#
# A helper module to look a capability up from PuppetDB
#
# @todo lutter 2015-03-10: determine whether this should be based on
# Puppet::Pops::Evaluator::Collectors, or at least use
# Puppet::Util::Puppetdb::Http

require 'net/http'
require 'cgi'

module Puppet::Resource::CapabilityFinder

  # Look the capability resource with the given +type+ and +title+ up from
  # PuppetDB.
  def self.find(environment, cap)
    http = Net::HTTP.new("localhost", 8080)
    # @todo lutter 2015-03-10: do we also lookup by type and
    # cap.uniqueness_key ?
    query = ["and", ["=", "type", cap.type.capitalize],
                    ["=", "title", cap.title.to_s],
                    ["=", "tag", "producer:#{environment}"]].to_json

    Puppet.notice "Capability lookup #{cap}]: #{query}"
    # @todo lutter 2015-03-10: it is possible that +cap+ isn't in PuppetDB
    # yet because PuppetDB is backed up in committing catalogs. We can
    # resolve this either by querying PuppetDB as long as its queue is not
    # empty, or by sticking produced resources into the environment catalog
    # and having the deployer make sure that catalog was committed before
    # running any nodes
    response = http.get("/v3/resources?query=#{CGI.escape(query)}",
                        { "Accept" => 'application/json'})

    json = response.body

    # @todo lutter 2014-11-04: use just JSON
    data = PSON.parse(json)
    data.is_a?(Array) or raise Puppet::DevError,
    "Unexpected response from PuppetDB when looking up #{cap}: " +
      "expected an Array but got #{data.inspect}"

    # @todo lutter 2014-11-13: this was in the original capabilities
    # prototype; can we really get entries back that do not have
    # parameters set ?
    data = data.select { |hash| hash["parameters"] }

    Puppet.notice "Capability lookup #{cap}: response #{data}"
    data.size <= 1 or fail Puppet::ParseError,
    "Multiple resources found in PuppetDB when looking " +
      "up #{cap}: #{data.inspect}"

    unless data.empty?
      hash = data.first
      resource = Puppet::Resource.new(hash["type"], hash["title"])
      real_type = Puppet::Type.type(resource.type) or
        fail Puppet::ParseError,
          "Could not find resource type #{resource.type} returned from PuppetDB"
      real_type.parameters.each do |param|
        param = param.to_s
        next if param == "name"
        if value = hash["parameters"][param]
          resource[param] = value
        else
          Puppet.debug "No capability value for #{resource}->#{param}"
        end
      end
      return resource
    end
  end
end
