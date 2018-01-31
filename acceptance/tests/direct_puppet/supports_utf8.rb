test_name "C97172: static catalogs support utf8" do

  confine :except, :platform => /^cisco_/ # skip the test because some of the machines have LANG=C as the default and we break
  confine :except, :platform => /^solaris/ # skip the test because some of the machines have LANG=C as the default and we break

  require 'puppet/acceptance/environment_utils'
  extend Puppet::Acceptance::EnvironmentUtils

  require 'puppet/acceptance/agent_fqdn_utils'
  extend Puppet::Acceptance::AgentFqdnUtils

  app_type = File.basename(__FILE__, '.*')
  tmp_environment   = mk_tmp_environment_with_teardown(master, app_type)

  tmp_file = {}
  agents.each do |agent|
    if agent.platform =~ /^(eos-4-i386|cumulus-2\.5|osx|sles-10)/
      # skip_test doesn't work in with_puppet_running_on blocks (tableflip)
      #   so we can't easily use expect_failure here
      skip_test 'PUP-6217'
    end
    tmp_file[agent_to_fqdn(agent)] = agent.tmpfile(tmp_environment)
  end

  teardown do
    step 'clean out produced resources' do
      agents.each do |agent|
        if tmp_file.has_key?(agent_to_fqdn(agent)) && !tmp_file[agent_to_fqdn(agent)].empty?
          on(agent, "rm -f '#{tmp_file[agent_to_fqdn(agent)]}'")
        end
      end
    end
  end

  file_contents     = 'Mønti Pythøn ik den Hølie Gräilen, yër? € ‰ ㄘ 万 竹 Ü Ö'
  step 'create site.pp with utf8 chars' do
    manifest = <<MANIFEST
file { '#{environmentpath}/#{tmp_environment}/manifests/site.pp':
  ensure => file,
  content => '
\$test_path = \$::fqdn ? #{tmp_file}
file { \$test_path:
  content => @(UTF8)
    #{file_contents}
    | UTF8
}
  ',
}
MANIFEST
    apply_manifest_on(master, manifest, :catch_failures => true)
  end

  step 'run agent(s)' do
    with_puppet_running_on(master, {}) do
      agents.each do |agent|
        config_version = ''
        config_version_matcher = /configuration version '(\d+)'/
        on(agent, puppet("agent -t --environment '#{tmp_environment}' --server #{master.hostname}"),
           :acceptable_exit_codes => 2).stdout do |result|
          config_version = result.match(config_version_matcher)[1]
        end
        on(agent, "cat '#{tmp_file[agent_to_fqdn(agent)]}'").stdout do |result|
          assert_equal(file_contents, result, 'file contents did not match accepted')
        end

        on(agent, "rm -f '#{tmp_file[agent_to_fqdn(agent)]}'")
        on(agent, puppet("agent -t --environment '#{tmp_environment}' --server #{master.hostname} --use_cached_catalog"),
           :acceptable_exit_codes => 2).stdout do |result|
          assert_match(config_version_matcher, result, 'agent did not use cached catalog')
          second_config_version = result.match(config_version_matcher)[1]
          asset_equal(config_version, second_config_version, 'config version should have been the same')
        end
        on(agent, "cat '#{tmp_file[agent_to_fqdn(agent)]}'").stdout do |result|
          assert_equal(file_contents, result, 'file contents did not match accepted')
        end
      end
    end
  end

end
