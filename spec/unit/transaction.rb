#!/usr/bin/env ruby

require File.dirname(__FILE__) + '/../spec_helper'

require 'puppet/transaction'

describe Puppet::Transaction do
    it "should match resources by name, not title, when prefetching" do
        @catalog = Puppet::Node::Catalog.new
        @transaction = Puppet::Transaction.new(@catalog)

        # Have both a title and name
        resource = Puppet::Type.type(:sshkey).create :title => "foo", :name => "bar", :type => :dsa, :key => "eh"
        @catalog.add_resource resource

        resource.provider.class.expects(:prefetch).with("bar" => resource)

        @transaction.prefetch
    end
end

describe Puppet::Transaction, " when determining tags" do
    before do
        @config = Puppet::Node::Catalog.new
        @transaction = Puppet::Transaction.new(@config)
    end

    it "should default to the tags specified in the :tags setting" do
        Puppet.expects(:[]).with(:tags).returns("one")
        @transaction.tags.should == %w{one}
    end

    it "should split tags based on ','" do
        Puppet.expects(:[]).with(:tags).returns("one,two")
        @transaction.tags.should == %w{one two}
    end

    it "should use any tags set after creation" do
        Puppet.expects(:[]).with(:tags).never
        @transaction.tags = %w{one two}
        @transaction.tags.should == %w{one two}
    end

    it "should always convert assigned tags to an array" do
        @transaction.tags = "one::two"
        @transaction.tags.should == %w{one::two}
    end
end
