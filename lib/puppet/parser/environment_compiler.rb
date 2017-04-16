require 'puppet/parser/compiler'

class Puppet::Parser::EnvironmentCompiler < Puppet::Parser::Compiler
  def self.compile(env)
    $env_module_directories = nil
    env.check_for_reparse

    node = Puppet::Node.new(env)
    node.environment = env
    new(node).compile
  rescue => detail
    message = "#{detail} in environment #{env.name}"
    Puppet.log_exception(detail, message)
    raise Puppet::Error, message, detail.backtrace
  end

  def compile
    Puppet.override(@context_overrides, "For compiling environment #{environment.name}") do
      @catalog.environment_instance = environment

      Puppet::Util::Profiler.profile("Compile: Created settings scope", [:compiler, :create_settings_scope]) { create_settings_scope }

      activate_binder

      Puppet::Util::Profiler.profile("Compile: Evaluated main", [:compiler, :evaluate_main]) { evaluate_main }

      Puppet::Util::Profiler.profile("Compile: Evaluated application instances", [:compiler, :evaluate_applications]) { evaluate_applications }

      Puppet::Util::Profiler.profile("Compile: Evaluated produced capability resources", [:compiler, :evaluate_capabilities]) { evaluate_capabilities }

      Puppet::Util::Profiler.profile("Compile: Finished catalog", [:compiler, :finish_catalog]) { finish }

      fail_on_unevaluated

      if block_given?
        yield @catalog
      else
        @catalog
      end
    end
  end

  def add_resource(scope, resource)
    type = resource.resource_type
    # At topscope, only applications and Class[main] are allowed. Elsewhere,
    # only components and capabilities are allowed.
    if scope == @topscope
      if ! (type.is_a?(Puppet::Resource::Type) && type.application?) && resource != @main_resource
        raise ArgumentError, "Only applications are allowed at topscope, not #{resource.ref}"
      end
    else
      if (type.is_a?(Puppet::Resource::Type) && (type.produces.empty? && resource.consumes.empty?)) || (type.is_a?(Puppet::Type) && type.is_capability?)
        raise ArgumentError, "Only components are allowed inside applications, not #{resource.ref}"
      end
    end

    @resources << resource

    # Note that this will fail if the resource is not unique.
    @catalog.add_resource(resource)

    if not resource.class? and resource[:stage]
      raise ArgumentError, "Only classes can set 'stage'; normal resources like #{resource} cannot change run stage"
    end

    # Stages should not be inside of classes.  They are always a
    # top-level container, regardless of where they appear in the
    # manifest.
    return if resource.stage?

    # This adds a resource to the class it lexically appears in in the
    # manifest.
    unless resource.class?
      return @catalog.add_edge(scope.resource, resource)
    end
  end

  def evaluate_applications
    exceptwrap do
      resources.select { |resource| type = resource.resource_type; type.is_a?(Puppet::Resource::Type) && type.application? }.each do |resource|
        Puppet::Util::Profiler.profile("Evaluated resource #{resource}", [:compiler, :evaluate_resource, resource]) do
          resource.evaluate
        end
      end
    end
  end

  def evaluate_capabilities
    exceptwrap do
      resources.select { |resource| ! resource.resource_type.produces.empty? }.each do |resource|
        Puppet::Util::Profiler.profile("Evaluated resource #{resource}", [:compiler, :evaluate_resource, resource]) do
          resource.resource_type.evaluate_produces(resource)
        end
      end
    end
  end
end
