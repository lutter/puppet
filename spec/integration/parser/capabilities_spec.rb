require 'spec_helper'
require 'puppet/pops'
require 'puppet/parser/parser_factory'
require 'puppet_spec/compiler'
require 'puppet_spec/pops'
require 'puppet_spec/scope'
require 'matchers/resource'
require 'rgen/metamodel_builder'

require 'ostruct'
require 'net/http'

# These tests simply do the same as
# https://github.com/lak/puppet/blob/prototype/master/capabilities/bin/xhost.pp

describe "capabilities" do
  include PuppetSpec::Compiler
  include Matchers::Resource

  COMPONENTS = <<-EOS
  define db($port = 80, $user = root, $password, $host = "127.0.0.1", $database = $name) produces sql() {
    notify { "db($name,$password)": }
  }

  define web($dbport, $dbuser, $dbpassword, $dbhost, $database) consumes sql(
    $port      = dbport,
    $user      = dbuser,
    $password  = dbpassword,
    $host      = dbhost,
    $database  = database
  ) {
    notify { "web($name,$dbpassword,$dbuser)": }
  }
EOS

  before :each do
    Puppet[:parser] = 'future'
  end

  it 'compiles components' do
    catalog = compile_to_catalog(<<-CODE)
#{COMPONENTS}
CODE
  end

  describe "instantiation" do
    it "works with direct use" do
      catalog = compile_to_catalog(<<-CODE)
#{COMPONENTS}
  db { one: password => "passw0rd" }
  web { one: require => Db[one] }
CODE
      expect(catalog).to have_resource("Db[one]")
      expect(catalog).to have_resource("Web[one]")
      expect(catalog).to have_resource("Notify[db(one,passw0rd)]")
      expect(catalog).to have_resource("Notify[web(one,passw0rd,root)]")

      # @todo lutter 2014-11-06: currently, the code does not instantiate the
      # capres when it is pulled in via 'require'. That is a bit strange
      expect(catalog).to_not have_resource("Sql[one]")
    end

    it "works with indirect use" do
      catalog = compile_to_catalog(<<-CODE)
#{COMPONENTS}
  db { one: password => "passw0rd", produce => Sql[one] }
  web { one: consume => Sql[one] }
CODE
      expect(catalog).to have_resource("Sql[one]")
      expect(catalog).to have_resource("Db[one]")
      expect(catalog).to have_resource("Web[one]")
      expect(catalog).to have_resource("Notify[db(one,passw0rd)]")
      expect(catalog).to have_resource("Notify[web(one,passw0rd,root)]")
    end
  end

  it "works across nodes" do
    db1 = Puppet::Node.new("db1")
    web1 = Puppet::Node.new("web1")
    db_catalog = compile_to_catalog(<<-CODE, db1)
#{COMPONENTS}
  db { one: password => "passw0rd", produce => Sql[one] }
CODE

    # @todo lutter 2014-11-06: this way of stubbing out PuppetDB is pretty
    # gross, yet surprisingly effective
    data = [{"parameters" => {
                "host" => "127.0.0.1",
                "port" => "80",
                "user" => "root",
                "password" => "passw0rd",
                "database" => "one"
              },
              "title" => "one",
              "type" => "Sql"}]
    response = OpenStruct.new
    response.body = data.to_json
    Net::HTTP.any_instance.stubs(:get).returns(response)

    web_catalog = compile_to_catalog(<<-CODE, web1)
#{COMPONENTS}
  web { one: consume => Sql[one] }
CODE

  end
end
