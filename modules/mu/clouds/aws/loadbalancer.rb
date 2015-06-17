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
	class Cloud
	class AWS
		# A load balancer as configured in {MU::Config::BasketofKittens::loadbalancers}
		class LoadBalancer
			# The {MU::Config::BasketofKittens} name for a single resource of this class.
			def self.cfg_name; "loadbalancer".freeze end
			# The {MU::Config::BasketofKittens} name for a collection of resources of this class.
			def self.cfg_plural; "loadbalancers".freeze end
			# Whether {MU::Deploy} should hold creation of other resources which depend on this resource until the latter has been created.
			def self.deps_wait_on_my_creation; true.freeze end
			# Whether {MU::Deploy} should hold creation of this resource until resources on which it depends have been fully created and deployed.
			def self.waits_on_parent_completion; false.freeze end

			@deploy = nil
			@lb = nil

			# @param mommacat [MU::MommaCat]: A {MU::Mommacat} object containing the deploy of which this resource is/will be a member.
			# @param kitten_cfg [Hash]: The fully parsed and resolved {MU::Config} resource descriptor as defined in {MU::Config::BasketofKittens::loadbalancers}
			def initialize(mommacat: mommacat, kitten_cfg: kitten_cfg)
				@deploy = mommacat
				@loadbalancer = kitten_cfg
				MU.setVar("curRegion", @loadbalancer['region']) if !@loadbalancer['region'].nil?
			end

			# Called automatically by {MU::Deploy#createResources}
			def create
				MU::Cloud.artifact("AWS", :DNSZone)
				MU.setVar("curRegion", @loadbalancer['region']) if !@loadbalancer['region'].nil?
				lb_name = MU::MommaCat.getResourceName(@loadbalancer["name"], max_length: 32, need_unique_string: true)
				lb_name.gsub!(/[^\-a-z0-9]/i, "-") # LB naming rules

				if @loadbalancer["zones"] == nil
					@loadbalancer["zones"] = MU::Cloud::AWS.listAZs(@loadbalancer['region'])
					MU.log "Using zones from #{@loadbalancer['region']}", MU::DEBUG, details: @loadbalancer['zones']
				end

				lb_options = {
					load_balancer_name: lb_name,
					tags: []
				}
				MU::MommaCat.listStandardTags.each_pair { |name, value|
					lb_options[:tags] << { key: name, value: value }
				}
				if !@loadbalancer['tags'].nil?
					@loadbalancer['tags'].each { |tag|
						lb_options[:tags] << { key: tag['key'], value: tag['value'] }
					}
				end


				sgs = Array.new
				if !@loadbalancer["add_firewall_rules"].nil?
					@loadbalancer["add_firewall_rules"].each { |acl|
						sg = MU::Cloud::AWS::FirewallRule.find(sg_id: acl["rule_id"], name: acl["rule_name"])
						if sg.nil?
							MU.log "Couldn't find dependent security group #{acl} for Load Balancer #{@loadbalancer['name']}", MU::ERR, details: MU.mommacat.deployment['firewall_rules']
							raise MuError, "deploy failure"
						end
						sgs << sg.group_id
					}
				end

				if @loadbalancer["vpc"] != nil
					vpc_id, subnet_ids = MU::Cloud::AWS::VPC.parseVPC(@loadbalancer["vpc"])
					sgs << MU::Cloud::AWS::FirewallRule.setAdminSG(vpc_id: vpc_id)
					lb_sg = MU::Cloud::AWS::FirewallRule.createEc2SG(@loadbalancer['name'], @loadbalancer['ingress_rules'], description: "Load Balancer #{lb_name}", vpc_id: vpc_id)
					sgs << lb_sg
					lb_options[:subnets] = subnet_ids
					lb_options[:security_groups] = sgs
					if @loadbalancer["private"]
						lb_options[:scheme] = "internal"
					end
				else
					lb_options[:availability_zones] = @loadbalancer["zones"]
				end

				listeners = Array.new
				@loadbalancer["listeners"].each { |listener|
					listen_struct = {
						:load_balancer_port => listener["lb_port"],
						:protocol => listener["lb_protocol"],
						:instance_port => listener["instance_port"],
						:instance_protocol => listener["instance_protocol"]
					}
					listen_struct[:ssl_certificate_id] = listener["ssl_certificate_id"] if !listener["ssl_certificate_id"].nil?
					listeners << listen_struct
				}
				lb_options[:listeners ] = listeners

				MU.log "Creating Load Balancer #{lb_name}", details: lb_options
				zones_to_try = @loadbalancer["zones"]
				retries = 0
				begin
					resp = MU::Cloud::AWS.elb.create_load_balancer(lb_options)
				rescue Aws::ElasticLoadBalancing::Errors::ValidationError, Aws::ElasticLoadBalancing::Errors::SubnetNotFound => e
					if zones_to_try.size > 0
						MU.log "Got #{e.inspect} when creating #{lb_name} retrying with individual AZs in case that's the problem", MU::WARN
						lb_options[:availability_zones] = [zones_to_try.pop]
						retry
					else
						raise MuError, "#{e.inspect} when creating #{lb_name}"
					end
				rescue Aws::ElasticLoadBalancing::Errors::InvalidSecurityGroup => e
					if retries < 5
						MU.log "#{e.inspect}, waiting then retrying", MU::WARN
						sleep 10
						retries = retries + 1
						retry
					else
						raise MuError, "#{e.inspect} when creating #{lb_name}"
					end
				end
				MU.log "Load Balancer is at #{resp.dns_name}"

				if zones_to_try.size < @loadbalancer["zones"].size
					zones_to_try.each { |zone|
						begin
							MU::Cloud::AWS.elb.enable_availability_zones_for_load_balancer(
								load_balancer_name: lb_name,
								availability_zones: [zone]
							)
						rescue Aws::ElasticLoadBalancing::Errors::ValidationError => e
							MU.log "Couldn't enable Availability Zone #{zone} for Load Balancer #{lb_name} (#{e.message})", MU::WARN
						end
					}
				end

				if !@loadbalancer['healthcheck'].nil?
					MU.log "Configuring custom health check for ELB #{lb_name}", details: @loadbalancer['healthcheck']
					MU::Cloud::AWS.elb.configure_health_check(
						load_balancer_name: lb_name,
						health_check: {
							target: @loadbalancer['healthcheck']['target'],
							interval: @loadbalancer['healthcheck']['interval'],
							timeout: @loadbalancer['healthcheck']['timeout'],
							unhealthy_threshold: @loadbalancer['healthcheck']['unhealthy_threshold'],
							healthy_threshold: @loadbalancer['healthcheck']['healthy_threshold']
						}
					)
				end

				if @loadbalancer['cross_zone_unstickiness']
					MU.log "Enabling cross-zone un-stickiness on #{resp.dns_name}"
					MU::Cloud::AWS.elb.modify_load_balancer_attributes(
						load_balancer_name: lb_name,
						load_balancer_attributes: {
							cross_zone_load_balancing: {
								enabled: true
							}
						}
					)
				end

				if !@loadbalancer['idle_timeout'].nil?
					MU.log "Setting idle timeout to #{@loadbalancer['idle_timeout']} #{resp.dns_name}"
					MU::Cloud::AWS.elb.modify_load_balancer_attributes(
						load_balancer_name: lb_name,
						load_balancer_attributes: {
							connection_settings: {
								idle_timeout: @loadbalancer['idle_timeout']
							}
						}
					)
				end

				if !@loadbalancer['connection_draining_timeout'].nil?
					if @loadbalancer['connection_draining_timeout'] >= 0
						MU.log "Setting connection draining timeout to #{@loadbalancer['connection_draining_timeout']} on #{resp.dns_name}"
						MU::Cloud::AWS.elb.modify_load_balancer_attributes(
							load_balancer_name: lb_name,
							load_balancer_attributes: {
								connection_draining: {
									enabled: true,
									timeout: @loadbalancer['connection_draining_timeout']
								}
							}
						)
					else
						MU.log "Disabling connection draining on #{resp.dns_name}"
						MU::Cloud::AWS.elb.modify_load_balancer_attributes(
							load_balancer_name: lb_name,
							load_balancer_attributes: {
								connection_draining: {
									enabled: false
								}
							}
						)
					end
				end


				if !@loadbalancer['access_log'].nil?
					MU.log "Setting access log params for #{resp.dns_name}", details: @loadbalancer['access_log']
					MU::Cloud::AWS.elb.modify_load_balancer_attributes(
						load_balancer_name: lb_name,
						load_balancer_attributes: {
							access_log: {
								enabled: @loadbalancer['access_log']['enabled'],
								emit_interval: @loadbalancer['access_log']['emit_interval'],
								s3_bucket_name: @loadbalancer['access_log']['s3_bucket_name'],
								s3_bucket_prefix: @loadbalancer['access_log']['s3_bucket_prefix']
							}
						}
					)
				end

				if !@loadbalancer['lb_cookie_stickiness_policy'].nil?
					MU.log "Setting ELB cookie stickiness policy for #{resp.dns_name}", details: @loadbalancer['lb_cookie_stickiness_policy']
					cookie_policy = {
						load_balancer_name: lb_name,
						policy_name: @loadbalancer['lb_cookie_stickiness_policy']['name']
					}
					if !@loadbalancer['lb_cookie_stickiness_policy']['timeout'].nil?
						cookie_policy[:cookie_expiration_period] = @loadbalancer['lb_cookie_stickiness_policy']['timeout']
					end
					MU::Cloud::AWS.elb.create_lb_cookie_stickiness_policy(cookie_policy)
					lb_policy_names = Array.new
					lb_policy_names << @loadbalancer['lb_cookie_stickiness_policy']['name']
					listener_policy = {
						load_balancer_name: lb_name,
						policy_names: lb_policy_names
					}
					lb_options[:listeners].each do |listener|
						if listener[:protocol].upcase == 'HTTP' or listener[:protocol].upcase == 'HTTPS'
							listener_policy[:load_balancer_port] = listener[:load_balancer_port]
							MU::Cloud::AWS.elb.set_load_balancer_policies_of_listener(listener_policy)
						end
					end
				end

				if !@loadbalancer['app_cookie_stickiness_policy'].nil?
					MU.log "Setting application cookie stickiness policy for #{resp.dns_name}", details: @loadbalancer['app_cookie_stickiness_policy']
					cookie_policy = {
						load_balancer_name: lb_name,
						policy_name: @loadbalancer['app_cookie_stickiness_policy']['name'],
						cookie_name: @loadbalancer['app_cookie_stickiness_policy']['cookie']
					}
					MU::Cloud::AWS.elb.create_app_cookie_stickiness_policy(cookie_policy)
					lb_policy_names = Array.new
					lb_policy_names << @loadbalancer['app_cookie_stickiness_policy']['name']
					listener_policy = {
						load_balancer_name: lb_name,
						policy_names: lb_policy_names
					}
					lb_options[:listeners].each do |listener|
						if listener[:protocol].upcase == 'HTTP' or listener[:protocol].upcase == 'HTTPS'
							listener_policy[:load_balancer_port] = listener[:load_balancer_port]
							MU::Cloud::AWS.elb.set_load_balancer_policies_of_listener(listener_policy)
						end
					end
				end
				MU::Cloud::AWS::DNSZone.genericDNSEntry(lb_name, "#{resp.dns_name}.", MU::Cloud::AWS::LoadBalancer, sync_wait: @loadbalancer['dns_sync_wait'])
				if !@loadbalancer['dns_records'].nil?
					@loadbalancer['dns_records'].each { |dnsrec|
						dnsrec['name'] = lb_name.downcase if !dnsrec.has_key?('name')
					}
				end
				MU::Cloud::AWS::DNSZone.createRecordsFromConfig(@loadbalancer['dns_records'], target: resp.dns_name)

				deploy_struct = {
					"awsname" => lb_name,
					"dns" => resp.dns_name,
					"sgs" => lb_options[:security_groups],
					"listeners" => listeners
				}
				@deploy.notify("loadbalancers", @loadbalancer["name"], deploy_struct)
			end

			# Register a Server node with an existing LoadBalancer.
			#
			# @param lb_name [String] The name of a LoadBalancer with which to register.
			# @param instance_id [String] A node to register.
			# @param region [String]: The cloud provider region
			def self.registerInstance(lb_name, instance_id, region: MU.curRegion)
				raise MuError, "MU::Cloud::AWS::LoadBalancer.registerInstance requires a Load Balancer name and an instance id" if lb_name.nil? or instance_id.nil?
				MU::Cloud::AWS.elb(region).register_instances_with_load_balancer(
					load_balancer_name: lb_name,
					instances: [
						{ instance_id: instance_id }
					]
				)
			end

			# Remove all load balancers associated with the currently loaded deployment.
			# @param noop [Boolean]: If true, will only print what would be done
			# @param ignoremaster [Boolean]: If true, will remove resources not flagged as originating from this Mu server
			# @param region [String]: The cloud provider region
			# @return [void]
			def self.cleanup(noop = false, ignoremaster = false, region: MU.curRegion)
				raise MuError, "Can't touch ELBs without MU-ID" if MU.mu_id.nil? or MU.mu_id.empty?

				resp = MU::Cloud::AWS.elb(region).describe_load_balancers
				resp.load_balancer_descriptions.each { |lb|
					tags = MU::Cloud::AWS.elb(region).describe_tags(load_balancer_names: [lb.load_balancer_name]).tag_descriptions.first.tags
					muid_match = false
					mumaster_match = false
					saw_tags = []
					if !tags.nil?
						tags.each { |tag|
							saw_tags << tag.key
							muid_match = true if tag.key == "MU-ID" and tag.value == MU.mu_id
							mumaster_match = true if tag.key == "MU-MASTER-IP" and tag.value == MU.mu_public_ip
						}
					end
					if saw_tags.include?("MU-ID") and (saw_tags.include?("MU-MASTER-IP") or ignoremaster)
						if muid_match and (mumaster_match or ignoremaster)
							MU::Cloud::AWS::DNSZone.genericDNSEntry(lb.load_balancer_name, lb.dns_name, MU::Cloud::AWS::LoadBalancer, delete: true)
							MU.log "Removing Elastic Load Balancer #{lb.load_balancer_name}"
							MU::Cloud::AWS.elb(region).delete_load_balancer(load_balancer_name: lb.load_balancer_name) if !noop
						end
						next
					end
					if lb.load_balancer_name.match(/^#{MU.mu_id}/)
						MU.log "Removing Elastic Load Balancer #{lb.load_balancer_name} by name match (tags unavailable). This behavior is DEPRECATED and will be removed in a future release.", MU::WARN
						resp = MU::Cloud::AWS.elb(region).delete_load_balancer(load_balancer_name: lb.load_balancer_name) if !noop
					end
				}

				return nil
			end



			# Find a LoadBalancer, given one or more pieces of identifying information.
			#
			# @param name [String] The MU resource name of a LoadBalancer to find.
			# @param lb_id [String] The cloud provider's internal identifier of a LoadBalancer to find.
			# @param dns_name [String] The DNS name of a LoadBalancer to Find.
			# @param region [String]: The cloud provider region
			# @return [OpenStruct, nil] The cloud provider's description of the LoadBalancer, or nil if none was found.
			def self.find(name: name = nil, lb_id: lb_id = nil, dns_name: dns_name = nil, region: MU.curRegion)
				return nil if !name and !dns_name and !lb_id
				if !name.nil? and !MU.mommacat.deployment.nil? and !MU.mommacat.deployment['loadbalancers'].nil?
					lb_id = MU.mommacat.deployment['loadbalancers'][name]['awsname'] if lb_id.nil?
					dns_name = MU.mommacat.deployment['loadbalancers'][name]['dns'] if dns_name.nil?
				end

				return nil if lb_id.nil? and dns_name.nil?

				resp = MU::Cloud::AWS.elb(region).describe_load_balancers
				resp.load_balancer_descriptions.each { |lb|
					return lb if !lb_id.nil? and lb.load_balancer_name == lb_id
					return lb if !dns_name.nil? and lb.dns_name == dns_name
				}

				return nil

			end
		end
	end
	end
end
