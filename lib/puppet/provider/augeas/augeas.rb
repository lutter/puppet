#--
#  Copyright (C) 2008 Red Hat Inc.
#
#  This library is free software; you can redistribute it and/or
#  modify it under the terms of the GNU General Public
#  License as published by the Free Software Foundation; either
#  version 2 of the License, or (at your option) any later version.
#
#  This library is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
#  General Public License for more details.
#
#  You should have received a copy of the GNU General Public
#  License along with this library; if not, write to the Free Software
#  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307  USA
#
# Author: Bryan Kearney <bkearney@redhat.com>

require 'augeas' if Puppet.features.augeas?
require 'strscan'

Puppet::Type.type(:augeas).provide(:augeas) do
    include Puppet::Util

    confine :true => Puppet.features.augeas?

    has_features :parse_commands, :need_to_run?,:execute_changes

    SAVE_NOOP = "noop"
    SAVE_OVERWRITE = "overwrite"

    COMMANDS = {
      "set" => [ :path, :string ],
      "rm" => [ :path ],
      "clear" => [ :path ],
      "insert" => [ :string, :string, :path ],
      "get" => [ :path, :comparator, :string ],
      "match" => [ :path, :glob ],
      "size" => [:comparator, :int],
      "include" => [:string],
      "eq" => [:glob],
      "noteq" => [:glob]
    }

    COMMANDS["ins"] = COMMANDS["insert"]
    COMMANDS["remove"] = COMMANDS["rm"]    

    attr_accessor :aug

    # Extracts an 2 dimensional array of commands which are in the
    # form of command path value.
    # The input can be
    # - A string with one command
    # - A string with many commands per line
    # - An array of strings.
    def parse_commands(data)
        context = resource[:context]
        # Add a trailing / if it is not there
        if (context.length > 0)
            context << "/" if context[-1, 1] != "/"
        end

        if data.is_a?(String)
            s = data
            data = []
            s.each_line { |line| data << line }
        end
        args = []
        data.each do |line|
            argline = []
            sc = StringScanner.new(line)
            cmd = sc.scan(/\w+/)
            formals = COMMANDS[cmd]
            fail("Unknown command #{cmd}") unless formals
            argline << cmd
            narg = 0
            formals.each do |f|
                sc.skip(/\s+/)
                narg += 1
                if f == :path
                    start = sc.pos
                    nbracket = 0
                    begin
                        sc.skip(/[^\]\[\s]+/)
                        ch = sc.getch
                        nbracket += 1 if ch == "["
                        nbracket -= 1 if ch == "]"
                        fail("unmatched [") if nbracket < 0
                    end until nbracket == 0 && (sc.eos? || ch =~ /\s/)
                        len = sc.pos - start
                        len -= 1 unless sc.eos?
                    unless p = sc.string[start, len]
                        fail("missing path argument #{narg} for #{cmd}")
                    end
                    if p[0,1] != "$" && p[0,1] != "/"
                        argline << context + p
                    else
                        argline << p
                    end
                elsif f == :string
                    delim = sc.peek(1)
                    if delim == "'" || delim == "\""
                        sc.getch
                        argline << sc.scan(/([^\\#{delim}]|(\\.))*/)
                        sc.getch
                    else
                        argline << sc.scan(/[^\s]+/)
                    end
                    unless argline[-1]
                        fail(raise Exception, "missing string argument #{narg} for #{cmd}")
                    end
                elsif f == :comparator
                    argline << sc.scan(/(==|!=|=~|<|<=|>|>=)/)
                    unless argline[-1]
                        puts sc.rest() 
                        fail(raise Exception, "invalid comparator for command #{cmd}")
                    end
                elsif f == :int
                    argline << sc.scan(/\d+/).to_i
                elsif f== :glob
                    argline << sc.rest()
                end
            end
            args << argline
        end
        return args
    end


    def open_augeas
        if (@aug.nil?)
            flags = 0
            (flags = 1 << 2 ) if self.resource[:type_check] == :true
            root = self.resource[:root]
            load_path = self.resource[:load_path]
            debug("Opening augeas with root #{root}, lens path #{load_path}, flags #{flags}")
            @aug = Augeas.open(root, load_path,flags)

            if (self.get_augeas_version() >= "0.3.6")
                debug("Augeas version #{self.get_augeas_version()} is installed")
            end
        end
        @aug
    end

    def close_augeas
        if (!@aug.nil?)
            @aug.close()
            debug("Closed the augeas connection")
            @aug = nil;
        end
    end

    # Used by the need_to_run? method to process get filters. Returns
    # true if there is a match, false if otherwise
    # Assumes a syntax of get /files/path [COMPARATOR] value
    def process_get(cmd_array)
        return_value = false

        #validate and tear apart the command
        fail ("Invalid command: #{cmd_array.join(" ")}") if cmd_array.length < 4
        cmd = cmd_array.shift()
        path = cmd_array.shift()
        comparator = cmd_array.shift()
        arg = cmd_array.join(" ")

        #check the value in augeas
        result = @aug.get(path) || ''
        unless result.nil?
            case comparator
                when "!=":
                    return_value = true if !(result == arg)
                when "=~":
                    regex = Regexp.new(arg)
                    loc = result=~ regex
                    return_value = true if ! loc.nil?
                else
                    return_value = true if (result.send(comparator, arg))
            end
        end
        return_value
    end

    # Used by the need_to_run? method to process match filters. Returns
    # true if there is a match, false if otherwise
    def process_match(cmd_array)
        return_value = false

        #validate and tear apart the command
        fail("Invalid command: #{cmd_array.join(" ")}") if cmd_array.length < 3
        cmd = cmd_array.shift()
        path = cmd_array.shift()

        # Need to break apart the clause
        clause_array = parse_commands(cmd_array.shift())[0]
        verb = clause_array.shift()

        #Get the values from augeas
        result = @aug.match(path) || ''
        # Now do the work
        unless (result.nil?)
            case verb
                when "size":
                    fail("Invalid command: #{cmd_array.join(" ")}") if clause_array.length != 2
                    comparator = clause_array.shift()
                    arg = clause_array.shift()
                    return_value = true if (result.size.send(comparator, arg))
                when "include":
                    arg = clause_array.shift()
                    return_value = true if result.include?(arg)
                when "eq":
                    begin
                        arg = clause_array.shift()
                        new_array = eval arg
                        return_value = true if result == new_array
                    rescue
                        fail("Invalid array in command: #{cmd_array.join(" ")}")
                    end
                when "noteq":
                    begin
                        arg = clause_array.shift()
                        new_array = eval arg
                        return_value = true if result != new_array
                    rescue
                        fail("Invalid array in command: #{cmd_array.join(" ")}")
                    end                    
            end
        end
        return_value
    end

    def get_augeas_version
        return @aug.get("/augeas/version") || ""
    end

    def set_augeas_save_mode(mode)
        return @aug.set("/augeas/save", mode)
    end

    def files_changed?
        saved_files = @aug.match("/augeas/events/saved")
        return saved_files.size() > 0
    end

    # Determines if augeas acutally needs to run.
    def need_to_run?
        force = resource[:force]
        return_value = true
        self.open_augeas()
        filter = resource[:onlyif]
        unless (filter == "")
            cmd_array = parse_commands(filter)[0]
            command = cmd_array[0];
            begin
                case command
                    when "get" then return_value = process_get(cmd_array)
                    when "match" then return_value = process_match(cmd_array)
                end
            rescue Exception => e
                fail("Error sending command '#{command}' with params #{cmd_array[1..-1].inspect}/#{e.message}")
            end
        end

        unless (force)
            # If we have a verison of augeas which is at least 0.3.6 then we
            # can make the changes now, see if changes were made, and
            # actually do the save.
            if ((return_value) and (self.get_augeas_version() >= "0.3.6"))
                debug("Will attempt to save and only run if files changed")
                self.set_augeas_save_mode(SAVE_NOOP)
                self.do_execute_changes()
                save_result = @aug.save()
                saved_files = @aug.match("/augeas/events/saved")
                if ((save_result) and (not files_changed?))
                    debug("Skipping becuase no files were changed")
                    return_value = false
                else
                    debug("Files changed, should execute")
                end
            end
        end
        self.close_augeas()
        return return_value
    end

    def execute_changes
        # Re-connect to augeas, and re-execute the changes
        self.open_augeas()
        if (self.get_augeas_version() >= "0.3.6")
            self.set_augeas_save_mode(SAVE_OVERWRITE)
        end

        self.do_execute_changes()

        success = @aug.save()
        if (success != true)
            fail("Save failed with return code #{success}")
        end
        self.close_augeas()

        return :executed
    end

    # Actually execute the augeas changes.
    def do_execute_changes
        commands = parse_commands(resource[:changes])
        commands.each do |cmd_array|
            fail("invalid command #{cmd_array.join[" "]}") if cmd_array.length < 2
            command = cmd_array[0]
            cmd_array.shift()
            begin
                case command
                    when "set":
                        debug("sending command '#{command}' with params #{cmd_array.inspect}")
                        @aug.set(cmd_array[0], cmd_array[1])
                    when "rm", "remove":
                        debug("sending command '#{command}' with params #{cmd_array.inspect}")
                        @aug.rm(cmd_array[0])
                    when "clear":
                        debug("sending command '#{command}' with params #{cmd_array.inspect}")
                        @aug.clear(cmd_array[0])
                    when "insert", "ins"
                        label = cmd_array[0]
                        where = cmd_array[1]
                        path = cmd_array[2]
                        case where
                            when "before": before = true
                            when "after": before = false
                            else fail("Invalid value '#{where}' for where param")
                        end
                        debug("sending command '#{command}' with params #{[label, where, path].inspect()}")
                        aug.insert(path, label, before)
                    else fail("Command '#{command}' is not supported")
                end
            rescue Exception => e
                fail("Error sending command '#{command}' with params #{cmd_array.inspect}/#{e.message}")
            end
        end
    end

end
