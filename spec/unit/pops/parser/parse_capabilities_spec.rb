#! /usr/bin/env ruby
require 'spec_helper'
require 'puppet/pops'

# relative to this spec file (./) does not work as this file is loaded by rspec
require File.join(File.dirname(__FILE__), '/parser_rspec_helper')

describe "egrammar parsing of 'produces'" do
  include ParserRspecHelper

  it "parses produces" do
    prog = <<-EOS
define foo {}
foo produces sql { one: }
EOS
    ast = <<EOS.strip
(block
  (define foo ())
  (produces foo (resource sql
    (one)))
)
EOS
    expect(dump(parse(prog))).to eq(ast)
  end

end
