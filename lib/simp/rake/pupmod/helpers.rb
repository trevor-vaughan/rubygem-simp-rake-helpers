require 'puppetlabs_spec_helper/rake_tasks'
require 'puppet/version'
require 'puppet/vendor/semantic/lib/semantic' unless Puppet.version.to_f < 3.6
require 'puppet-syntax/tasks/puppet-syntax'
require 'puppet-lint/tasks/puppet-lint'
require 'simp/rake/pkg'
require 'simp/rake/beaker'

module Simp; end
module Simp::Rake; end
module Simp::Rake::Pupmod; end

# Rake tasks for SIMP Puppet modules
class Simp::Rake::Pupmod::Helpers < ::Rake::TaskLib
  def initialize( base_dir = Dir.pwd )
    @base_dir = base_dir
    Dir[ File.join(File.dirname(__FILE__),'*.rb') ].each do |rake_file|
      next if rake_file == __FILE__
      require rake_file
    end
    define_tasks
  end

  def define_tasks
    # These gems aren't always present, for instance
    # on Travis with --without development
    begin
      require 'puppet_blacksmith/rake_tasks'
    rescue LoadError
    end


    # Lint & Syntax exclusions
    exclude_paths = [
      "bundle/**/*",
      "pkg/**/*",
      "dist/**/*",
      "vendor/**/*",
      "spec/**/*",
    ]
    PuppetSyntax.exclude_paths = exclude_paths

    # See: https://github.com/rodjek/puppet-lint/pull/397
    Rake::Task[:lint].clear
    PuppetLint.configuration.ignore_paths = exclude_paths
    PuppetLint::RakeTask.new :lint do |config|
      config.ignore_paths = PuppetLint.configuration.ignore_paths
    end

    Simp::Rake::Pkg.new( @base_dir ) do | t |
      t.clean_list << "#{t.base_dir}/spec/fixtures/hieradata/hiera.yaml"
    end

    Simp::Rake::Beaker.new( @base_dir )

    desc "Run acceptance tests"
    RSpec::Core::RakeTask.new(:acceptance) do |t|
      t.pattern = 'spec/acceptance'
    end

    desc "Populate CONTRIBUTORS file"
    task :contributors do
      system("git log --format='%aN' | sort -u > CONTRIBUTORS")
    end

    task :metadata do
      sh "metadata-json-lint metadata.json"
    end

    desc "Run syntax, lint, and spec tests."
    task :test => [
      :syntax,
      :lint,
      :spec,
      :metadata,
    ]
  end
end