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

require 'net/ssh'
require 'net/ssh/multi'
require 'net/ssh/proxy/command'
autoload :OpenStruct, "ostruct"
autoload :Timeout, "timeout"
autoload :ERB, "erb"
autoload :Base64, "base64"
require 'open-uri'

module MU
  class Cloud
    class Google

      # A server as configured in {MU::Config::BasketofKittens::servers}. In
      # Google Cloud, this amounts to a single Instance in an Unmanaged
      # Instance Group.
      class Server < MU::Cloud::Server

        attr_reader :mu_name
        attr_reader :config
        attr_reader :deploy
        attr_reader :cloud_id
        attr_reader :cloud_desc
        attr_reader :groomer
        attr_accessor :mu_windows_name

        # @param mommacat [MU::MommaCat]: A {MU::Mommacat} object containing the deploy of which this resource is/will be a member.
        # @param kitten_cfg [Hash]: The fully parsed and resolved {MU::Config} resource descriptor as defined in {MU::Config::BasketofKittens::servers}
        def initialize(mommacat: nil, kitten_cfg: nil, mu_name: nil, cloud_id: nil)
          @deploy = mommacat
          @config = MU::Config.manxify(kitten_cfg)
          @cloud_id = cloud_id

          # XXX does this go into a Google::Apis::ComputeBeta::Metadata object?
          @userdata = MU::Cloud::AWS::Server.fetchUserdata(
            platform: @config["platform"],
            template_variables: {
              "deployKey" => Base64.urlsafe_encode64(@deploy.public_key),
              "deploySSHKey" => @deploy.ssh_public_key,
              "muID" => MU.deploy_id,
              "muUser" => MU.mu_user,
              "publicIP" => MU.mu_public_ip,
              "skipApplyUpdates" => @config['skipinitialupdates'],
              "windowsAdminName" => @config['windows_admin_username'],
              "resourceName" => @config["name"],
              "resourceType" => "server",
              "platform" => @config["platform"]
            },
            custom_append: @config['userdata_script']
          )

          if !mu_name.nil?
            @mu_name = mu_name
            @config['mu_name'] = @mu_name
            # describe
            @mu_windows_name = @deploydata['mu_windows_name'] if @mu_windows_name.nil? and @deploydata
          else
            if kitten_cfg.has_key?("basis")
              @mu_name = @deploy.getResourceName(@config['name'], need_unique_string: true).downcase
            else
              @mu_name = @deploy.getResourceName(@config['name']).downcase
            end
            @config['mu_name'] = @mu_name

            @config['instance_secret'] = Password.random(50)
          end
          @config['ssh_user'] ||= "mu"
          @groomer = MU::Groomer.new(self)

        end

        # Called automatically by {MU::Deploy#createResources}
        def create

          begin
            disks = []

# XXX slurp settings from /dev/sda or w/e by convention
            imageobj = MU::Cloud::Google.compute(:AttachedDiskInitializeParams).new(
              source_image: @config['image_id'],
              disk_size_gb: 10, # this is binary? 2gb, that says
              disk_type: "projects/#{@config['project']}/zones/#{@config['availability_zone']}/diskTypes/pd-standard"
# disk_type: projects/project/zones/#{@config['availability_zone']}/diskTypes/pd-standard Other values include pd-ssd and local-ssd
            )
            disks << MU::Cloud::Google.compute(:AttachedDisk).new(
              auto_delete: true,
              boot: true,
              mode: "READ_WRITE",
              type: "PERSISTENT",
              initialize_params: imageobj
            )
            if @config["storage"]
              @config["storage"].each { |vol|
                devicename = vol['device'].gsub(/[^\w\-\.]/, "-").sub(/^[^\w]/, "")
                disk_desc = {
                  :auto_delete => true,
                  :device_name => devicename, # XXX empty string is also legit
                  :mode => "READ_WRITE",
                  :type => "PERSISTENT" # SCRATCH is equivalent of ephemeral? cheap virtual memory disk? maybe ship a standard set
                }

                if vol['snapshot_id']
# XXX check existence in in validateConfig
                elsif vol['somekindofidforaloosevolume']
                  disk_desc[:source] = vol['somekindofidforaloosevolume']
# XXX check existence in in validateConfig
                else
                  newdiskobj = MU::Cloud::Google.compute(:Disk).new(
                    size_gb: vol['size'],
                    description: @deploy.deploy_id,
                    zone: @config['availability_zone'],
#                    type: "projects/#{@config['project']}/zones/#{@config['availability_zone']}/diskTypes/pd-ssd",
                    type: "projects/#{@config['project']}/zones/#{@config['availability_zone']}/diskTypes/pd-standard",
# type: projects/project/zones/#{@config['availability_zone']}/diskTypes/pd-standard Other values include pd-ssd and local-ssd
                    name: @mu_name+"-"+devicename
                  )
                  MU.log "Creating disk #{@mu_name}-#{devicename}"

                  newdisk = MU::Cloud::Google.compute.insert_disk(
                    @config['project'],
                    @config['availability_zone'],
                    newdiskobj
                  )
# XXX Do we have to wait for this? Thread this loop if so
# newdisk.progress means things

                  disk_desc[:source] = newdisk.self_link
                end

                disks << MU::Cloud::Google.compute(:AttachedDisk).new(disk_desc)
              }
            end


            base_iface_obj = {
              :network => @config['vpc']['vpc_id'],
              :subnetwork => @config['vpc']['subnet_id']
            }
            if @config['associate_public_ip']
              base_iface_obj[:access_configs] = [
                MU::Cloud::Google.compute(:AccessConfig).new
              ]
            end
            interfaces = [base_iface_obj]
            # XXX add more if they asked for it

            desc = {
              :name => @mu_name,
              :can_ip_forward => !@config['src_dst_check'],
              :description => @deploy.deploy_id,
              :network_interfaces => interfaces,
              :machine_type => "zones/"+@config['availability_zone']+"/machineTypes/"+@config['size'],
              :metadata => {
                :items => [
                  :key => "ssh-keys",
                  :value => @config['ssh_user']+":"+@deploy.ssh_public_key
                ]
              }
            }
