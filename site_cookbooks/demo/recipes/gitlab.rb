#
# Cookbook Name:: demo
# Recipe:: gitlab
#
# Copyright:: Copyright (c) 2017 eGlobalTech, Inc., all rights reserved
#
# Licensed under the BSD-3 license (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License in the root of the project or at
#
#     http://egt-labs.com/mu/LICENSE.html
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'securerandom'
include_recipe 'chef-vault'
#DO CONFIG HERE

# MOVE THESE ATTRIBUTES TO A ATTRIBUTES FILE
node.default['gitlab']['generate_runnerToken'] = true
node.default['gitlab']['generate_password'] = true


# Set an attribute to identify the node as a GitLab Server
node.default['gitlab']['is_server'] = true
node.default['gitlab']['endpoint'] = 'http://'+node['ec2']['public_dns_name']+'/'
node.default['gitlab']['endpoint'] = node['gitlab']['endpoint']
ENV['GITLAB_ENDPOINT'] = node['gitlab']['endpoint']

if !node['gitlab'].attribute?('runnerToken') && node['gitlab']['generate_runnerToken'] == true
    runnerToken = SecureRandom.urlsafe_base64 #GENERATE A RUNNER TOKEN
    node.default['gitlab']['runnerToken'] = runnerToken #SAVE THE TOKEN TO AN ATTRIBUTE
    ENV['GITLAB_SHARED_RUNNERS_REGISTRATION_TOKEN'] = runnerToken #PASS THE TOKEN TO THE GITLAB INSTALLER
end

# TODO SAVE PWD and TOKEN TO VAULT FOR SECURITY

if !node['gitlab'].attribute?('rootPWD') && node['gitlab']['generate_password'] == true
    rootPWD = SecureRandom.urlsafe_base64 # GENERATE A ROOT PASSWORD
    node.default['gitlab']['rootPWD'] = rootPWD #SAVE THE PASSWORD TO AN ATTRIBUTE
    ENV['GITLAB_ROOT_PASSWORD'] = rootPWD #PASS THE PASSWORD TO THE GITLAB INSTALLER

    # Notify Users of GITLAB instalation
    ruby_block "gitlabNotify" do
        block do
            puts "\n######################################## End of Run Information ########################################"
            puts "# Your Gitlab Server is running at #{node['omnibus-gitlab']['gitlab_rb']['external_url']}"
            puts "# The root password is #{rootPWD} you may want to change it..."
            puts "########################################################################################################\n\n"
        end
    end
end




# SETUP VARIABLES FOR GITLAB.RB CONFIGURATION
node.override['omnibus-gitlab']['gitlab_rb']['external_url'] = node['gitlab']['endpoint']

include_recipe 'omnibus-gitlab::default'

