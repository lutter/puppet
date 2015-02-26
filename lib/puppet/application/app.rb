require 'puppet/application'
require 'puppet/configurer'
require 'puppet/util/profiler/aggregate'

require 'puppet/pops'

class Component
  attr_reader :type, :title, :produces, :consumes

  def initialize(type, title)
    @type = type
    @title = title
    @produces = [] # Array of Puppet::Resource
    @consumes = [] # Array of Puppet::Resource
  end

  def produce(other)
    # Remember Array(Puppet::Resource) returns [] :(
    if other.is_a?(Array)
      @produces.concat(other)
    else
      @produces << other
    end
  end

  def consume(other)
    # Remember Array(Puppet::Resource) returns [] :(
    if other.is_a?(Array)
      @consumes.concat(other)
    else
      @consumes << other
    end
  end

  def produces?(cap)
    @produces.include?(cap)
  end

  def to_s
    "#{type}[#{title}]"
  end

  alias_method :ref, :to_s

  def inspect
    "define #{type}[#{title}] " +
      [format_array("produces", produces) +
       format_array("consumes", consumes)].join(" ")
  end

  private
  def format_array(name, ary)
    if ary.empty?
      ""
    else
      name + " " + ary.map(&:to_s).join(",")
    end
  end
end

# Describe the mapping of components to nodes for an application
# instance. This is the internal representation of the +nodes+ parameter of
# an app instance
#
# @todo lutter 2014-11-19: it also serves as a list of all the components
# in an application, which goes beyond its purpose of being a mapping
class ComponentMapping

  attr_reader :components, :components_by_node

  def initialize(nodes)
    # Map node name => array of components
    @components_by_node = Hash.new { |hash, key| hash[key] = [] }
    # Map component names => node
    @node_for_component = { }
    @components = []

    nodes.each do |key, value|
      # @todo lutter 2014-11-18: Array(value) does not work for
      # Puppet::Resource
      if value.is_a?(Array)
        value.each { |v| assoc(key, v) }
      else
        assoc(key, value)
      end
    end
  end

  def nodes
    @components_by_node.keys
  end

  def producing_node(cap)
    comp = components.find { |comp| comp.produces?(cap) }
    @node_for_component[comp]
  end

  # @todo lutter 2014-11-18: all calls to this message need to be cleaned
  # up and hook into the proper Puppet error reporting mechanisms
  def die(msg)
    raise msg
  end

  def to_s
    "\n    " + @components_by_node.map do |node, comps|
      "Node[#{node}] : [#{comps.map(&:to_s).join(",")}]"
    end.join("\n    ")
  end

  private
  def assoc(node, comp)
    node, comp = comp, node unless node.type == 'Node'
    node.type == 'Node' or die "Invalid mapping #{node.ref} => #{comp.ref}; one of them must be a Node"
    comp.type != 'Node' or die "Invalid mapping #{node.ref} => #{comp.ref}; only one of them can be a Node"

    comp = Component.new(comp.type, comp.title)

    @components_by_node[node.title] << comp
    prev = @node_for_component[comp]
    prev.nil? or die "Component #{comp.ref} mapped to two nodes: #{Node[prev]} and #{node.ref}"
    @node_for_component[comp] = node.title
    @components << comp
  end
end

# Representation of an application instance that we will later use to
# compute component/node dependencies
class Application
  attr_reader :type, :title, :params, :mapping

  def initialize(type, title, args)
    @type = type
    @title = title
    @mapping = ComponentMapping.new(args.delete('nodes').value)
    @params = args
  end

  def component(res)
    mapping.components.find { |comp| comp.ref == res.ref }
  end

  def inspect
    "#{type}[#{title}]\n" +
      "components:\n  #{mapping.components.map { |c| c.inspect }.join("\n  ")}\n" +
      "mapping: #{mapping.inspect}"
  end

  def to_s
    "#{type}[#{title}]"
  end

  alias_method :ref, :to_s
end