# XXX tags aren't tags, but labels are maybe?
            desc[:disks] = disks if disks.size > 0

            instanceobj = MU::Cloud::Google.compute(:Instance).new(desc)

            MU.log "Creating instance #{@mu_name}"
            insert = MU::Cloud::Google.compute.insert_instance(
              @config['project'],
              @config['availability_zone'],
              instanceobj
            )
            @cloud_id = @mu_name # XXX or instance.target_link... pick a convention, would you?

            done = false

            @deploy.saveNodeSecret(@cloud_id, @config['instance_secret'], "instance_secret")
            @config.delete("instance_secret")

            if cloud_desc.nil? or cloud_desc.status != "RUNNING"
              raise MuError, "#{@cloud_id} appears to have gone sideways mid-bootstrap #{cloud_desc.status if cloud_desc.nil?}"
            end

            notify

            if !@config['async_groom']
              sleep 5
              MU::MommaCat.lock(@cloud_id+"-create")
              if !postBoot
                MU.log "#{@config['name']} is already being groomed, skipping", MU::NOTICE
              else
                MU.log "Node creation complete for #{@config['name']}"
              end
              MU::MommaCat.unlock(@cloud_id+"-create")
            else
#              MU::MommaCat.createStandardTags(@cloud_id, region: @config['region'])
#              MU::MommaCat.createTag(@cloud_id, "Name", @mu_name, region: @config['region'])
            end
            done = true
          rescue Exception => e
            if !cloud_desc.nil? and !done
              MU.log "Aborted before I could finish setting up #{@config['name']}, cleaning it up. Stack trace will print once cleanup is complete.", MU::WARN if !@deploy.nocleanup
              MU::MommaCat.unlockAll
              if !@deploy.nocleanup
                parent_thread_id = Thread.current.object_id
                Thread.new {
                  MU.dupGlobals(parent_thread_id)
                  MU::Cloud::Google::Server.cleanup(noop: false, ignoremaster: false, skipsnapshots: true)
                }
              end
            end
            raise e
          end

          return @config
        end

        # Ask the Google API to restart this node
        def reboot(hard = false)
          return if @cloud_id.nil?

          if hard
            groupname = nil
            if !@config['basis'].nil?
              resp = MU::Cloud::AWS.autoscale(@config['region']).describe_auto_scaling_instances(
                instance_ids: [@cloud_id]
              )
              groupname = resp.auto_scaling_instances.first.auto_scaling_group_name
              MU.log "Pausing Autoscale processes in #{groupname}", MU::NOTICE
              MU::Cloud::AWS.autoscale(@config['region']).suspend_processes(
                auto_scaling_group_name: groupname
              )
            end
            begin
              MU.log "Stopping #{@mu_name} (#{@cloud_id})", MU::NOTICE
              MU::Cloud::AWS.ec2(@config['region']).stop_instances(
                instance_ids: [@cloud_id]
              )
              MU::Cloud::AWS.ec2(@config['region']).wait_until(:instance_stopped, instance_ids: [@cloud_id]) do |waiter|
                waiter.before_attempt do |attempts|
                  MU.log "Waiting for #{@mu_name} to stop for hard reboot"
                end
              end
              MU.log "Starting #{@mu_name} (#{@cloud_id})"
              MU::Cloud::AWS.ec2(@config['region']).start_instances(
                instance_ids: [@cloud_id]
              )
            ensure
              if !groupname.nil?
                MU.log "Resuming Autoscale processes in #{groupname}", MU::NOTICE
                MU::Cloud::AWS.autoscale(@config['region']).resume_processes(
                  auto_scaling_group_name: groupname
                )
              end
            end
          else
            MU.log "Rebooting #{@mu_name} (#{@cloud_id})"
            MU::Cloud::AWS.ec2(@config['region']).reboot_instances(
              instance_ids: [@cloud_id]
            )
          end
        end

        # Figure out what's needed to SSH into this server.
        # @return [Array<String>]: nat_ssh_key, nat_ssh_user, nat_ssh_host, canonical_ip, ssh_user, ssh_key_name, alternate_names
        def getSSHConfig
          node, config, deploydata = describe(cloud_id: @cloud_id)
# XXX add some awesome alternate names from metadata and make sure they end
# up in MU::MommaCat's ssh config wangling
          ssh_keydir = Etc.getpwuid(Process.uid).dir+"/.ssh"
          return nil if @config.nil? or @deploy.nil?

          nat_ssh_key = nat_ssh_user = nat_ssh_host = nil
          if !@config["vpc"].nil? and !MU::Cloud::Google::VPC.haveRouteToInstance?(cloud_desc, region: @config['region'])
            if !@nat.nil?
              if @nat.is_a?(Struct) && @nat.nat_gateway_id && @nat.nat_gateway_id.start_with?("nat-")
                raise MuError, "Configured to use NAT Gateway, but I have no route to instance. Either use Bastion, or configure VPC peering"
              end

              if @nat.cloud_desc.nil?
                MU.log "NAT was missing cloud descriptor when called in #{@mu_name}'s getSSHConfig", MU::ERR
                return nil
              end
              # XXX Yanking these things from the cloud descriptor will only work in AWS!

              nat_ssh_key = @nat.cloud_desc.key_name
							nat_ssh_key = @config["vpc"]["nat_ssh_key"] if !@config["vpc"]["nat_ssh_key"].nil?
              nat_ssh_host = @nat.cloud_desc.public_ip_address
              nat_ssh_user = @config["vpc"]["nat_ssh_user"]
              if nat_ssh_user.nil? and !nat_ssh_host.nil?
                MU.log "#{@config["name"]} (#{MU.deploy_id}) is configured to use #{@config['vpc']} NAT #{nat_ssh_host}, but username isn't specified. Guessing root.", MU::ERR, details: caller
                nat_ssh_user = "root"
              end
            end
          end

          if @config['ssh_user'].nil?
            if windows?
              @config['ssh_user'] = "Administrator"
            else
              @config['ssh_user'] = "root"
            end
          end

          return [nat_ssh_key, nat_ssh_user, nat_ssh_host, canonicalIP, @config['ssh_user'], @deploy.ssh_key_name]

        end

        # Apply tags, bootstrap our configuration management, and other
        # administravia for a new instance.
        def postBoot(instance_id = nil)
          if !instance_id.nil?
            @cloud_id = instance_id
          end

          instance = cloud_desc

          node, config, deploydata = describe(cloud_id: @cloud_id)
          instance = cloud_desc
          raise MuError, "Couldn't find instance of #{@mu_name} (#{@cloud_id})" if !instance
          @cloud_id = @cloud_id
          return false if !MU::MommaCat.lock(@cloud_id+"-orchestrate", true)
          return false if !MU::MommaCat.lock(@cloud_id+"-groom", true)

