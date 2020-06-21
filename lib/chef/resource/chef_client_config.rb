#
# Copyright:: Copyright (c) Chef Software Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require_relative "../resource"

class Chef
  class Resource
    class ChefClientConfig < Chef::Resource
      unified_mode true

      provides :chef_client_config

      description "Use the **chef_client_config** resource to setup the #{Chef::Dist::PRODUCT} client.rb file used to configure the chef-client process"
      introduced "16.4"
      examples <<~DOC
      **Setup #{Chef::Dist::PRODUCT} to run using the default 30 minute cadence**:

      ```ruby
      chef_client_config "Configure /etc/chef/client.rb"
      ```

      **Configure the #{Chef::Dist::PRODUCT} in a non-standard location**:

      ```ruby
      chef_client_config "Configure client.rb in /usr/chef/client.rb" do

      end
      ```

      **Run #{Chef::Dist::PRODUCT} with extra options passed to the client**:

      ```ruby
      ```
      DOC

      property :filename, String,
        default: "client.rb",
        description: "The name of the configuration file for chef-client."

      property :chef_server_url, String,
        default: Chef::Config[:chef_server_url],
        description: "The URL of the Chef Infra Server the client will connect to.",
        default_description: "Defaults to the Chef Infra Server that the client is already bootstrapped to."

      property :validation_client_name, String,
        default: Chef::Config[:validation_client_name],
        description: "The validation client name.",
        default_description: "Defaults to the validation client name that the client is already using."

      property :node_name, String,
        default: Chef::Config[:node_name],
        description: "The name the node is registered to the Chef Infra Server as.",
        default_description: "Defaults to the client's current node_name"

      action :configure do
        if node['chef_client']['log_file'].is_a?(String)
          log_path = ::File.join(node['chef_client']['log_dir'], node['chef_client']['log_file'])
          node.default['chef_client']['config']['log_location'] = log_path

          if node['os'] == 'linux'
            logrotate_app 'chef-client' do
              path [log_path]
              rotate node['chef_client']['logrotate']['rotate']
              frequency node['chef_client']['logrotate']['frequency']
              options node['chef_client']['log_rotation']['options']
              prerotate node['chef_client']['log_rotation']['prerotate']
              postrotate node['chef_client']['log_rotation']['postrotate']
              template_mode '0644'
            end
          end
        else
          log_path = 'STDOUT'
        end

        # libraries/helpers.rb method to DRY directory creation resources
        create_chef_directories

        # We need to set these local variables because the methods aren't
        # available in the Chef::Resource scope
        d_owner = root_owner

        if log_path != 'STDOUT'
          file log_path do
            owner d_owner
            group node['root_group']
            mode node['chef_client']['log_perm']
          end
        end

        chef_requires = []
        node['chef_client']['load_gems'].each do |gem_name, gem_info_hash|
          gem_info_hash ||= {}
          chef_gem gem_name do
            compile_time true
            action gem_info_hash[:action] || :install
            source gem_info_hash[:source] if gem_info_hash[:source]
            version gem_info_hash[:version] if gem_info_hash[:version]
            options gem_info_hash[:options] if gem_info_hash[:options]
            retries gem_info_hash[:retries] if gem_info_hash[:retries]
            retry_delay gem_info_hash[:retry_delay] if gem_info_hash[:retry_delay]
            timeout gem_info_hash[:timeout] if gem_info_hash[:timeout]
          end
          chef_requires.push(gem_info_hash[:require_name] || gem_name)
        end

        template "#{node['chef_client']['conf_dir']}/client.rb" do
          source ::File.expand_path("../support/client.rb.erb", __FILE__)
          owner d_owner
          group node['root_group']
          mode '0644'
          variables(
            chef_config: node['chef_client']['config'],
            chef_requires: chef_requires,
            ohai_disabled_plugins: node['ohai']['disabled_plugins'],
            ohai_optional_plugins: node['ohai']['optional_plugins'],
            start_handlers: node['chef_client']['config']['start_handlers'],
            report_handlers: node['chef_client']['config']['report_handlers'],
            exception_handlers: node['chef_client']['config']['exception_handlers'],
            chef_license: node['chef_client']['chef_license']
          )

          if node['chef_client']['reload_config']
            notifies :run, 'ruby_block[reload_client_config]', :immediately
          end
        end

        directory ::File.join(node['chef_client']['conf_dir'], 'client.d') do
          recursive true
          owner d_owner
          group node['root_group']
          mode '0755'
        end

        ruby_block 'reload_client_config' do
          block do
            Chef::Config.from_file("#{node['chef_client']['conf_dir']}/client.rb")
          end
          action :nothing
        end
      end

      action_class do
        #
        # Generate a uniformly distributed unique number to sleep from 0 to the splay time
        #
        # @param [Integer] splay The number of seconds to splay
        #
        # @return [Integer]
        #
        def splay_sleep_time(splay)
          seed = node["shard_seed"] || Digest::MD5.hexdigest(node.name).to_s.hex
          random = Random.new(seed.to_i)
          random.rand(splay)
        end

        #
        # The complete cron command to run
        #
        # @return [String]
        #
        def cron_command
          cmd = ""
          cmd << "/bin/sleep #{splay_sleep_time(new_resource.splay)}; "
          cmd << "#{new_resource.chef_binary_path} "
          cmd << "#{new_resource.daemon_options.join(" ")} " unless new_resource.daemon_options.empty?
          cmd << "-c #{::File.join(new_resource.config_directory, "client.rb")} "
          cmd << "--chef-license accept " if new_resource.accept_chef_license
          cmd << log_command
          cmd << " || echo \"#{Chef::Dist::PRODUCT} execution failed\"" if new_resource.mailto
          cmd
        end

        #
        # The portion of the overall cron job that handles logging based on the append_log_file property
        #
        # @return [String]
        #
        def log_command
          if new_resource.append_log_file
            "-L #{::File.join(new_resource.log_directory, new_resource.log_file_name)}"
          else
            "> #{::File.join(new_resource.log_directory, new_resource.log_file_name)} 2>&1"
          end
        end

        #
        # The type of cron resource to run. Linux systems all support the /etc/cron.d directory
        # and can use the cron_d resource, but Solaris / AIX / FreeBSD need to use the crontab
        # via the legacy cron resource.
        #
        # @return [Symbol]
        #
        def cron_resource_type
          linux? ? :cron_d : :cron
        end
      end
    end
  end
end
