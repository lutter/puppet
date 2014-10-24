#! /usr/bin/env ruby
require 'spec_helper'
require 'puppet/pops'

# relative to this spec file (./) does not work as this file is loaded by rspec
require File.join(File.dirname(__FILE__), '/parser_rspec_helper')

describe "parsing capabilities" do
  include ParserRspecHelper

  it "parses produces" do
    prog = "define foo($a, $b) produces sql($x = u1, $y = u2) { }"
    s = "(define foo (parameters a b) (produces sql (parameters (= x u1) (= y u2))) ())"
    dump(parse(prog)).should == s
  end

  it "parses consumes" do
    prog = "define foo  { notice('Howdy') }"
    s = "(define foo () (block\n  (invoke notice 'Howdy')\n))"
    dump(parse("define foo  { notice('Howdy') }")).should == s
  end
end