#          MU::MommaCat.createStandardTags(@cloud_id, region: @config['region'])
#          MU::MommaCat.createTag(@cloud_id, "Name", node, region: @config['region'])
#
#          if @config['optional_tags']
#            MU::MommaCat.listOptionalTags.each { |key, value|
#              MU::MommaCat.createTag(@cloud_id, key, value, region: @config['region'])
#            }
#          end
#
#          if !@config['tags'].nil?
#            @config['tags'].each { |tag|
#              MU::MommaCat.createTag(@cloud_id, tag['key'], tag['value'], region: @config['region'])
#            }
#          end
#          MU.log "Tagged #{node} (#{@cloud_id}) with MU-ID=#{MU.deploy_id}", MU::DEBUG
#
          # Make double sure we don't lose a cached mu_windows_name value.
          if windows? or !@config['active_directory'].nil?
            if @mu_windows_name.nil?
              @mu_windows_name = deploydata['mu_windows_name']
            end
          end

#          punchAdminNAT
#
#
#          # If we came up via AutoScale, the Alarm module won't have had our
#          # instance ID to associate us with itself. So invoke that here.
#          if !@config['basis'].nil? and @config["alarms"] and !@config["alarms"].empty?
#            @config["alarms"].each { |alarm|
#              alarm_obj = MU::MommaCat.findStray(
#                "AWS",
#                "alarms",
#                region: @config["region"],
#                deploy_id: @deploy.deploy_id,
#                name: alarm['name']
#              ).first
#              alarm["dimensions"] = [{:name => "InstanceId", :value => @cloud_id}]
#
#              if alarm["enable_notifications"]
#                topic_arn = MU::Cloud::AWS::Notification.createTopic(alarm["notification_group"], region: @config["region"])
#                MU::Cloud::AWS::Notification.subscribe(arn: topic_arn, protocol: alarm["notification_type"], endpoint: alarm["notification_endpoint"], region: @config["region"])
#                alarm["alarm_actions"] = [topic_arn]
#                alarm["ok_actions"]  = [topic_arn]
#              end
#
#              alarm_name = alarm_obj ? alarm_obj.cloud_id : "#{node}-#{alarm['name']}".upcase
#
#              MU::Cloud::AWS::Alarm.setAlarm(
#                name: alarm_name,
#                ok_actions: alarm["ok_actions"],
#                alarm_actions: alarm["alarm_actions"],
#                insufficient_data_actions: alarm["no_data_actions"],
#                metric_name: alarm["metric_name"],
#                namespace: alarm["namespace"],
#                statistic: alarm["statistic"],
#                dimensions: alarm["dimensions"],
#                period: alarm["period"],
#                unit: alarm["unit"],
#                evaluation_periods: alarm["evaluation_periods"],
#                threshold: alarm["threshold"],
#                comparison_operator: alarm["comparison_operator"],
#                region: @config["region"]
#              )
#            }
#          end
#
#          # We have issues sometimes where our dns_records are pointing at the wrong node name and IP address.
#          # Make sure that doesn't happen. Happens with server pools only
#          if @config['dns_records'] && !@config['dns_records'].empty?
#            @config['dns_records'].each { |dnsrec|
#              if dnsrec.has_key?("name")
#                if dnsrec['name'].start_with?(MU.deploy_id.downcase) && !dnsrec['name'].start_with?(node.downcase)
#                  MU.log "DNS records for #{node} seem to be wrong, deleting from current config", MU::WARN, details: dnsrec
#                  dnsrec.delete('name')
#                  dnsrec.delete('target')
#                end
#              end
#            }
#          end

          # Unless we're planning on associating a different IP later, set up a
          # DNS entry for this thing and let it sync in the background. We'll
          # come back to it later.
          if @config['static_ip'].nil? && !@named
            MU::MommaCat.nameKitten(self)
            @named = true
          end

#          if !@config['src_dst_check'] and !@config["vpc"].nil?
#            MU.log "Disabling source_dest_check #{node} (making it NAT-worthy)"
#            MU::Cloud::AWS.ec2(@config['region']).modify_instance_attribute(
#                instance_id: @cloud_id,
#                source_dest_check: {:value => false}
#            )
#          end

#          # Set console termination protection. Autoscale nodes won't set this
#          # by default.
#          MU::Cloud::AWS.ec2(@config['region']).modify_instance_attribute(
#              instance_id: @cloud_id,
#              disable_api_termination: {:value => true}
#          )

#MU.log "Let's deal with addressing", MU::WARN, details: cloud_desc
            # If we asked for a public IP address, make sure we get one
#              addrobj = MU::Cloud::Google.compute(:Address).new(
#                name: @mu_name+"-public-ip",
#                description: @deploy.deploy_id
#              )
#              addr_insert = MU::Cloud::Google.compute.insert_global_address(
#                @config['project'],
##                @config['region'],
#                addrobj
#              )
#              pp addr_insert
#              raise "BOOP"
#          has_elastic_ip = false
#          if !instance.public_ip_address.nil?
#            begin
#              resp = MU::Cloud::AWS.ec2((@config['region'])).describe_addresses(public_ips: [instance.public_ip_address])
#              if resp.addresses.size > 0 and resp.addresses.first.instance_id == @cloud_id
#                has_elastic_ip = true
#              end
#            rescue Aws::EC2::Errors::InvalidAddressNotFound => e
#              # XXX this is ok to ignore, it means the public IP isn't Elastic
#            end
#          end

