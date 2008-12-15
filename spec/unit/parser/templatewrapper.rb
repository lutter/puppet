#!/usr/bin/env ruby

require File.dirname(__FILE__) + '/../../spec_helper'

describe Puppet::Parser::TemplateWrapper do
    before(:each) do
        compiler = stub('compiler', :environment => "foo")
        parser = stub('parser', :watch_file => true)
        @scope = stub('scope', :compiler => compiler, :parser => parser, :to_hash => {})
        @file = "fake_template"
        Puppet::Module.stubs(:find_template).returns("/tmp/fake_template")
        FileTest.stubs(:exists?).returns("true")
        File.stubs(:read).with("/tmp/fake_template").returns("template content")
        @tw = Puppet::Parser::TemplateWrapper.new(@scope)
    end

    it "should create a new object TemplateWrapper from a scope" do
        tw = Puppet::Parser::TemplateWrapper.new(@scope)

        tw.should be_a_kind_of(Puppet::Parser::TemplateWrapper)
    end

    it "should check template file existance and read its content" do
        Puppet::Module.expects(:find_template).with("fake_template", "foo").returns("/tmp/fake_template")
        FileTest.expects(:exists?).with("/tmp/fake_template").returns(true)
        File.expects(:read).with("/tmp/fake_template").returns("template content")

        @tw.file = @file
    end

    it "should turn into a string like template[name] for file based template" do
        @tw.file = @file
        @tw.to_s.should eql("template[/tmp/fake_template]")
    end

    it "should turn into a string like template[inline] for string-based template" do
        @tw.to_s.should eql("template[inline]")
    end

    it "should return the processed template contents with a call to result" do
        template_mock = mock("template", :result => "woot!")
        File.expects(:read).with("/tmp/fake_template").returns("template contents")
        ERB.expects(:new).with("template contents", 0, "-").returns(template_mock)

        @tw.file = @file
        @tw.result.should eql("woot!")
    end

    it "should return the processed template contents with a call to result and a string" do
        template_mock = mock("template", :result => "woot!")
        ERB.expects(:new).with("template contents", 0, "-").returns(template_mock)

        @tw.result("template contents").should eql("woot!")
    end

    it "should return the contents of a variable if called via method_missing" do
        @scope.expects(:lookupvar).with("chicken", false).returns("is good")
        tw = Puppet::Parser::TemplateWrapper.new(@scope)
        tw.chicken.should eql("is good")
    end

    it "should throw an exception if a variable is called via method_missing and it does not exist" do
        @scope.expects(:lookupvar).with("chicken", false).returns(:undefined)
        tw = Puppet::Parser::TemplateWrapper.new(@scope)
        lambda { tw.chicken }.should raise_error(Puppet::ParseError)
    end

    it "should allow you to check whether a variable is defined with has_variable?" do
        @scope.expects(:lookupvar).with("chicken", false).returns("is good")
        tw = Puppet::Parser::TemplateWrapper.new(@scope)
        tw.has_variable?("chicken").should eql(true)
    end

    it "should allow you to check whether a variable is not defined with has_variable?" do
        @scope.expects(:lookupvar).with("chicken", false).returns(:undefined)
        tw = Puppet::Parser::TemplateWrapper.new(@scope)
        tw.has_variable?("chicken").should eql(false)
    end

    it "should allow you to retrieve the defined classes with classes" do
        catalog = mock 'catalog', :classes => ["class1", "class2"]
        @scope.expects(:catalog).returns( catalog )
        tw = Puppet::Parser::TemplateWrapper.new(@scope)
        tw.classes().should == ["class1", "class2"]
    end

    it "should allow you to retrieve all the tags with all_tags" do
        catalog = mock 'catalog', :tags => ["tag1", "tag2"]
        @scope.expects(:catalog).returns( catalog )
        tw = Puppet::Parser::TemplateWrapper.new(@scope)
        tw.all_tags().should == ["tag1","tag2"]
    end

    it "should allow you to retrieve the tags defined in the current scope" do
        @scope.expects(:tags).returns( ["tag1", "tag2"] )
        tw = Puppet::Parser::TemplateWrapper.new(@scope)
        tw.tags().should == ["tag1","tag2"]
    end

    it "should set all of the scope's variables as instance variables" do
        template_mock = mock("template", :result => "woot!")
        ERB.expects(:new).with("template contents", 0, "-").returns(template_mock)

        @scope.expects(:to_hash).returns("one" => "foo")
        @tw.result("template contents")

        @tw.instance_variable_get("@one").should == "foo"
     end

     it "should not error out if one of the variables is a symbol" do
        template_mock = mock("template", :result => "woot!")
        ERB.expects(:new).with("template contents", 0, "-").returns(template_mock)

        @scope.expects(:to_hash).returns(:_timestamp => "1234")
        @tw.result("template contents")
     end

     %w{! . ; :}.each do |badchar|
       it "should translate #{badchar} to _ when setting the instance variables" do
        template_mock = mock("template", :result => "woot!")
        ERB.expects(:new).with("template contents", 0, "-").returns(template_mock)

        @scope.expects(:to_hash).returns("one#{badchar}" => "foo")
        @tw.result("template contents")

        @tw.instance_variable_get("@one_").should == "foo"
      end
     end
end
