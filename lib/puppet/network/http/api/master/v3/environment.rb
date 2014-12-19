require 'json'

class Puppet::Network::HTTP::API::Master::V3::Environment
  def call(request, response)
    require 'puppet/application/app'

    env_name = request.routing_path.split('/').last
    env = Puppet.lookup(:environments).get(env_name)

    if File.directory?(env.manifest)
      manifests = Puppet::FileSystem::PathPattern.absolute(File.join(env.manifest, '**/*.pp')).glob
    else
      manifests = [env.manifest]
    end

    compiler = AppCompiler.new(env.name)

    parser = Puppet::Pops::Parser::Parser.new
    manifests.each do |manifest|
      ast = parser.parse_file(manifest)
      compiler.find(ast.current)
    end

    compiler.eval

    env_graph = {:environment => env.name, :applications => {}}
    compiler.applications.each do |app|
      app_components = {}
      app.mapping.components.each do |comp|
        app_components[comp.ref] = {:produces => comp.produces.map(&:ref), :consumes => comp.consumes.map(&:ref)}
      end
      app.mapping.components_by_node.each do |node, comps|
        comps.each do |comp|
          app_components[comp.ref][:node] = node
        end
      end
      env_graph[:applications][app.ref] = app_components
    end

    response.respond_with(200, "application/json", JSON.dump(env_graph))
  end

end

