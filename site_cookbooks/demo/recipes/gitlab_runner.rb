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



# SEARCH FOR THE GITLAB SERVER

gitlabServer = ''
gitlabToken = ''

gitlabServers = search(:node, "gitlab_is_server:true") do |node|
  gitlabServer = node['gitlab']['endpoint']
  gitlabToken = node['gitlab']['runnerToken']
end

if gitlabServer == '' 
  gitlabServer = ENV['GITLAB_ENDPOINT']
  gitlabToken = ENV['GITLAB_SHARED_RUNNERS_REGISTRATION_TOKEN']
end

case node['platform']

when 'windows'
    puts "******************************************************"
    puts "NEED TO DO WINDOWS STUFFS!"
    puts "******************************************************"

    powershell_script 'Install Chocolatey' do
      code <<-EOH
      Set-ExecutionPolicy Bypass -Scope Process -Force; iex ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
      
      EOH
      not_if 'choco -v'
    end
    
    chocolatey_package 'gitlab-runner'  do
      action :upgrade
    end
    
else

    case node['platform_family']
    when 'rhel', 'amazon'
      scriptURL = 'https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.rpm.sh'
    when 'debian'
      scriptURL = 'https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh'
    end

    execute 'Configure Repositories' do
      command "curl -L #{scriptURL} | sudo bash"
    end

    package 'gitlab-runner' do
      action :install
    end

    service 'gitlab-runner' do
      action [:enable, :start]
    end

    execute 'Register Runner' do
      command "gitlab-runner register -n -u '#{gitlabServer}' -r '#{gitlabToken}' --executor docker --docker-image ubuntu --locked false --tag-list '#{node['ec2']['public_dns_name']}, #{node['platform_family']}, docker'"
      notifies :restart, "service[gitlab-runner]", :delayed
    end

    docker_service 'default' do
      action [:create, :start]
    end
end