#!/usr/bin/env ruby
#
#  Created by Luke Kanies on 2007-10-24.
#  Copyright (c) 2007. All rights reserved.

require File.dirname(__FILE__) + '/../../spec_helper'

require 'puppet/indirector/direct_file_server'

describe Puppet::Indirector::DirectFileServer do
    before :each do
        Puppet::Indirector::Terminus.stubs(:register_terminus_class)
        @model = mock 'model'
        @indirection = stub 'indirection', :name => :mystuff, :register_terminus_type => nil, :model => @model
        Puppet::Indirector::Indirection.stubs(:instance).returns(@indirection)

        @direct_file_class = Class.new(Puppet::Indirector::DirectFileServer) do
            def self.to_s
                "Testing::Mytype"
            end
        end

        @server = @direct_file_class.new

        @uri = "file:///my/local"
    end

    describe Puppet::Indirector::DirectFileServer, "when finding a single file" do

        it "should return nil if the file does not exist" do
            FileTest.expects(:exists?).with("/my/local").returns false
            @server.find(@uri).should be_nil
        end

        it "should return a Content instance created with the full path to the file if the file exists" do
            FileTest.expects(:exists?).with("/my/local").returns true
            @model.expects(:new).returns(:mycontent)
            @server.find(@uri).should == :mycontent
        end
    end

    describe Puppet::Indirector::DirectFileServer, "when creating the instance for a single found file" do

        before do
            @data = mock 'content'
            @data.stubs(:collect_attributes)
            FileTest.expects(:exists?).with("/my/local").returns true
        end

        it "should create the Content instance with the original key as the key" do
            @model.expects(:new).with { |key, options| key == @uri }.returns(@data)
            @server.find(@uri)
        end

        it "should pass the full path to the instance" do
            @model.expects(:new).with { |key, options| options[:path] == "/my/local" }.returns(@data)
            @server.find(@uri)
        end

        it "should pass the :links setting on to the created Content instance if the file exists and there is a value for :links" do
            @model.expects(:new).returns(@data)
            @data.expects(:links=).with(:manage)
            @server.find(@uri, :links => :manage)
        end
    end

    describe Puppet::Indirector::DirectFileServer, "when searching for multiple files" do

        it "should return nil if the file does not exist" do
            FileTest.expects(:exists?).with("/my/local").returns false
            @server.find(@uri).should be_nil
        end

        it "should pass the original key to :path2instances" do
            FileTest.expects(:exists?).with("/my/local").returns true
            @server.expects(:path2instances).with { |uri, path, options| uri == @uri }
            @server.search(@uri)
        end

        it "should use :path2instances from the terminus_helper to return instances if the file exists" do
            FileTest.expects(:exists?).with("/my/local").returns true
            @server.expects(:path2instances)
            @server.search(@uri)
        end

        it "should pass any options on to :path2instances" do
            FileTest.expects(:exists?).with("/my/local").returns true
            @server.expects(:path2instances).with { |uri, path, options| options == {:testing => :one, :other => :two}}
            @server.search(@uri, :testing => :one, :other => :two)
        end
    end
end