#          win_admin_password = nil
#          ec2config_password = nil
#          sshd_password = nil
#          if windows?
#            ssh_keydir = "#{Etc.getpwuid(Process.uid).dir}/.ssh"
#            ssh_key_name = @deploy.ssh_key_name
#
#            if @config['use_cloud_provider_windows_password']
#              win_admin_password = getWindowsAdminPassword
#            elsif @config['windows_auth_vault'] && !@config['windows_auth_vault'].empty?
#              if @config["windows_auth_vault"].has_key?("password_field")
#                win_admin_password = @groomer.getSecret(
#                    vault: @config['windows_auth_vault']['vault'],
#                    item: @config['windows_auth_vault']['item'],
#                    field: @config["windows_auth_vault"]["password_field"]
#                )
#              else
#                win_admin_password = getWindowsAdminPassword
#              end
#
#              if @config["windows_auth_vault"].has_key?("ec2config_password_field")
#                ec2config_password = @groomer.getSecret(
#                    vault: @config['windows_auth_vault']['vault'],
#                    item: @config['windows_auth_vault']['item'],
#                    field: @config["windows_auth_vault"]["ec2config_password_field"]
#                )
#              end
#
#              if @config["windows_auth_vault"].has_key?("sshd_password_field")
#                sshd_password = @groomer.getSecret(
#                    vault: @config['windows_auth_vault']['vault'],
#                    item: @config['windows_auth_vault']['item'],
#                    field: @config["windows_auth_vault"]["sshd_password_field"]
#                )
#              end
#            end
#
#            win_admin_password = MU.generateWindowsPassword if win_admin_password.nil?
#            ec2config_password = MU.generateWindowsPassword if ec2config_password.nil?
#            sshd_password = MU.generateWindowsPassword if sshd_password.nil?
#
#            # We're creating the vault here so when we run
#            # MU::Cloud::Server.initialSSHTasks and we need to set the Windows
#            # Admin password we can grab it from said vault.
#            creds = {
#                "username" => @config['windows_admin_username'],
#                "password" => win_admin_password,
#                "ec2config_username" => "ec2config",
#                "ec2config_password" => ec2config_password,
#                "sshd_username" => "sshd_service",
#                "sshd_password" => sshd_password
#            }
#            @groomer.saveSecret(vault: @mu_name, item: "windows_credentials", data: creds, permissions: "name:#{@mu_name}")
#          end
#
#
#            nat_ssh_key, nat_ssh_user, nat_ssh_host, canonical_ip, ssh_user, ssh_key_name = getSSHConfig
#            if subnet.private? and !nat_ssh_host and !MU::Cloud::Google::VPC.haveRouteToInstance?(cloud_desc, region: @config['region'])
#              raise MuError, "#{node} is in a private subnet (#{subnet}), but has no NAT host configured, and I have no other route to it"
#            end
#
#            # If we've asked for additional subnets (and this @config is not a
#            # member of a Server Pool, which has different semantics), create
#            # extra interfaces to accomodate.
#            if !@config['vpc']['subnets'].nil? and @config['basis'].nil?
#              device_index = 1
#              @vpc.subnets { |subnet|
#                subnet_id = subnet.cloud_id
#                MU.log "Adding network interface on subnet #{subnet_id} for #{node}"
#                iface = MU::Cloud::AWS.ec2(@config['region']).create_network_interface(subnet_id: subnet_id).network_interface
#                MU::MommaCat.createStandardTags(iface.network_interface_id, region: @config['region'])
#                MU::MommaCat.createTag(iface.network_interface_id, "Name", node+"-ETH"+device_index.to_s, region: @config['region'])
#
#                if @config['optional_tags']
#                  MU::MommaCat.listOptionalTags.each { |key, value|
#                    MU::MommaCat.createTag(iface.network_interface_id, key, value, region: @config['region'])
#                  }
#                end
#
#                if !@config['tags'].nil?
#                  @config['tags'].each { |tag|
#                    MU::MommaCat.createTag(iface.network_interface_id, tag['key'], tag['value'], region: @config['region'])
#                  }
#                end
#
#                MU::Cloud::AWS.ec2(@config['region']).attach_network_interface(
#                    network_interface_id: iface.network_interface_id,
#                    instance_id: @cloud_id,
#                    device_index: device_index
#                )
#                device_index = device_index + 1
#              }
#            end
#          elsif !@config['static_ip'].nil?
#            if !@config['static_ip']['ip'].nil?
#              public_ip = MU::Cloud::AWS::Server.associateElasticIp(@cloud_id, classic: true, ip: @config['static_ip']['ip'])
#            elsif !has_elastic_ip
#              public_ip = MU::Cloud::AWS::Server.associateElasticIp(@cloud_id, classic: true)
#            end
#          end
#
#
#          if !@config['image_then_destroy']
#            notify
#          end
#
#          MU.log "EC2 instance #{node} has id #{@cloud_id}", MU::DEBUG
#
#          @config["private_dns_name"] = instance.private_dns_name
#          @config["public_dns_name"] = instance.public_dns_name
#          @config["private_ip_address"] = instance.private_ip_address
#          @config["public_ip_address"] = instance.public_ip_address
#
#          ext_mappings = MU.structToHash(instance.block_device_mappings)
#
#          # Root disk on standard CentOS AMI
#          # tagVolumes(@cloud_id, "/dev/sda", "Name", "ROOT-"+MU.deploy_id+"-"+@config["name"].upcase)
#          # Root disk on standard Ubuntu AMI
#          # tagVolumes(@cloud_id, "/dev/sda1", "Name", "ROOT-"+MU.deploy_id+"-"+@config["name"].upcase)
#
#          # Generic deploy ID tag
#          # tagVolumes(@cloud_id)
#
#          # Tag volumes with all our standard tags.
#          # Maybe replace tagVolumes with this? There is one more place tagVolumes is called from
#          volumes = MU::Cloud::AWS.ec2(@config['region']).describe_volumes(filters: [name: "attachment.instance-id", values: [@cloud_id]])
#          volumes.each { |vol|
#            vol.volumes.each { |volume|
#              volume.attachments.each { |attachment|
#                MU::MommaCat.listStandardTags.each_pair { |key, value|
#                  MU::MommaCat.createTag(attachment.volume_id, key, value, region: @config['region'])
#
#                  if attachment.device == "/dev/sda" or attachment.device == "/dev/sda1"
#                    MU::MommaCat.createTag(attachment.volume_id, "Name", "ROOT-#{MU.deploy_id}-#{@config["name"].upcase}", region: @config['region'])
#                  else
#                    MU::MommaCat.createTag(attachment.volume_id, "Name", "#{MU.deploy_id}-#{@config["name"].upcase}-#{attachment.device.upcase}", region: @config['region'])
#                  end
#                }
#
#                if @config['optional_tags']
#                  MU::MommaCat.listOptionalTags.each { |key, value|
#                    MU::MommaCat.createTag(attachment.volume_id, key, value, region: @config['region'])
#                  }
#                end
#
#                if @config['tags']
#                  @config['tags'].each { |tag|
#                    MU::MommaCat.createTag(attachment.volume_id, tag['key'], tag['value'], region: @config['region'])
#                  }
#                end
#              }
#            }
#          }
#
#          canonical_name = instance.public_dns_name
#          canonical_name = instance.private_dns_name if !canonical_name or nat_ssh_host != nil
#          @config['canonical_name'] = canonical_name
#
#          if !@config['add_private_ips'].nil?
#            instance.network_interfaces.each { |int|
#              if int.private_ip_address == instance.private_ip_address and int.private_ip_addresses.size < (@config['add_private_ips'] + 1)
#                MU.log "Adding #{@config['add_private_ips']} extra private IP addresses to #{@cloud_id}"
#                MU::Cloud::AWS.ec2(@config['region']).assign_private_ip_addresses(
#                    network_interface_id: int.network_interface_id,
#                    secondary_private_ip_address_count: @config['add_private_ips'],
#                    allow_reassignment: false
#                )
#              end
#            }
#            notify
#          end
#
#          windows? ? ssh_wait = 60 : ssh_wait = 30
#          windows? ? max_retries = 50 : max_retries = 35
#          begin
#            session = getSSHSession(max_retries, ssh_wait)
#            initialSSHTasks(session)
#          rescue BootstrapTempFail
#            sleep ssh_wait
#            retry
#          ensure
#            session.close if !session.nil?
#          end
#
#          if @config["existing_deploys"] && !@config["existing_deploys"].empty?
#            @config["existing_deploys"].each { |ext_deploy|
#              if ext_deploy["cloud_id"]
#                found = MU::MommaCat.findStray(
#                  @config['cloud'],
#                  ext_deploy["cloud_type"],
#                  cloud_id: ext_deploy["cloud_id"],
#                  region: @config['region'],
#                  dummy_ok: false
#                ).first
#
#                MU.log "Couldn't find existing resource #{ext_deploy["cloud_id"]}, #{ext_deploy["cloud_type"]}", MU::ERR if found.nil?
#                @deploy.notify(ext_deploy["cloud_type"], found.config["name"], found.deploydata, mu_name: found.mu_name, triggering_node: @mu_name)
#              elsif ext_deploy["mu_name"] && ext_deploy["deploy_id"]
#                MU.log "#{ext_deploy["mu_name"]} / #{ext_deploy["deploy_id"]}"
#                found = MU::MommaCat.findStray(
#                  @config['cloud'],
#                  ext_deploy["cloud_type"],
#                  deploy_id: ext_deploy["deploy_id"],
#                  mu_name: ext_deploy["mu_name"],
#                  region: @config['region'],
#                  dummy_ok: false
#                ).first
#
#                MU.log "Couldn't find existing resource #{ext_deploy["mu_name"]}/#{ext_deploy["deploy_id"]}, #{ext_deploy["cloud_type"]}", MU::ERR if found.nil?
#                @deploy.notify(ext_deploy["cloud_type"], found.config["name"], found.deploydata, mu_name: ext_deploy["mu_name"], triggering_node: @mu_name)
#              else
#                MU.log "Trying to find existing deploy, but either the cloud_id is not valid or no mu_name and deploy_id where provided", MU::ERR
#              end
#            }
#          end

          # See if this node already exists in our config management. If it does,
          # we're done.
          if @groomer.haveBootstrapped?
            MU.log "Node #{node} has already been bootstrapped, skipping groomer setup.", MU::NOTICE
            @groomer.saveDeployData
            MU::MommaCat.unlock(@cloud_id+"-orchestrate")
            MU::MommaCat.unlock(@cloud_id+"-groom")
            return true
          end

          @groomer.bootstrap

          # Make sure we got our name written everywhere applicable
          if !@named
            MU::MommaCat.nameKitten(self)
            @named = true
          end

          MU::MommaCat.unlock(@cloud_id+"-groom")
          MU::MommaCat.unlock(@cloud_id+"-orchestrate")
          return true
        end #postBoot

        # Locate an existing instance or instances and return an array containing matching AWS resource descriptors for those that match.
        # @param cloud_id [String]: The cloud provider's identifier for this resource.
        # @param region [String]: The cloud provider region
        # @param tag_key [String]: A tag key to search.
        # @param tag_value [String]: The value of the tag specified by tag_key to match when searching by tag.
        # @param ip [String]: An IP address associated with the instance
        # @param flags [Hash]: Optional flags
        # @return [Array<Hash<String,OpenStruct>>]: The cloud provider's complete descriptions of matching instances
        def self.find(cloud_id: nil, region: MU.curRegion, tag_key: "Name", tag_value: nil, ip: nil, flags: {})