class NodeGraph
  attr_reader :nodes

  def initialize
    # Adjacency list: node +n+ requires all the nodes in +@nodes[n]+
    @nodes = { }
  end

  # Add an Application. Adds dependency edges between any two nodes
  # that have components that depend on each other
  def add_app(app)
    m = app.mapping
    m.nodes.each do |node|
      @nodes[node] = []
      m.components_by_node[node].each do |comp|
        comp.consumes.each do |cons|
          prod = m.producing_node(cons) or
            raise "Component #{comp} on node #{node} consumes #{cons} but nobody produces it; maybe it is not a capability ?"
          dest = m.producing_node(cons)
          @nodes[node] << m.producing_node(cons) if dest != node
        end
      end
    end
  end

  # Return a list of nodes in topological order
  def order
    # Clone @nodes because we will make changes destructively
    queue = []
    graph = {}
    @nodes.each do |node, deps|
      # We can safely ignore self-cycles, they are meaningless
      graph[node] = deps.dup
      graph[node].delete(node)
      if graph[node].empty?
        graph.delete(node)
        queue << node
      end
    end

    result = []
    until queue.empty? do
      node = queue.pop
      result << node
      # @todo lutter 2014-09-10: the adjacency list data structure in
      # +@nodes+ is terrible for doing toposort .. but hey, small graphs here
      graph.keys.each do |n|
        graph[n].delete(node)
        if graph[n].empty?
          graph.delete(n)
          queue << n
        end
      end
    end
    graph.empty? or
      raise "The graph has cycles; can't complete toposort: #{graph.inspect}"

    result
  end
end

