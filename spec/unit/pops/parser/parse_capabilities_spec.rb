#! /usr/bin/env ruby
require 'spec_helper'
require 'puppet/pops'

# relative to this spec file (./) does not work as this file is loaded by rspec
require File.join(File.dirname(__FILE__), '/parser_rspec_helper')

describe "egrammar parsing of 'produces' and 'consumes'" do
  include ParserRspecHelper

  it "parses produces" do
    prog = "define foo($a) produces sql { one: } { }"
    ast = "(define foo (parameters a) (produces (resource sql
  (one))) ())"
    dump(parse(prog)).should == ast
  end

  it "parses consumes" do
    prog = "define foo($a) consumes Sql $sql { }"
    ast = "(define foo (parameters a) (consumes (t sql sql)) ())"
    dump(parse(prog)).should == ast
  end

  it "parses produces and consumes" do
    prog = "define foo($a) produces http { one: } consumes Sql $sql { }"
    ast = "(define foo (parameters a) (produces (resource http
  (one))) (consumes (t sql sql)) ())"
    dump(parse(prog)).should == ast

    # produces and consumes can come in any order
    prog = "define foo($a) consumes Sql $sql produces http { one: } { }"
    dump(parse(prog)).should == ast
  end

  it "parses multiple produces" do
    prog = "define foo($a) produces http { one: } produces sql { two: } { }"
    ast = "(define foo (parameters a) (produces (resource http
  (one)) (resource sql
  (two))) ())"
    dump(parse(prog)).should == ast
  end

  it "parses multiple consumes" do
    prog = "define foo($a) consumes Sql $sql consumes Array[Http] $members { }"
    ast = "(define foo (parameters a) (consumes (t sql sql) (t (slice array http) members)) ())"
    dump(parse(prog)).should == ast
  end

end