# XXX put that 'ip' value into flags
          instance = nil
          if !region.nil?
            regions = [region]
          else
            regions = MU::Cloud::AWS.listRegions
          end

          found_instances = {}
          search_semaphore = Mutex.new
          search_threads = []

          # If we got an instance id, go get it
          if !cloud_id.nil? and !cloud_id.empty?
            regions.each { |region|
              search_threads << Thread.new {
                MU.log "Hunting for instance with cloud id '#{cloud_id}' in #{region}", MU::DEBUG
                retries = 0
                begin
                  MU::Cloud::AWS.ec2(region).describe_instances(
                      instance_ids: [cloud_id],
                      filters: [
                          {name: "instance-state-name", values: ["running", "pending"]}
                      ]
                  ).reservations.each { |resp|
                    if !resp.nil? and !resp.instances.nil?
                      resp.instances.each { |instance|
                        search_semaphore.synchronize {
                          found_instances[instance.instance_id] = instance
                        }
                      }
                    end
                  }
                rescue Aws::EC2::Errors::InvalidInstanceIDNotFound => e
                  if retries < 5
                    retries = retries + 1
                    sleep 5
                  else
                    raise MuError, "#{e.inspect} in region #{region}"
                  end
                end
              }
            }
            done_threads = []
            begin
              search_threads.each { |t|
                joined = t.join(2)
                done_threads << joined if !joined.nil?
              }
            end while found_instances.size < 1 and done_threads.size != search_threads.size
          end

          if found_instances.size > 0
            return found_instances
          end

          # Ok, well, let's try looking it up by IP then
          if instance.nil? and !ip.nil?
            MU.log "Hunting for instance by IP '#{ip}'", MU::DEBUG
            ["ip-address", "private-ip-address"].each { |filter|
              response = MU::Cloud::AWS.ec2(region).describe_instances(
                  filters: [
                      {name: filter, values: [ip]},
                      {name: "instance-state-name", values: ["running", "pending"]}
                  ]
              ).reservations.first
              instance = response.instances.first if !response.nil?
            }
          end

          if !instance.nil?
            return {instance.instance_id => instance} if !instance.nil?
          end

          # Fine, let's try it by tag.
          if !tag_value.nil?
            MU.log "Searching for instance by tag '#{tag_key}=#{tag_value}'", MU::DEBUG
            MU::Cloud::AWS.ec2(region).describe_instances(
                filters: [
                    {name: "tag:#{tag_key}", values: [tag_value]},
                    {name: "instance-state-name", values: ["running", "pending"]}
                ]
            ).reservations.each { |resp|
              if !resp.nil? and resp.instances.size > 0
                resp.instances.each { |instance|
                  found_instances[instance.instance_id] = instance
                }
              end
            }
          end

          return found_instances
        end

        # Return a description of this resource appropriate for deployment
        # metadata. Arguments reflect the return values of the MU::Cloud::[Resource].describe method
        def notify
          node, config, deploydata = describe(cloud_id: @cloud_id, update_cache: true)
          deploydata = {} if deploydata.nil?

          if cloud_desc.nil?
            raise MuError, "Failed to load instance metadata for #{@config['mu_name']}/#{@cloud_id}"
          end

          interfaces = []
          private_ips = []
          public_ips = []

          cloud_desc.network_interfaces.each { |iface|
            private_ips << iface.network_ip
            if iface.access_configs
              iface.access_configs.each { |acfg|
                public_ips << acfg.nat_ip if acfg.nat_ip
              }
            end
            interfaces << {
              "network_interface_id" => iface.name,
              "subnet_id" => iface.subnetwork,
              "vpc_id" => iface.network
            }
          }

          deploydata = {
              "nodename" => @config['mu_name'],
              "run_list" => @config['run_list'],
              "image_created" => @config['image_created'],
#              "iam_role" => @config['iam_role'],
              "cloud_desc_id" => @cloud_id,
              "private_ip_address" => private_ips.first,
              "public_ip_address" => public_ips.first,
              "private_ip_list" => private_ips,
#              "key_name" => cloud_desc.key_name,
#              "subnet_id" => cloud_desc.subnet_id,
#              "cloud_desc_type" => cloud_desc.instance_type #,
              #				"network_interfaces" => interfaces,
              #				"config" => server
          }

          if !@mu_windows_name.nil?
            deploydata["mu_windows_name"] = @mu_windows_name
          end
          if !@config['chef_data'].nil?
            deploydata.merge!(@config['chef_data'])
          end
          deploydata["region"] = @config['region'] if !@config['region'].nil?
          if !@named
            MU::MommaCat.nameKitten(self)
            @named = true
          end

          return deploydata
        end

        # Called automatically by {MU::Deploy#createResources}
        def groom
          MU::MommaCat.lock(@cloud_id+"-groom")
          node, config, deploydata = describe(cloud_id: @cloud_id)

          if node.nil? or node.empty?
            raise MuError, "MU::Cloud::AWS::Server.groom was called without a mu_name"
          end

          # Make double sure we don't lose a cached mu_windows_name value.
          if windows? or !@config['active_directory'].nil?
            if @mu_windows_name.nil?
              @mu_windows_name = deploydata['mu_windows_name']
            end
          end