# Go through a program and extract the following model obejcts:
#   +definitions+ - application definitions
#   +components+   - component definitions (defines with a produces/consumes)
#   +resources+    - resource expressions at the toplevel
class AppCompiler
  attr_reader :applications, :definitions, :resources

  def initialize(env)
    @@find_visitor ||= Puppet::Pops::Visitor.new(self, "find", 0, 0)
    @@eval_visitor ||= Puppet::Pops::Visitor.new(self, "eval", 1, 1)
    @@expand_visitor ||= Puppet::Pops::Visitor.new(self, "expand", 2, 2)

    @definitions = {}        # name -> Puppet::Pops::Model::Application
    @applications = []       # Application
    @resources = []          # Application instantiations
                             # (ResourceExpression), in the order in which
                             # they were parsed
    @locator = nil           # Will be filled in find_Program

    @environment = env

    # All this setup is only here to use EvaluatingParser and Scope
    @parser  = Puppet::Pops::Parser::EvaluatingParser.new
    @scope = init_scope
  end

  # @todo lutter 2014-11-18: all calls to this message need to be cleaned
  # up and hook into the proper Puppet error reporting mechanisms
  def die(msg)
    raise msg
  end

  # Debug  helper to look at model snippets
  def dump(o)
    puts Puppet::Pops::Model::ModelTreeDumper.new.dump(o)
  end

  def line(o)
    @locator.line_for_offset(o.offset)
  end

  # Find application definitions and instantiations
  def find(model)
    @@find_visitor.visit_this_0(self, model)
    # Weed out resources that are not application instantiations
    # @todo lutter 2014-11-18: this makes it legal to reference an
    # application before it is defined. Is that desirable ?
    @resources.each do |appinst|
      appname = model_eval(appinst.type_name)
      @resources.delete(appname) unless @definitions[appname]
    end
  end

  # Evaluate all application instantiations so that we can deduce a node
  # graph
  def eval
    @resources.each do |res|
      @@eval_visitor.visit_this_1(self, res, @scope)
    end
  end

  def eval_ResourceExpression(o, scope)
    # @todo lutter 2014-11-18: this only deals with one individual resource
    # statement; it needs to handle more general syntax like what
    # EvaluatorImpl#eval_ResourceExpression does
    appname = model_eval(o.type_name)
    app_model = @definitions[appname] or die "#{line(o)}: no definition for application #{appname}"

    o.bodies.size == 1 or die "#{line(o.bodies)}: Can only handle one single resource statement #{o.bodies.size}"
    body = o.bodies.first

    titles = Array(model_eval(body.title, scope)).flatten
    titles.size == 1 or die "#{line(body)}: Can only handle one title for an application instantiation #{titles.size}"
    title = titles.first

    with_guarded_scope(scope) do
      create_local_scope_from({"name" => title}, scope)

      args = body.operations.inject({}) do |args, op|
        # This gives us a Puppet::Parser::Resource::Param
        arg = model_eval(op, scope)
        name = arg.name.to_s
        args[name].nil? or die "#{line(op)}: arg #{arg.name} is already defined"
        args[name] = arg
        args
      end
      args['nodes'] or die "#{line(body)}: the application instantiation of #{appname}[#{title}] does not contain a node mapping"

      begin
        # @todo lutter 2014-11-19: this is incredibly ugly: we need to pass
        # the app in an instance variable so that
        # evaluate_block_with_bindings has access to it even though the
        # machinery copied from the EvaluatorImpl doesn't have a way to pass
        # it through.
        @app = Application.new(appname, title, args)
        expand(app_model, @app, scope)
      ensure
        @app = nil
      end
    end
  end

  # Expand (evaluate) the body of an application definition. +o+ must be a
  # +Puppet::Pops::Model::Application+. The +Application+ passed in +app+
  # must have the params set up.
  def expand(o, app, scope)
    # @todo lutter 2014-11-19: start with a clean catalog to simulate
    # scoping of resources within the application instance
    scope.catalog.clear(false)

    o.parameters.each do |param|
      if app.params[param.name]
        scope[param.name] = app.params[param.name].value
      else
        scope[param.name] = model_eval(param.value, scope)
        app.params[param.name] = scope[param.name]
      end
      scope[param.name] or raise "#{line(o)}:#{app}: parameter #{param.name} has no value"
    end

    @@expand_visitor.visit_this_2(self, o.body, app, scope)

    @applications << app
  end

  def expand_BlockExpression(o, app, scope)
    o.statements.each do |st|
      @@expand_visitor.visit_this_2(self, st, app, scope)
    end
  end

  def expand_CallMethodExpression(o, app, scope)
    # @todo lutter 2014-11-19: copied from
    # Puppet::Pops::Evaluator::EvaluatorImpl#eval_CallMethodExpression
    unless o.functor_expr.is_a? Puppet::Pops::Model::NamedAccessExpression
      fail(Issues::ILLEGAL_EXPRESSION, o.functor_expr, {:feature=>'function accessor', :container => o})
    end
    receiver = model_eval(o.functor_expr.left_expr, scope)
    name = o.functor_expr.right_expr
    unless name.is_a? Puppet::Pops::Model::QualifiedName
      fail(Issues::ILLEGAL_EXPRESSION, o.functor_expr, {:feature=>'function name', :container => o})
    end
    name = name.value # the string function name

    evaluated_arguments = unfold([receiver], o.arguments || [], scope)

    # wrap lambda in a callable block if it is present
    evaluated_arguments << Puppet::Pops::Evaluator::Closure.new(self, o.lambda, scope) if o.lambda
    call_function(name, evaluated_arguments, o, scope)
  end

  # Create a resource inside the application instance
  def expand_ResourceExpression(o, app, scope)
    type = model_eval(o.type_name, scope)

    o.bodies.size == 1 or die "#{line(o.bodies)}: Can only handle one single resource statement #{o.bodies.size}"
    body = o.bodies.first

    # @todo lutter 2014-11-18: gracefully handle errors in evaluating body.title
    titles = Array(model_eval(body.title, scope)).flatten
    titles.size == 1 or die "#{line(o)}: Can only handle one title for an application instantiation, but got #{titles.size}"
    title = titles.first

    with_guarded_scope(scope) do
      # @todo lutter 2014-11-19: this makes it so that 'name' when we
      # evaluate a 'produces' resource refers to the name of the component;
      # somewhat ugly
      # @todo lutter 2014-11-19: at this point, we need to figure out where
      # this component gets mapped, and pull in the facts for that node
      # from PuppetDB
      create_local_scope_from({"name" => title}, scope)

      # @todo lutter 2014-11-18: handle evaluation errors gracefully
      args = body.operations.map { |op| model_eval(op, scope) }

      res = Puppet::Parser::Resource.new(type, title,
                                         :parameters => args,
                                         :scope => scope)
      # Fill in defaults for params not set explicitly
      res.set_default_parameters(scope)

      # Set up the 'inside' scope for evaluation of produces clauses
      # @todo lutter 2014-11-19: there must be a cleaner way to do this
      res.eachparam { |param| scope[param.name.to_s] = param.value }

      # @todo lutter 2014-11-19: this is a part of
      # Puppet::Resource::Type#set_resource_parameters. The main difference
      # is that at this point we do _not_ want to look up consumed capres
      # from PuppetDB. All we want to evaluate from +res+ are its paramters
      # and the produces clauses - even for that, we really only need the
      # name.
      res.resource_type.produces.each do |prod|
        comp = app.component(res) or die "In #{app}: component #{res} is not mapped to a node"
        comp.produce(prod.safeevaluate(scope))
      end
      res.resource_type.consumes.each do |cons|
        res[cons] or die "In #{app}: parameter #{cons} not defined for component #{res}"
        # @todo lutter 2014-11-19: check that +res[cons]+ is actually a
        # capability type; for some reason +res[cons].resource_type+ is nil
        # in some cases which makes checking somewhat hard
        app.component(res).consume(res[cons])
      end
    end
  end

  # @todo lutter 2014-09-08: we need to expand this to ignore all the other
  # stuff people might have at the toplevel of a manifest. Right now, some
  # of these constructs will lead to a Runtime error "Visitor Error"
  # (vistor.rb:46)

  def find_Program(o)
    @locator = o.locator

    # @todo lutter 2014-11-18: Make all the defined types defined in the
    # top scope. This is just cargo culted; what's the right way to do this
    # ?
    @program = Puppet::Parser::AST::PopsBridge::Program.new(o)
    ast_code = @program.instantiate("")
    ast_code.each do |ast|
      @scope.known_resource_types.add(ast)
    end
    find(o.body)
  end

  def find_BlockExpression(o)
    o.statements.each { |st| find(st) }
  end

  def find_NodeDefinition(o)
    # we do not look into node blocks
  end

  # Extract component definitions
  def find_ResourceTypeDefinition(o)
    # Do nothing, this is done by the black magic in find_Program
  end

  # Extract application instantiations
  def find_ResourceExpression(o)
    # This might be an application instantiation
    @resources << o
  end

  # Extract application definitions
  def find_Application(o)
    # @todo lutter 2014-09-09: check that everything consumed is also
    # produced by some component
    name = model_eval(o.name)
    @definitions[name] = o
  end

  def find_Nop(o)
    nil
  end

  # @todo lutter 2014-11-19: callback from expand_CallMethodExpression via
  # call_function; patterned after
  # Puppet::Pops::Evaluator::EvaluatorImpl#evaluate_block_with_bindings
  def evaluate_block_with_bindings(scope, variable_bindings, block_expr)
    with_guarded_scope(scope) do
      # change to create local scope_from - cannot give it file and line -
      # that is the place of the call, not "here"
      create_local_scope_from(variable_bindings, scope)
      @@expand_visitor.visit_this_2(self, block_expr, @app, scope)
    end
  end

  private
  def init_scope
    # @todo lutter 2014-11-17: all this setup is so that we ultimately get
    # a scope that we can pass to an evaluator to evaluate choice pieces of
    # the manifest

    # We don't really have a node, but the compiler needs one
    node_name = 'no-such-node.example.com'
    node = Puppet::Node.new(node_name)
    # @todo lutter 2014-11-17: don't hardcode the environment in which we
    # are working
    node.environment = Puppet::Node::Environment.create(@environment, [])
    compiler = Puppet::Parser::Compiler.new(node)
    @scope = Puppet::Parser::Scope.new(compiler)
    @scope.source = Puppet::Resource::Type.new(:node, 'node.example.com')
    @scope.parent = compiler.topscope

  end

  # Evaluate some part of the model in the our scope
  def model_eval(model, scope = nil)
    scope ||= @scope
    @@evaluator ||= Puppet::Pops::Evaluator::EvaluatorImpl.new()
    @@evaluator.evaluate(model, scope)
  end

  # @todo lutter 2014-11-19: copied from
  # Puppet::Pops::Evaluator::EvaluatorImpl#unfold
  def unfold(result, array, scope)
    array.each do |x|
      if x.is_a?(Puppet::Pops::Model::UnfoldExpression)
        result.concat(evaluate(x, scope))
      else
        result << evaluate(x, scope)
      end
    end
    result
  end

  # @todo lutter 2014-11-19: copied from
  # Puppet::Pops::Evaluator::Runtime3Support#call_function
  def call_function(name, args, o, scope)
    Puppet::Util::Profiler.profile("Called #{name}", [:functions, name]) do
      # Call via 4x API if the function exists there
      loaders = scope.compiler.loaders
      # find the loader that loaded the code, or use the private_environment_loader (sees env + all modules)
      adapter = Puppet::Pops::Utils.find_adapter(o, Puppet::Pops::Adapters::LoaderAdapter)
      loader = adapter.nil? ? loaders.private_environment_loader : adapter.loader
      if loader && func = loader.load(:function, name)
        return func.call(scope, *args)
      end

      # Call via 3x API if function exists there
      fail(Puppet::Pops::Issues::UNKNOWN_FUNCTION, o, {:name => name}) unless Puppet::Parser::Functions.function(name)

      # Arguments must be mapped since functions are unaware of the new and magical creatures in 4x.
      # NOTE: Passing an empty string last converts nil/:undef to empty string
      mapped_args = args.map {|a| convert(a, scope, '') }
      result = scope.send("function_#{name}", mapped_args)
      # Prevent non r-value functions from leaking their result (they are not written to care about this)
      Puppet::Parser::Functions.rvalue?(name) ? result : nil
    end
  end

  # @todo lutter 2014-11-19: copied from
  # Puppet::Pops::Evaluator::EvaluatorImpl
  def with_guarded_scope(scope)
    scope_memo = scope.ephemeral_level
    begin
      yield
    ensure
      scope.unset_ephemeral_var(scope_memo)
    end
  end

  # @todo lutter 2014-11-19: Puppet::Pops::Evaluator::Runtime3Support
  def create_local_scope_from(hash, scope)
    # two dummy values are needed since the scope tries to give an error message (can not happen in this
    # case - it is just wrong, the error should be reported by the caller who knows in more detail where it
    # is in the source.
    #
    raise ArgumentError, "Internal error - attempt to create a local scope without a hash" unless hash.is_a?(Hash)
    scope.ephemeral_from(hash)
  end
