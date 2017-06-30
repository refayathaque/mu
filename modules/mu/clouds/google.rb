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

require "google/cloud"
require 'googleauth'
require "net/http"
require 'net/https'
require 'multi_json'
require 'stringio'

module MU
  class Cloud
    # Support for Google Cloud Platform as a provisioning layer.
    class Google
      @@authtoken = nil
      @@default_project = nil
      @@authorizers = {}

      # Pull our global Google Cloud Platform credentials out of their secure
      # vault, feed them to the googleauth gem, and stash the results on hand
      # for consumption by the various GCP APIs.
      # @param scopes [Array<String>]: One or more scopes for which to authorizer the caller. Will vary depending on the API you're calling.
      def self.loadCredentials(scopes = nil)
        return @@authorizers[scopes.to_s] if @@authorizers[scopes.to_s]
# XXX Maybe rig this up as a fallback (would work when we're deployed in 
# Computer or cohabiting with other things that use the generic ENV setup.
# ::Google::Auth.get_application_default(scopes)
        if $MU_CFG.has_key?("google") and $MU_CFG["google"].has_key?("credentials")
          begin
            vault, item = $MU_CFG["google"]["credentials"].split(/:/)
            data = MU::Groomer::Chef.getSecret(vault: vault, item: item).to_h
            @@default_project ||= data["project_id"]
            creds = {
              :json_key_io => StringIO.new(MultiJson.dump(data)),
              :scope => scopes
            }
            @@authorizers[scopes.to_s] = ::Google::Auth::ServiceAccountCredentials.make_creds(creds)
            return @@authorizers[scopes.to_s]
          rescue MU::Groomer::Chef::MuNoSuchSecret
            raise MuError, "Google Cloud credentials not found in Vault #{vault}:#{item}"
          end
        else
          raise MuError, "Google Cloud credentials not configured"
        end
        nil
      end

      # Fetch a URL
      def self.get(url)
        uri = URI url
        resp = nil

        Net::HTTP.start(uri.host, uri.port) do |http|
          resp = http.get(uri)
        end

        unless resp.code == "200"
          puts resp.code, resp.body
          exit
        end
        resp.body
      end

      # Our credentials map to a project, an organizational structure in Google
      # Cloud. This fetches the identifier of the project associated with our
      # default credentials.
      def self.defaultProject
        loadCredentials if !@@default_project
        @@default_project
      end

      @@regions = {}
      # List all known Google Cloud Platform regions
      # @param us_only [Boolean]: Restrict results to United States only
      def self.listRegions(us_only = false)
        if @@regions.size == 0
          result = MU::Cloud::Google.compute.list_regions(MU::Cloud::Google.defaultProject)
          regions = []
          result.items.each { |region|
            @@regions[region.name] = []
            region.zones.each { |az|
              @@regions[region.name] << az.sub(/^.*?\/([^\/]+)$/, '\1')
            }
          }
        end
        if us_only
          @@regions.keys.delete_if { |r| !r.match(/^us/) }
        else
          @@regions.keys
        end
      end
  
      # List the Availability Zones associated with a given Google Cloud
      # region. If no region is given, search the one in which this MU master
      # server resides (if it resides in this cloud provider's ecosystem).
      # @param region [String]: The region to search.
      # @return [Array<String>]: The Availability Zones in this region.
      def self.listAZs(region = MU.curRegion)
        MU::Cloud::Google.listRegions if !@@regions.has_key?(region)
        raise MuError, "No such Google Cloud region '#{region}'" if !@@regions.has_key?(region)
        @@regions[region]
      end

      # Google's Compute Service API
      # @param subclass [<Google::Apis::ComputeBeta>]: If specified, will return the class ::Google::Apis::ComputeBeta::subclass instead of an API client instance
      def self.compute(subclass = nil)
        require 'google/apis/compute_beta'

        if subclass.nil?
          @@compute_api ||= MU::Cloud::Google::Endpoint.new(api: "ComputeBeta::ComputeService", scopes: ['https://www.googleapis.com/auth/cloud-platform', 'https://www.googleapis.com/auth/compute.readonly'])
          return @@compute_api
        elsif subclass.is_a?(Symbol)
          return Object.const_get("::Google").const_get("Apis").const_get("ComputeBeta").const_get(subclass)
        end
      end

      private

      # Wrapper class for Google APIs, so that we can catch some common
      # transient endpoint errors without having to spray rescues all over the
      # codebase.
      class Endpoint
        @api = nil
#        @region = nil

        # Create a Google Cloud Platform API client
        # @param api [String]: Which API are we wrapping?
        # @param scopes [Array<String>]: Google auth scopes applicable to this API
        def initialize(api: "ComputeBeta::ComputeService", scopes: ['https://www.googleapis.com/auth/cloud-platform', 'https://www.googleapis.com/auth/compute.readonly'])
#          @region = region
          @api = Object.const_get("Google::Apis::#{api}").new
          @api.authorization = MU::Cloud::Google.loadCredentials(scopes)
        end

        @instance_cache = {}
        # Catch-all for AWS client methods. Essentially a pass-through with some
        # rescues for known silly endpoint behavior.
        def method_missing(method_sym, *arguments)
          retries = 0
          begin
            MU.log "Calling #{method_sym}", MU::DEBUG, details: arguments
            retval = nil
            if !arguments.nil? and arguments.size == 1
              retval = @api.method(method_sym).call(arguments[0])
            elsif !arguments.nil? and arguments.size > 0
              retval = @api.method(method_sym).call(*arguments)
            else
              retval = @api.method(method_sym).call
            end
            if retval.class == ::Google::Apis::ComputeBeta::Operation
              retries = 0
              begin
                if retries > 0 and retries % 3 == 0
                  MU.log "Waiting for #{method_sym} to be done (retry #{retries})", MU::NOTICE
                else
                  MU.log "Waiting for #{method_sym} to be done (retry #{retries})", MU::DEBUG, details: retval
                end
                if retval.status != "DONE"
                  sleep 7
                  begin
                    resp = MU::Cloud::Google.compute.get_global_operation(
                      arguments.first, # there's always a project id
                      retval.name
                    )
                    retval = resp
                  rescue ::Google::Apis::ClientError => e
                    # this is ok; just means the operation is done and went away
                    if e.message.match(/^notFound:/)
                      return retval
                    else
                      raise e
                    end
                  end
                  retries = retries + 1
                end
              end while retval.status != "DONE"
            end
            return retval
          rescue ::Google::Apis::ServerError => e
            retries = retries + 1
#            debuglevel = MU::DEBUG
debuglevel = MU::NOTICE
            interval = 5 + Random.rand(4) - 2
            if retries < 10 and retries > 2
              debuglevel = MU::NOTICE
              interval = 20 + Random.rand(10) - 3
            # elsif retries >= 10 and retries <= 100
            elsif retries >= 10
              debuglevel = MU::WARN
              interval = 40 + Random.rand(15) - 5
            # elsif retries > 100
              # raise MuError, "Exhausted retries after #{retries} attempts while calling EC2's #{method_sym} in #{@region}.  Args were: #{arguments}"
            end
            MU.log "Got #{e.inspect} calling Google's #{method_sym}, waiting #{interval.to_s}s and retrying. Args were: #{arguments}", debuglevel, details: caller
            sleep interval
            retry
          end
        end
      end
      @@compute_api = nil
    end
  end
end