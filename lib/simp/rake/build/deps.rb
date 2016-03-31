#!/usr/bin/rake -T

require 'yaml'

class R10KHelper
  attr_accessor :puppetfile
  attr_accessor :modules
  attr_accessor :basedir

  require 'r10k/puppetfile'

  # Horrible, but we need to be able to manipulate the cache
  class R10K::Git::ShellGit::ThinRepository
    def cache_repo
      @cache_repo
    end

    # Return true if the repository has local modifications, false otherwise.
    def dirty?
      repo_status = false

      return repo_status unless File.directory?(path)

      Dir.chdir(path) do
        %x(git update-index -q --ignore-submodules --refresh)
        repo_status = "Could not update git index for '#{path}'" unless $?.success?

        unless repo_status
          %x(git diff-files --quiet --ignore-submodules --)
          repo_status = "'#{path}' has unstaged changes" unless $?.success?
        end

        unless repo_status
          %x(git diff-index --cached --quiet HEAD --ignore-submodules --)
          repo_status = "'#{path}' has uncommitted changes" unless $?.success?
        end

        unless repo_status
          untracked_files = %x(git ls-files -o -d --exclude-standard)

          if $?.success?
            unless untracked_files.empty?
              untracked_files.strip!

              if untracked_files.lines.count > 0
                repo_status = "'#{path}' has untracked files"
              end
            end
          else
            # We should never get here
            raise Error, "Failure running 'git ls-files -o -d --exclude-standard' at '#{path}'"
          end
        end
      end

      repo_status
    end
  end

  def initialize(puppetfile)
    @modules = []
    @basedir = File.dirname(File.expand_path(puppetfile))
    Dir.chdir(@basedir) do

      R10K::Git::Cache.settings[:cache_root] = File.join(@basedir,'.r10k_cache')

      unless File.directory?(R10K::Git::Cache.settings[:cache_root])
        FileUtils.mkdir_p(R10K::Git::Cache.settings[:cache_root])
      end

      r10k = R10K::Puppetfile.new(Dir.pwd, nil, puppetfile).load!

      @modules = r10k.entries.collect do |mod|
        mod_status = mod.repo.repo.dirty?

        mod = {
          :name        => mod.name,
          :path        => mod.path.to_s,
          :git_source  => mod.repo.repo.origin,
          :git_ref     => mod.repo.head,
          :module_dir  => mod.basedir,
          :status      => mod_status ? mod_status : :known,
          :r10k_module => mod,
          :r10k_cache  => mod.repo.repo.cache_repo
        }
      end
    end

    module_dirs = @modules.collect do |mod|
      mod = mod[:module_dir]
    end

    module_dirs.uniq!

    module_dirs.each do |module_dir|
      known_modules = @modules.select do |mod|
        mod[:module_dir] == module_dir
      end

      known_modules.map! do |mod|
        mod = mod[:name]
      end

      current_modules = Dir.glob(File.join(module_dir,'*')).map do |mod|
        mod = File.basename(mod)
      end

      (current_modules - known_modules).each do |mod|
        # Did we find random git repos in our module spaces?
        if File.exist?(File.join(module_dir, mod, '.git'))
          @modules << {
            :name        => mod,
            :path        => File.join(module_dir, mod),
            :module_dir  => module_dir,
            :status      => :unknown,
          }
        end
      end
    end
  end

  def puppetfile
    last_module_dir = nil
    str = StringIO.new
    @modules.each do |mod|
      if last_module_dir != mod[:module_dir]
        str.puts "module_dir '#{mod[:module_dir]}'"
        last_module_dir = mod[:module_dir]
      end

      str.puts "mod '#{name}',"
      str.puts (opts.map{|k,v| "  :#{k} => '#{v}'"}).join(",\n") , ''
    end
    str.string
  end

  def each_module(&block)
    Dir.chdir(@basedir) do
      @modules.each do |mod|
        # This works for Puppet Modules

        unless File.directory?(mod[:path])
          FileUtils.mkdir_p(mod[:path])
        end

        block.call(mod)
      end
    end
  end
end

module Simp; end
module Simp::Rake; end
module Simp::Rake::Build

  class Deps < ::Rake::TaskLib

    def initialize( base_dir )
      @base_dir = base_dir
      define_tasks
    end

    def define_tasks
      namespace :deps do
        desc <<-EOM
        Checks out all dependency repos.

        This task used R10k to update all dependencies.

        Arguments:
          * :method  => The update method to use (Default => 'tracking')
               tracking => checks out each dep (by branch) according to Puppetfile.tracking
               stable   => checks out each dep (by ref) according to in Puppetfile.stable
        EOM
        task :checkout, [:method] do |t,args|
          args.with_defaults(:method => 'tracking')

          r10k_helper = R10KHelper.new("Puppetfile.#{args[:method]}")

          r10k_helper.each_module do |mod|
            # Since r10k is destructive, we're enumerating all valid states
            # here
            if [:absent, :mismatched, :outdated].include?(mod[:r10k_module].status)
              unless mod[:r10k_cache].synced?
                mod[:r10k_cache].sync
              end

              if mod[:status] == :known
                mod[:r10k_module].sync
              else
                # If we get here, the module was dirty and should be skipped
                puts "#{mod[:name]}: Skipping - #{mod[:status]}"
                next
              end
            else
              puts "#{mod[:name]}: Skipping - Unknown status type #{mod[:r10k_module].status}"
            end
          end
        end

        desc <<-EOM
        Get the status of the project Git repositories

        Arguments:
          * :method  => The update method to use (Default => 'tracking')
               tracking => checks out each dep (by branch) according to Puppetfile.tracking
               stable   => checks out each dep (by ref) according to in Puppetfile.stable
        EOM
        task :status, [:method] do |t,args|
          args.with_defaults(:method => 'tracking')
          @dirty_repos = nil

          fake_lp = FakeLibrarian.new("Puppetfile.#{args[:method]}")
          mods_with_changes = {}

          fake_lp.each_module do |environment, name, path|
            unless File.directory?(path)
              $stderr.puts("Warning: '#{path}' is not a module...skipping")
              next
            end

            repo = Librarian::Puppet::Source::Git::Repository.new(environment,path)
            if repo.dirty?
              # Clean up the path a bit for printing
              dirty_path = path.split(environment.project_path.to_s).last
              if dirty_path[0].chr == File::SEPARATOR
                dirty_path[0] = ''
              end

              mods_with_changes[name] = dirty_path
            end
          end

          if mods_with_changes.empty?
            puts "No repositories have changes."
            @dirty_repos = false
          else
            puts "The following repositories have changes:"
            puts mods_with_changes.map{|k,v| "  + #{k} => #{v}"}.join("\n")

            @dirty_repos = true
          end

          unknown_mods = fake_lp.unknown_modules
          unless unknown_mods.empty?
            puts "The following modules were unknown:"
            puts unknown_mods.map{|k,v| "  ? #{k}"}.join("\n")
          end
        end

        desc 'Records the current dependencies into Puppetfile.stable.'
        task :record do
          fake_lp     = FakeLibrarian.new('Puppetfile.tracking')
          modules     = fake_lp.modules

          fake_lp.each_module do |environment, name, path|
            Dir.chdir(path) do
              modules[name][:ref] = %x{git rev-parse --verify HEAD}.strip
            end
          end

          fake_lp.modules = modules
          File.open('Puppetfile.stable','w'){|f| f.puts fake_lp.puppetfile }
        end
      end
    end
  end
end