end

class Puppet::Application::App < Puppet::Application

  def help
    <<-'HELP'

puppet-app(8) -- Manage cross-node applications
========

SYNOPSIS
--------
Read a manifest describing and mapping an application and run the Puppet
agent on each node participating in the application

USAGE
-----

puppet app [-j|--json <FILE>] <file.pp>

OPTIONS
-------

* --json:
  Write the environment catalog to <FILE> as a JSON document

COPYRIGHT
---------
Copyright (c) 2014 Puppet Labs, LLC Licensed under the Apache 2.0 License

    HELP
  end

  option("--json FILE", "-j") do |arg|
    options[:json] = arg
  end

  def main
    if command_line.args.size != 1
      puts "usage: puppet app <file.pp>"
      exit(1)
    end
    file = command_line.args[0]

    # Force future parser
    Puppet[:parser] = 'future'

    # @todo lutter 2014-11-17: this whole business should become the
    # compile method on AppCompiler
    parser = Puppet::Pops::Parser::Parser.new()
    ast = parser.parse_file(file)
    # puts Puppet::Pops::Model::ModelTreeDumper.new.dump(ast)

    # Walk the AST and extract application definitions
    compiler = AppCompiler.new(:development)
    compiler.find(ast.current)

    compiler.eval

    env_graph = {:environment => 'development', :applications => {}}
    puts "Application instances:"
    compiler.applications.each do |app|
      app_components = {}
      puts "  #{app.ref}"
      puts "    components:"
      app.mapping.components.each do |comp|
        app_components[comp.ref] = {:produces => comp.produces.map(&:ref), :consumes => comp.consumes.map(&:ref)}
        puts " " * 6 + comp.inspect
      end
      puts "    mapping:"
      app.mapping.components_by_node.each do |node, comps|
        comps.each do |comp|
          app_components[comp.ref][:node] = node
        end
        puts " " * 6 + "Node[#{node}] : [#{comps.map(&:to_s).join(",")}]"
      end
      puts
      env_graph[:applications][app.ref] = app_components
    end
    if options[:json]
      File.open(options[:json], "w") { |fp| fp.puts JSON.pretty_generate(env_graph) }
      puts "Wrote environment catalog to #{options[:json]}"
    end

    # Build the NodeGraph
    ng = NodeGraph.new
    ng = compiler.applications.inject(NodeGraph.new) do |ng, app|
      ng.add_app(app)
      ng
    end

    puts "Node graph:"
    ng.nodes.keys.sort.each do |src|
      if ng.nodes[src].empty?
        printf "  %-10s    (root)\n" % src
      else
        printf "  %-10s -> %s\n" % [ src, ng.nodes[src].join(",") ]
      end
    end

    puts "\nRun puppet in this order:"
    ng.order.each do |node|
      puts "  ssh #{node} puppet agent -otv"
    end
  rescue => e
    puts "error: #{e}"
    puts e.backtrace
  end

end
