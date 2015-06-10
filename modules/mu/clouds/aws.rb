
module MU
	class AWS
		# List the Availability Zones associated with a given Amazon Web Services
		# region. If no region is given, search the one in which this MU master
		# server resides.
		# @param region [String]: The region to search.	
		# @return [Array<String>]: The Availability Zones in this region.
		def listAZs(region = MU.curRegion)
			azs = MU::Config.listAZs(region)
			return azs
		end
		# (see #listAZs)
		def self.listAZs(region = MU.curRegion)
			if region
				azs = MU::AWS.ec2(region).describe_availability_zones(
					filters: [name: "region-name", values: [region]]
				)
			else
				azs = MU::AWS.ec2(region).describe_availability_zones
			end
			zones = Array.new
			azs.data.availability_zones.each { |az|
				zones << az.zone_name if az.state == "available"
			}
			return zones
		end

		# List the Amazon Web Services region names available to this account. The
		# region that is local to this Mu server will be listed first.
		# @return [Array<String>]
		def listRegions
			return MU::AWS.listRegions
		end
		# (see #listRegions)
		def self.listRegions
			regions = MU::AWS.ec2.describe_regions().regions.map{ |region| region.region_name }

			regions.sort! { |a, b|
				val = a <=> b
				if a == MU.myRegion
					val = -1
				elsif b == MU.myRegion
					val = 1
				end
				val
			}

			return regions
		end

		# Generate an EC2 keypair unique to this deployment, given a regular
		# OpenSSH-style public key and a name.
		# @param keyname [String]: The name of the key to create.
		# @param public_key [String]: The public key
		# @return [Array<String>]: keypairname, ssh_private_key, ssh_public_key
		def self.createEc2SSHKey(keyname, public_key)
			# We replicate this key in all regions
			MU::AWS.listRegions.each { |region|
				next if region == MU.myRegion
				MU.log "Replicating #{keyname} to #{region}", MU::DEBUG, details: @ssh_public_key
				MU::AWS.ec2(region).import_key_pair(
					key_name: keyname,
					public_key_material: public_key
				)
			}

# XXX This library code would be nicer... except it can't do PKCS8.
#			foo = OpenSSL::PKey::RSA.new(@ssh_private_key)
#			bar = foo.public_key

			sleep 3
		  return [keyname, keypair.key_material, @ssh_public_key]
		end
		

		# Wrapper class for the EC2 API, so that we can catch some common transient
		# endpoint errors without having to spray rescues all over the codebase.
		class Endpoint
			@api = nil
			@region = nil

			# Create an AWS API client
			# @param region [String]: Amazon region so we know what endpoint to use
			# @param api [String]: Which API are we wrapping?
			def initialize(region: MU.curRegion, api: "EC2")
				@region = region
				@api = Object.const_get("Aws::#{api}::Client").new(region: region)
			end

			# Catch-all for AWS client methods. Essentially a pass-through with some
			# rescues for known silly endpoint behavior.
			def method_missing(method_sym, *arguments)
				retries = 0
				begin
					MU.log "Calling #{method_sym} in #{@region}", MU::DEBUG, details: arguments[0]
					return @api.method(method_sym).call(arguments[0])
				rescue Aws::EC2::Errors::InternalError, Aws::EC2::Errors::RequestLimitExceeded, Aws::EC2::Errors::Unavailable => e
					retries = retries + 1
					debuglevel = MU::DEBUG
					interval = 5
					if retries < 5 and retries > 2
						debuglevel = MU::NOTICE
						interval = 10
					else
						debuglevel = MU::WARN
						interval = 20
					end
					MU.log "Got #{e.inspect} calling EC2's #{method_sym} in #{@region}, waiting #{interval.to_s}s and retrying", debuglevel
					sleep interval
					retry
				end
			end
		end

		@@iam_api = {}
		# Object for accessing Amazon's IAM service
		def self.iam(region = MU.curRegion)
			region ||= MU.myRegion
			@@iam_api[region] ||= MU::AWS::Endpoint.new(api: "IAM", region: region)
			@@iam_api[region]
		end

		@@ec2_api = {}
		# Object for accessing Amazon's EC2 service
		def self.ec2(region = MU.curRegion)
			region ||= MU.myRegion
			@@ec2_api[region] ||= MU::AWS::Endpoint.new(api: "EC2", region: region)
			@@ec2_api[region]
		end

		@@autoscale_api = {}
		# Object for accessing Amazon's Autoscaling service
		def self.autoscale(region = MU.curRegion)
			region ||= MU.myRegion
			@@autoscale_api[region] ||= MU::AWS::Endpoint.new(api: "AutoScaling", region: region)
			@@autoscale_api[region]
		end

		@@elb_api = {}
		# Object for accessing Amazon's ElasticLoadBalancing service
		def self.elb(region = MU.curRegion)
			region ||= MU.myRegion
			@@elb_api[region] ||= MU::AWS::Endpoint.new(api: "ElasticLoadBalancer", region: region)
			@@elb_api[region]
		end

		@@route53_api = {}
		# Object for accessing Amazon's Route53 service
		def self.route53(region = MU.curRegion)
			region ||= MU.myRegion
			@@route53_api[region] ||= MU::AWS::Endpoint.new(api: "Route53", region: region)
			@@route53_api[region]
		end

		@@rds_api = {}
		# Object for accessing Amazon's RDS service
		def self.rds(region = MU.curRegion)
			region ||= MU.myRegion
			@@rds_api[region] ||= MU::AWS::Endpoint.new(api: "RDS", region: region)
			@@rds_api[region]
		end

		@@cloudformation_api = {}
		# Object for accessing Amazon's CloudFormation service
		def self.cloudformation(region = MU.curRegion)
			region ||= MU.myRegion
			@@cloudformation_api[region] ||= MU::AWS::Endpoint.new(api: "CloudFormation", region: region)
			@@cloudformation_api[region]
		end

		@@s3_api = {}
		# Object for accessing Amazon's S3 service
		def self.s3(region = MU.curRegion)
			region ||= MU.myRegion
			@@s3_api[region] ||= MU::AWS::Endpoint.new(api: "S3", region: region)
			@@s3_api[region]
		end

		@@cloudtrails_api = {}
		# Object for accessing Amazon's CloudTrail service
		def self.cloudtrails(region = MU.curRegion)
			region ||= MU.myRegion
			@@cloudtrails_api[region] ||= MU::AWS::Endpoint.new(api: "CloudTrail", region: region)
			@@cloudtrails_api[region]
		end
		
		@@cloudwatch_api = {}
		# Object for accessing Amazon's CloudWatch service
		def self.cloudwatch(region = MU.curRegion)
			region ||= MU.myRegion
			@@cloudwatch_api[region] ||= MU::AWS::Endpoint.new(api: "CloudWatch", region: region)
			@@cloudwatch_api[region]
		end

		@@cloudfront_api = {}
		# Object for accessing Amazon's CloudFront service
		def self.cloudfront(region = MU.curRegion)
			region ||= MU.myRegion
			@@cloudfront_api[region] ||= MU::AWS::Endpoint.new(api: "CloudFront", region: region)
			@@cloudfront_api[region]
		end

	end
end
