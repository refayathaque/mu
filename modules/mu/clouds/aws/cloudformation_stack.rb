# Copyright:: Copyright (c) 2014 eGlobalTech, Inc., all rights reserved
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

module MU

		class AWS

		# An Amazon CloudFormation stack as configured in {MU::Config::BasketofKittens::cloudformation_stacks}
		class CloudFormation

			# The {MU::Config::BasketofKittens} name for a single resource of this class.
			def self.cfg_name; "cloudformation_stack".freeze end
			# The {MU::Config::BasketofKittens} name for a collection of resources of this class.
			def self.cfg_plural; "cloudformation_stacks".freeze end
			# Whether {MU::Deploy} should hold creation of other resources which depend on this resource until the latter has been created.
			def self.deps_wait_on_my_creation; true.freeze end
			# Whether {MU::Deploy} should hold creation of this resource until resources on which it depends have been fully created and deployed.
			def self.waits_on_parent_completion; false.freeze end

			@deploy = nil
			@stack = nil

			# @param deployer [MU::Deploy]: A {MU::Deploy} object, typically associated with an in-progress deployment.
			# @param cloudformation_stack [Hash]: The full {MU::Config} resource declaration as defined in {MU::Config::BasketofKittens::cloudformation_stacks}
			def initialize(deployer, cloudformation_stack)
				@deploy = deployer
				@stack = cloudformation_stack
				MU.setVar("curRegion", @stack['region']) if !@stack['region'].nil?
			end


			# Called automatically by {MU::Deploy#createResources}
			def create
				flag="SUCCESS"
				MU.setVar("curRegion", @stack['region']) if !@stack['region'].nil?
				region = @stack['region']
				server=@stack["name"]
				stack_name = getStackName(@stack["name"])

				if @stack["type"] !=nil && @stack["type"]=="existing" then 
