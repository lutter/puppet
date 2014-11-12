#! /usr/bin/env ruby
require 'spec_helper'
require 'puppet/pops'

# relative to this spec file (./) does not work as this file is loaded by rspec
require File.join(File.dirname(__FILE__), '/parser_rspec_helper')

describe "egrammar parsing of 'application'" do
  include ParserRspecHelper

  it "an empty body" do
    dump(parse("application foo { }")).should == "(application foo () ())"
  end

  it "an empty body" do
    prog = <<-EPROG
application foo {
  db { one:
    password => 'secret'
  }
}
EPROG
    dump(parse(prog)).should == [
"(application foo () (block",
"  (resource db",
"    (one",
"      (password => 'secret')))", "))" ].join("\n")
  end

  it "accepts parameters" do
    s = "application foo($p1 = 'yo', $p2) { }"
    dump(parse(s)).should == "(application foo ((= p1 'yo') p2) ())"
  end
end
