require 'puppettest'

module PuppetTest::Support
end
module PuppetTest::Support::Utils
    def gcdebug(type)
        Puppet.warning "%s: %s" % [type, ObjectSpace.each_object(type) { |o| }]
    end

    #
    # TODO: I think this method needs to be renamed to something a little more
    # explanatory.
    #

    def newobj(type, name, hash)
        transport = Puppet::TransObject.new(name, "file")
        transport[:path] = path
        transport[:ensure] = "file"
        assert_nothing_raised {
            file = transport.to_type
        }
    end

    # Turn a list of resources, or possibly a catalog and some resources,
    # into a catalog object.
    def resources2catalog(*resources)
        if resources[0].is_a?(Puppet::Node::Catalog)
            config = resources.shift
            unless resources.empty?
                resources.each { |r| config.add_resource r }
            end
        elsif resources[0].is_a?(Puppet.type(:component))
            raise ArgumentError, "resource2config() no longer accpts components"
            comp = resources.shift
            comp.delve
        else
            config = Puppet::Node::Catalog.new
            resources.each { |res| config.add_resource res }
        end
        return config
    end

    # stop any services that might be hanging around
    def stopservices
        if stype = Puppet::Type.type(:service)
            stype.each { |service|
                service[:ensure] = :stopped
                service.evaluate
            }
        end
    end

    # TODO: rewrite this to use the 'etc' module.

    # Define a variable that contains the name of my user.
    def setme
        # retrieve the user name
        id = %x{id}.chomp
        if id =~ /uid=\d+\(([^\)]+)\)/
            @me = $1
        else
            puts id
        end
        unless defined? @me
            raise "Could not retrieve user name; 'id' did not work"
        end
    end

    # Define a variable that contains a group I'm in.
    def set_mygroup
        # retrieve the user name
        group = %x{groups}.chomp.split(/ /)[0]
	unless group
	    raise "Could not find group to set in @mygroup"
	end
	@mygroup = group
    end

    def run_events(type, trans, events, msg)
        case type
        when :evaluate, :rollback: # things are hunky-dory
        else
            raise Puppet::DevError, "Incorrect run_events type"
        end

        method = type

        newevents = nil
        assert_nothing_raised("Transaction %s %s failed" % [type, msg]) {
            newevents = trans.send(method).reject { |e| e.nil? }.collect { |e|
                e.name
            }
        }

        assert_equal(events, newevents, "Incorrect %s %s events" % [type, msg])

        return trans
    end

    # If there are any fake data files, retrieve them
    def fakedata(dir)
        ary = [basedir, "test"]
        ary += dir.split("/")
        dir = File.join(ary)

        unless FileTest.exists?(dir)
            raise Puppet::DevError, "No fakedata dir %s" % dir
        end
        files = Dir.entries(dir).reject { |f| f =~ /^\./ }.collect { |f|
            File.join(dir, f)
        }

        return files
    end

    def fakefile(name)
        ary = [PuppetTest.basedir, "test"]
        ary += name.split("/")
        file = File.join(ary)
        unless FileTest.exists?(file)
            raise Puppet::DevError, "No fakedata file %s" % file
        end
        return file
    end

    # wrap how to retrieve the masked mode
    def filemode(file)
        File.stat(file).mode & 007777
    end

    def memory
        Puppet::Util.memory
    end

    # a list of files that we can parse for testing
    def textfiles
        textdir = datadir "snippets"
        Dir.entries(textdir).reject { |f|
            f =~ /^\./ or f =~ /fail/
        }.each { |f|
            yield File.join(textdir, f)
        }
    end

    def failers
        textdir = datadir "failers"
        # only parse this one file now
        files = Dir.entries(textdir).reject { |file|
            file =~ %r{\.swp}
        }.reject { |file|
            file =~ %r{\.disabled}
        }.collect { |file|
            File.join(textdir,file)
        }.find_all { |file|
            FileTest.file?(file)
        }.sort.each { |file|
            Puppet.debug "Processing %s" % file
            yield file
        }
    end

    def mk_catalog(*resources)
        if resources[0].is_a?(String)
            name = resources.shift
        else
            name = :testing
        end
        config = Puppet::Node::Catalog.new :testing do |conf|
            resources.each { |resource| conf.add_resource resource }
        end

        return config
    end
end

module PuppetTest
    include PuppetTest::Support::Utils
end