#          punchAdminNAT

#          MU::Cloud::AWS::Server.tagVolumes(@cloud_id)

          # If we have a loadbalancer configured, attach us to it
#          if !@config['loadbalancers'].nil?
#            if @loadbalancers.nil?
#              raise MuError, "#{@mu_name} is configured to use LoadBalancers, but none have been loaded by dependencies()"
#            end
#            @loadbalancers.each { |lb|
#              lb.registerNode(@cloud_id)
#            }
#          end

          # Let us into any databases we depend on.
          # This is probelmtic with autscaling - old ips are not removed, and access to the database can easily be given at the BoK level
          # if @dependencies.has_key?("database")
            # @dependencies['database'].values.each { |db|
              # db.allowHost(@deploydata["private_ip_address"]+"/32")
              # if @deploydata["public_ip_address"]
                # db.allowHost(@deploydata["public_ip_address"]+"/32")
              # end
            # }
          # end

          @groomer.saveDeployData

          begin
            @groomer.run(purpose: "Full Initial Run", max_retries: 15)
          rescue MU::Groomer::RunError
            MU.log "Proceeding after failed initial Groomer run, but #{node} may not behave as expected!", MU::WARN
          end

          if !@config['create_image'].nil? and !@config['image_created']
            img_cfg = @config['create_image']
            # Scrub things that don't belong on an AMI
            session = getSSHSession
            sudo = purgecmd = ""
            sudo = "sudo" if @config['ssh_user'] != "root"
            if windows?
              purgecmd = "rm -rf /cygdrive/c/mu_installed_chef"
            else
              purgecmd = "rm -rf /opt/mu_installed_chef"
            end
            if img_cfg['image_then_destroy']
              if windows?
                purgecmd = "rm -rf /cygdrive/c/chef/ /home/#{@config['windows_admin_username']}/.ssh/authorized_keys /home/Administrator/.ssh/authorized_keys /cygdrive/c/mu-installer-ran-updates /cygdrive/c/mu_installed_chef"
                # session.exec!("powershell -Command \"& {(Get-WmiObject -Class Win32_Product -Filter \"Name='UniversalForwarder'\").Uninstall()}\"")
              else
                purgecmd = "#{sudo} rm -rf /root/.ssh/authorized_keys /etc/ssh/ssh_host_*key* /etc/chef /etc/opscode/* /.mu-installer-ran-updates /var/chef /opt/mu_installed_chef /opt/chef ; #{sudo} sed -i 's/^HOSTNAME=.*//' /etc/sysconfig/network"
              end
            end
            session.exec!(purgecmd)
            session.close
            ami_id = MU::Cloud::AWS::Server.createImage(
                name: @mu_name,
                instance_id: @cloud_id,
                storage: @config['storage'],
                exclude_storage: img_cfg['image_exclude_storage'],
                copy_to_regions: img_cfg['copy_to_regions'],
                make_public: img_cfg['public'],
                region: @config['region'],
                tags: @config['tags'])
            @deploy.notify("images", @config['name'], {"image_id" => ami_id})
            @config['image_created'] = true
            if img_cfg['image_then_destroy']
              MU::Cloud::AWS::Server.waitForAMI(ami_id, region: @config['region'])
              MU.log "AMI #{ami_id} ready, removing source node #{node}"
              MU::Cloud::AWS::Server.terminateInstance(id: @cloud_id, region: @config['region'], deploy_id: @deploy.deploy_id, mu_name: @mu_name)
              destroy
            end
          end

          MU::MommaCat.unlock(@cloud_id+"-groom")
        end

        def cloud_desc
          max_retries = 5
          retries = 0
          if !@cloud_id.nil?
            begin
              return MU::Cloud::Google.compute.get_instance(
                @config['project'],
                @config['availability_zone'],
                @cloud_id
              )
              return nil
            end
          end
          nil
        end

        # Return the IP address that we, the Mu server, should be using to access
        # this host via the network. Note that this does not factor in SSH
        # bastion hosts that may be in the path, see getSSHConfig if that's what
        # you need.
        def canonicalIP
          mu_name, config, deploydata = describe(cloud_id: @cloud_id)

          if !cloud_desc
            raise MuError, "Couldn't retrieve cloud descriptor for server #{self}"
          end

          private_ips = []
          public_ips = []
          cloud_desc.network_interfaces.each { |iface|
            private_ips << iface.network_ip
            if iface.access_configs
              iface.access_configs.each { |acfg|
                public_ips << acfg.nat_ip if acfg.nat_ip
              }
            end
          }

          # Our deploydata gets corrupted often with server pools, this will cause us to use the wrong IP to identify a node
          # which will cause us to create certificates, DNS records and other artifacts with incorrect information which will cause our deploy to fail.
          # The cloud_id is always correct so lets use 'cloud_desc' to get the correct IPs
          if MU::Cloud::Google::VPC.haveRouteToInstance?(cloud_desc) or public_ips.size == 0
            @config['canonical_ip'] = private_ips.first
            return private_ips.first
          else
            @config['canonical_ip'] = public_ips.first
            return public_ips.first
          end
        end

        # Retrieves the Cloud provider's randomly generated Windows password
        # Will only work on stock Amazon Windows AMIs or custom AMIs that where created with Administrator Password set to random in EC2Config
        # return [String]: A password string.
        def getWindowsAdminPassword
          if @cloud_id.nil?
            node, config, deploydata = describe
            @cloud_id = cloud_desc.instance_id
          end
          ssh_keydir = "#{Etc.getpwuid(Process.uid).dir}/.ssh"
          ssh_key_name = @deploy.ssh_key_name

          retries = 0
          MU.log "Waiting for Windows instance password to be set by Amazon and flagged as available from the API. Note- if you're using a source AMI that already has its password set, this may fail. You'll want to set use_cloud_provider_windows_password to false if this is the case.", MU::NOTICE
          begin
            MU::Cloud::AWS.ec2(@config['region']).wait_until(:password_data_available, instance_id: @cloud_id) do |waiter|
              waiter.max_attempts = 60
              waiter.before_attempt do |attempts|
                MU.log "Waiting for Windows password data to be available for node #{@mu_name}", MU::NOTICE if attempts % 5 == 0
              end
              # waiter.before_wait do |attempts, resp|
              # throw :success if resp.data.password_data and !resp.data.password_data.empty?
              # end
            end
          rescue Aws::Waiters::Errors::TooManyAttemptsError => e
            if retries < 2
              retries = retries + 1
              MU.log "wait_until(:password_data_available, instance_id: #{@cloud_id}) in #{@config['region']} never got a good response, retrying (#{retries}/2)", MU::WARN, details: e.inspect
              retry
            else
              MU.log "wait_until(:password_data_available, instance_id: #{@cloud_id}) in #{@config['region']} never returned- this image may not be configured to have its password set by AWS.", MU::ERR
              return nil
            end
          end

          resp = MU::Cloud::AWS.ec2(@config['region']).get_password_data(instance_id: @cloud_id)
          encrypted_password = resp.password_data

          # Note: This is already implemented in the decrypt_windows_password API call
          decoded = Base64.decode64(encrypted_password)
          pem_bytes = File.open("#{ssh_keydir}/#{ssh_key_name}", 'rb') { |f| f.read }
          private_key = OpenSSL::PKey::RSA.new(pem_bytes)
          decrypted_password = private_key.private_decrypt(decoded)
          return decrypted_password
        end

        # Add a volume to this instance
        # @param dev [String]: Device name to use when attaching to instance
        # @param size [String]: Size (in gb) of the new volume
        # @param type [String]: Cloud storage type of the volume, if applicable
        def addVolume(dev, size, type: "gp2")
          if @cloud_id.nil? or @cloud_id.empty?
            MU.log "#{self} didn't have a #{@cloud_id}, couldn't determine 'active?' status", MU::ERR
            return true
          end
          az = nil
          MU::Cloud::AWS.ec2(@config['region']).describe_instances(
            instance_ids: [@cloud_id]
          ).reservations.each { |resp|
            if !resp.nil? and !resp.instances.nil?
              resp.instances.each { |instance|
              az = instance.placement.availability_zone
                instance.block_device_mappings.each { |vol|
                  if vol.device_name == dev
                    MU.log "A volume #{dev} already attached to #{self}, skipping", MU::NOTICE
                    return
                  end
                }
              }
            end
          }
          MU.log "Creating #{size}GB #{type} volume on #{dev} for #{@cloud_id}"
          creation = MU::Cloud::AWS.ec2(@config['region']).create_volume(
            availability_zone: az,
            size: size,
            volume_type: type
          )
          begin
            sleep 3
            creation = MU::Cloud::AWS.ec2(@config['region']).describe_volumes(volume_ids: [creation.volume_id]).volumes.first
            if !["creating", "available"].include?(creation.state)
              raise MuError, "Saw state '#{creation.state}' while creating #{size}GB #{type} volume on #{dev} for #{@cloud_id}"
            end
          end while creation.state != "available"

          MU::MommaCat.listStandardTags.each_pair { |key, value|
            MU::MommaCat.createTag(creation.volume_id, key, value, region: @config['region'])
          }
          MU::MommaCat.createTag(creation.volume_id, "Name", "#{MU.deploy_id}-#{@config["name"].upcase}-#{dev.upcase}", region: @config['region'])

          attachment = MU::Cloud::AWS.ec2(@config['region']).attach_volume(
            device: dev,
            instance_id: @cloud_id,
            volume_id: creation.volume_id
          )

          begin
            sleep 3
            attachment = MU::Cloud::AWS.ec2(@config['region']).describe_volumes(volume_ids: [attachment.volume_id]).volumes.first.attachments.first
            if !["attaching", "attached"].include?(attachment.state)
              raise MuError, "Saw state '#{creation.state}' while creating #{size}GB #{type} volume on #{dev} for #{@cloud_id}"
            end
          end while attachment.state != "attached"
        end

        # Determine whether the node in question exists at the Cloud provider
        # layer.
        # @return [Boolean]
        def active?
          if @cloud_id.nil? or @cloud_id.empty?
            MU.log "#{self} didn't have a #{@cloud_id}, couldn't determine 'active?' status", MU::ERR
            return true
          end
          begin
            MU::Cloud::AWS.ec2(@config['region']).describe_instances(
                instance_ids: [@cloud_id]
            ).reservations.each { |resp|
              if !resp.nil? and !resp.instances.nil?
                resp.instances.each { |instance|
                  if instance.state.name == "terminated" or
                      instance.state.name == "terminating"
                    return false
                  end
                  return true
                }
              end
            }
          rescue Aws::EC2::Errors::InvalidInstanceIDNotFound
            return false
          end
          return false
        end

        # Remove all instances associated with the currently loaded deployment. Also cleans up associated volumes, droppings in the MU master's /etc/hosts and ~/.ssh, and in whatever Groomer was used.
        # @param noop [Boolean]: If true, will only print what would be done
        # @param ignoremaster [Boolean]: If true, will remove resources not flagged as originating from this Mu server
        # @param region [String]: The cloud provider region
        # @return [void]
        def self.cleanup(noop: false, ignoremaster: false, region: $MU_CFG['google']['region'], skipsnapshots: false, onlycloud: false, flags: {})
          flags["project"] ||= MU::Cloud::Google.defaultProject