# XXX this isn't correct, need to go through and list its resources
					return @stack
				end
				@stack["time"]=@deploy.timestamp

				begin

					stack_descriptor = {
						:stack_name => stack_name,
						:on_failure => @stack["on_failure"],
						:tags=> [
							{
								:key => "Name",
								:value => MU.appname.upcase + "-" + MU.environment.upcase + "-" + MU.timestamp.upcase + "-" + @stack['name'].upcase
							},
							{
								:key => "MU-ID",
								:value => MU.mu_id
							}
						]
					}

					keypairname, ssh_private_key, ssh_public_key = @deploy.SSHKey

					parameters = Array.new
					if !@stack["parameters"].nil?
						@stack["parameters"].each { |parameter|
							parameters << {
								:parameter_key =>parameter["parameter_key"],
								:parameter_value=>parameter["parameter_value"]
							}
		        }
					end
					if @stack["pass_deploy_key_as"] != nil
						parameters << {
							:parameter_key => @stack["pass_deploy_key_as"],
							:parameter_value => keypairname
						}
					end
					stack_descriptor[:parameters] = parameters

					if @stack["template_file"] != nil then
						# pass absolute path
						if !@stack["template_file"].nil?
							if @stack["template_file"].match(/^\//)
								MU.log "Loading Cloudformation template from #{@stack["template_file"]}"
								template_body = File.read(@stack["template_file"])
							else
								path = File.expand_path(File.dirname(MU::Config.config_path)+"/"+@stack["template_file"])
								MU.log "Loading Cloudformation template from #{path}"
								template_body = File.read(path)
							end
						else
							# json file and template path is same            
							file_dir =File.dirname(ARGV[0])
							if File.exists?file_dir+"/"+@stack["template_file"] then
								template_body=File.read(file_dir+"/"+@stack["template_file"]);
							end
						end
						stack_descriptor[:template_body] = template_body.to_s
					end 

					if @stack["template_url"] != nil then
						if @stack["template_file"] == nil then
							stack_descriptor[:template_url] = @stack["template_url"]
						end 
					end 
    
					MU.log "Creating CloudFormation stack '#{@stack['name']}'", details: stack_descriptor
					res = MU::AWS.cloudformation(region).create_stack(stack_descriptor);
					@deploy.notify("cloudformations", @stack["name"], @stack)

					sleep(10);
					stack_response = MU::AWS.cloudformation(region).describe_stacks({:stack_name=>stack_name}).stacks.first
					attempts = 0
					begin
						if attempts % 5 == 0
							MU.log "Waiting for CloudFormation stack '#{@stack['name']}' to be ready...", MU::NOTICE
						else
							MU.log "Waiting for CloudFormation stack '#{@stack['name']}' to be ready...", MU::DEBUG
						end
						stack_response =MU::AWS.cloudformation(region).describe_stacks({:stack_name=>stack_name}).stacks.first
						sleep 60
					end while stack_response.stack_status == "CREATE_IN_PROGRESS" 

					if stack_response.stack_status == "CREATE_FAILED" then
						showStackError server
						flag="FAIL"
					end
				rescue Aws::EC2::Errors::ServiceError => e
        
					flag="FAIL"
					MU.log "#{stack_name} creation failed (#{e.inspect})", MU::ERR, details: e.backtrace

				end

				if flag == "FAIL" then
					stack_response = MU::AWS.cloudformation(region).delete_stack({:stack_name=>stack_name})
					exit 1
				end 

				MU.log "CloudFormation stack '#{@stack['name']}' complete"

				begin
					resources = MU::AWS.cloudformation(region).describe_stack_resources(:stack_name=> stack_name)

					resources[:stack_resources].each { |resource|

						case resource.resource_type
							when "AWS::EC2::Instance"
								MU::MommaCat.createStandardTags(resource.physical_resource_id)
								instance_name = MU.mu_id+"-"+@stack['name']+"-"+resource.logical_resource_id
								MU::MommaCat.createTag(resource.physical_resource_id, "Name", instance_name)

								instance = MU::Server.notifyDeploy(
									@stack['name']+"-"+resource.logical_resource_id,
									resource.physical_resource_id
								)
							
								MU::MommaCat.addHostToSSHConfig(
									instance_name,
									instance["private_ip_address"],
									instance["private_dns_name"],
# XXX this is a hack-around
									user: "ec2-user",
									public_dns: instance["public_ip_address"],
									public_ip: instance["public_dns_name"],
									key_name: instance["key_name"]
								)

								mu_zone, junk = MU::DNSZone.find(name: "mu")
								if !mu_zone.nil?
									MU::DNSZone.genericDNSEntry(instance_name, instance["private_ip_address"], MU::Server)
								else
									MU::MommaCat.addInstanceToEtcHosts(instance["public_ip_address"], instance_name)
								end

							when "AWS::EC2::SecurityGroup"
								MU::MommaCat.createStandardTags(resource.physical_resource_id)
								MU::MommaCat.createTag(resource.physical_resource_id, "Name", MU.mu_id+"-"+@stack['name']+'-'+resource.logical_resource_id)
								MU::FirewallRule.notifyDeploy(
									@stack['name']+"-"+resource.logical_resource_id,
									resource.physical_resource_id
								)
							when  "AWS::EC2::Subnet"
								MU::MommaCat.createStandardTags(resource.physical_resource_id)
								MU::MommaCat.createTag(resource.physical_resource_id, "Name", MU.mu_id+"-"+@stack['name']+'-'+resource.logical_resource_id)
								data = {
									"cloudformation_stack" => @stack["name"],
									"subnet_id" => resource.physical_resource_id,
								}
								@deploy.notify("subnets", @stack['name']+"-"+resource.logical_resource_id, data)
							when "AWS::EC2::VPC"
								MU::MommaCat.createStandardTags(resource.physical_resource_id)
								MU::MommaCat.createTag(resource.physical_resource_id, "Name", MU.mu_id+"-"+@stack['name']+'-'+resource.logical_resource_id)
								data = {
									"cloudformation_stack" => @stack["name"],
									"vpc_id" => resource.physical_resource_id,
								}
								@deploy.notify("vpcs", @stack['name']+"-"+resource.logical_resource_id, data)
							when "AWS::EC2::InternetGateway"
								MU::MommaCat.createStandardTags(resource.physical_resource_id)
								MU::MommaCat.createTag(resource.physical_resource_id, "Name", MU.mu_id+"-"+@stack['name']+'-'+resource.logical_resource_id)
							when "AWS::EC2::RouteTable"
								MU::MommaCat.createStandardTags(resource.physical_resource_id)
								MU::MommaCat.createTag(resource.physical_resource_id, "Name", MU.mu_id+"-"+@stack['name']+'-'+resource.logical_resource_id)

							# The rest of these aren't anything we act on
							when "AWS::EC2::Route"
								MU.log resource.resource_type, MU::DEBUG
							when "AWS::EC2::EIP"
								MU.log resource.resource_type, MU::DEBUG
							when "AWS::EC2::SecurityGroupIngress"
								MU.log resource.resource_type, MU::DEBUG
							when "AWS::EC2::SubnetRouteTableAssociation"
								MU.log resource.resource_type, MU::DEBUG
							when "AWS::EC2::VPCGatewayAttachment"
								MU.log resource.resource_type, MU::DEBUG
							when "AWS::IAM::InstanceProfile"
								MU.log resource.resource_type, MU::DEBUG
							when "AWS::IAM::Role"
								MU.log resource.resource_type, MU::DEBUG
							else
								MU.log "Don't know what to do with #{resource.resource_type}, skipping it", MU::WARN
						end
					}
				rescue Aws::CloudFormation::Errors::ValidationError => e
					MU.log "Error processing created resource in CloudFormation stack #{stack_name}: #{e.inspect}", MU::ERR, details: e.backtrace
				end
			end

			# Remove all CloudFormation stacks associated with the currently loaded deployment.
			# @param noop [Boolean]: If true, will only print what would be done
			# @param ignoremaster [Boolean]: If true, will remove resources not flagged as originating from this Mu server
			# @param wait [Boolean]: Block on the removal of this stack; will continue in the background otherwise.
			# @param region [String]: The cloud provider region
			# @return [void]
			def self.cleanup(noop = false, ignoremaster = false, wait: false, region: MU.curRegion)
# XXX needs to check tags instead of name- possible?
				resp = MU::AWS.cloudformation(region).describe_stacks
				resp.stacks.each { |stack|
					ok = false
					stack.tags.each { |tag|
						ok = true if (tag.key == "MU-ID") and tag.value == MU.mu_id
					}
					if ok
						MU.log "Deleting CloudFormation stack #{stack.stack_name})"
						next if noop
						if stack.stack_status != "DELETE_IN_PROGRESS"
							MU::AWS.cloudformation(region).delete_stack(stack_name: stack.stack_name)
						end
						if wait
							last_status = ""
							max_retries = 10
							retries = 0
							mystack = nil
							begin
								mystack = nil
							  sleep 30
								retries = retries + 1
								desc = MU::AWS.cloudformation(region).describe_stacks(stack_name: stack.stack_name)
								if desc.size > 0
									mystack = desc.first.stacks.first
									if mystack.size > 0 and mystack.stack_status == "DELETE_FAILED"
										MU.log "Couldn't delete CloudFormation stack #{stack.stack_name}", MU::ERR, details: mystack.stack_status_reason
										return
									end
									last_status = mystack.stack_status_reason
									MU.log "Waiting for CloudFormation stack #{stack.stack_name} to delete (#{stack.stack_status})...", MU::NOTICE
								end
							rescue Aws::CloudFormation::Errors::ValidationError => e
								# this is ok, it means deletion finally succeeded
							
							end while !desc.nil? and desc.size > 0 and retries < max_retries

							if retries >= max_retries and !mystack.nil? and mystack.stack_status != "DELETED"
								MU.log "Failed to delete CloudFormation stack #{stack.stack_name}", MU::ERR
							end
						end

					end
				}
				return nil
			end

			private

			# Generate a MU-friendly name for a CloudFormation stack
			# @param stack [String]: The internal resource name of the stack
			# @return [String]
			def getStackName(stack) 
				stack_name = MU.mu_id + "-" + stack.upcase
				stack_name.gsub!(/[_\.]/, "-")
				return stack_name
			end

			# Log the Amazon-specific errors associated with a CloudFormation stack.
			# We have to query the AWS API explicitly to get this.
			# @param stack [String]: The internal resource name of the stack
			# @return [void]
			def showStackError(stack)
				region = stack['region']
				stack_name = getStackName(stack)
				begin
					resources = MU::AWS.cloudformation(region).describe_stack_resources(:stack_name => stack_name)

					MU.log "CloudFormation stack #{stack_name} failed", MU::ERR

					resources[:stack_resources].each { |resource|
						MU.log "#{resource.resource_type} #{resource.resource_status} #{resource.resource_status_reason }", MU::ERR
					}
				rescue Aws::CloudFormation::Errors::ValidationError => e
					MU.log e.inspect, MU::ERR, details: e.backtrace
				end
			end   

		end #class
	end #class
end #module