# XXX make damn sure MU.deploy_id is set

          MU::Cloud::Google.listAZs(region).each { |az|
            disks = []
            resp = MU::Cloud::Google.compute.list_instances(
              flags["project"],
              az,
              filter: "description eq #{MU.deploy_id}"
            )
            if !resp.items.nil? and resp.items.size > 0
              resp.items.each { |instance|
                MU.log "Terminating instance #{instance.id} #{instance.name})"
                if !instance.disks.nil? and instance.disks.size > 0
                  instance.disks.each { |disk|
                    disks << disk if !disk.auto_delete
                  }
                end
                deletia = MU::Cloud::Google.compute.delete_instance(
                  flags["project"],
                  az,
                  instance.name
                )
# XXX wait-loop on pending?
                pp deletia
              }
            end

            if disks.size > 0
# XXX make sure we don't miss anything that got created with dumb flags
            end
# XXX honor snapshotting
            resp = MU::Cloud::Google.compute.list_disks(
              flags["project"],
              az,
              filter: "description eq #{MU.deploy_id}"
            )
            if !resp.nil? and !resp.items.nil?
              resp.items.each { |disk|
                MU.log "Deleting disk #{disk.name}"
                begin
                  resp = MU::Cloud::Google.compute.delete_disk(
                    flags["project"],
                    az,
                    disk.name
                  )
                rescue ::Google::Apis::ClientError => e
                  MU.log "Disk #{disk.name} seems to be deleting already, skipping", MU::NOTICE
                end
              }
            end
          }
        end

        # Cloud-specific pre-processing of {MU::Config::BasketofKittens::servers}, bare and unvalidated.
        # @param server [Hash]: The resource to process and validate
        # @param configurator [MU::Config]: The overall deployment configurator of which this resource is a member
        # @return [Boolean]: True if validation succeeded, False otherwise
        def self.validateConfig(server, configurator)
          ok = true

          sizepattern = /^(f|g|n){1,2}[0-9]-(micro|small|standard|highmem|highcpu)(-(1|2|4|8|16|32|64))?$/
          if server["size"].nil? or !server["size"].match(sizepattern)
            MU.log "Invalid size '#{server['size']}' for a Google Compute instance. Must match: #{sizepattern}", MU::ERR
            ok = false
          end

          # If we're not targeting an availability zone, pick one randomly
          if !server['availability_zone']
            server['availability_zone'] = MU::Cloud::Google.listAZs(server['region']).sample
          end

          subnets = nil
          if !server['vpc']
            vpcs = MU::Cloud::Google::VPC.find
            if vpcs["default"]
              server["vpc"] ||= {}
              server["vpc"]["vpc_id"] = vpcs["default"].self_link
              subnets = vpcs["default"].subnetworks
              MU.log "No VPC specified for Server #{server['name']}, using default VPC for project #{server['project']}", MU::NOTICE
            else
              ok = false
              MU.log "You must specify a target VPC when creating a Server", MU::ERR
            end
          end

          if !server['vpc']['subnet_id']
            if !subnets
              vpcs = MU::Cloud::Google::VPC.find(cloud_id: server["vpc"]["vpc_id"])
              subnets = vpcs["default"].subnetworks.sample
            end
            server['vpc']['subnet_id'] = subnets.delete_if { |subnet|
              !subnet.match(/regions\/#{Regexp.quote(server['region'])}\/subnetworks/)
            }.sample
            if server['vpc']['subnet_id'].nil?
              ok = false
              MU.log "Failed to identify a subnet in my region (#{config['region']})", MU::ERR, details: server["vpc"]["vpc_id"]
            end
          end

          if server['image_id'].nil?
            if MU::Config.google_images.has_key?(server['platform'])
              server['image_id'] = configurator.getTail("server"+server['name']+"Image", value: MU::Config.google_images[server['platform']], prettyname: "server"+server['name']+"Image", cloudtype: "Google::::Apis::ComputeBeta::Image")
            else
              MU.log "No image specified for #{server['name']} and no default available for platform #{server['platform']}", MU::ERR, details: server
              ok = false
            end
          end

          img_proj = server['image_id'].to_s.gsub(/projects\/(.*?)\/.*/, '\1')
          img_name = server['image_id'].to_s.gsub(/.*?\/([^\/]+)$/, '\1')
          images = MU::Cloud::Google.compute.list_images(img_proj, filter: "name eq #{img_name}")
          if images.nil? or images.items.nil? or images.items.size == 0
            MU.log "Image #{server['image_id']} for server #{server['name']} does not appear to exist", MU::ERR
            ok = false
          end

          ok
        end

        private

      end #class
    end #class
  end
end #module
