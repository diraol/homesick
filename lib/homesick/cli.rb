# -*- encoding : utf-8 -*-
require 'thor'

module Homesick
  # Homesick's command line interface
  class CLI < Thor
    include Thor::Actions
    include Homesick::Actions
    include Homesick::Version
    include Homesick::Utils

    add_runtime_options!

    map '-v' => :version
    map '--version' => :version
    # Retain a mapped version of the symlink command for compatibility.
    map symlink: :link

    def initialize(args = [], options = {}, config = {})
      super
      self.shell = Homesick::Shell.new
    end

    desc 'clone URI', 'Clone +uri+ as a castle for homesick'
    def clone(uri)
      inside repos_dir do
        destination = nil
        if File.exist?(uri)
          uri = Pathname.new(uri).expand_path
          fail "Castle already cloned to #{uri}" if uri.to_s.start_with?(repos_dir.to_s)

          destination = uri.basename

          ln_s uri, destination
        elsif uri =~ GITHUB_NAME_REPO_PATTERN
          destination = Pathname.new(uri).basename
          git_clone "https://github.com/#{Regexp.last_match[1]}.git",
                    destination: destination
        elsif uri =~ /%r([^%r]*?)(\.git)?\Z/ || uri =~ /[^:]+:([^:]+)(\.git)?\Z/
          destination = Pathname.new(Regexp.last_match[1])
          git_clone uri
        else
          fail "Unknown URI format: #{uri}"
        end

        setup_castle(destination)
      end
    end

    desc 'rc CASTLE', 'Run the .homesickrc for the specified castle'
    def rc(name = DEFAULT_CASTLE_NAME)
      inside repos_dir do
        destination = Pathname.new(name)
        homesickrc = destination.join('.homesickrc').expand_path
        if homesickrc.exist?
          proceed = shell.yes?("#{name} has a .homesickrc. Proceed with evaling it? (This could be destructive)")
          if proceed
            shell.say_status 'eval', homesickrc
            inside destination do
              eval homesickrc.read, binding, homesickrc.expand_path.to_s
            end
          else
            shell.say_status 'eval skip',
                             "not evaling #{homesickrc}, #{destination} may need manual configuration",
                             :blue
          end
        end
      end
    end

    desc 'pull CASTLE', 'Update the specified castle'
    method_option :all,
                  type: :boolean,
                  default: false,
                  required: false,
                  desc: 'Update all cloned castles'
    def pull(name = DEFAULT_CASTLE_NAME)
      if options[:all]
        inside_each_castle do |castle|
          shell.say castle.to_s.gsub(repos_dir.to_s + '/', '') + ':'
          update_castle castle
        end
      else
        update_castle name
      end
    end

    desc 'commit CASTLE MESSAGE', "Commit the specified castle's changes"
    def commit(name = DEFAULT_CASTLE_NAME, message = nil)
      commit_castle name, message
    end

    desc 'push CASTLE', 'Push the specified castle'
    def push(name = DEFAULT_CASTLE_NAME)
      push_castle name
    end

    desc 'unlink CASTLE', 'Unsymlinks all dotfiles from the specified castle'
    def unlink(name = DEFAULT_CASTLE_NAME)
      check_castle_existance(name, 'symlink')

      inside castle_dir(name) do
        subdirs = subdirs(name)

        # unlink files
        unsymlink_each(name, castle_dir(name), subdirs)

        # unlink files in subdirs
        subdirs.each do |subdir|
          unsymlink_each(name, subdir, subdirs)
        end
      end
    end

    desc 'link CASTLE', 'Symlinks all dotfiles from the specified castle'
    method_option :force,
                  default: false,
                  desc: 'Overwrite existing conflicting symlinks without prompting.'
    def link(name = DEFAULT_CASTLE_NAME)
      check_castle_existance(name, 'symlink')

      inside castle_dir(name) do
        subdirs = subdirs(name)

        # link files
        symlink_each(name, castle_dir(name), subdirs)

        # link files in subdirs
        subdirs.each do |subdir|
          symlink_each(name, subdir, subdirs)
        end
      end
    end

    desc 'track FILE CASTLE', 'add a file to a castle'
    def track(file, castle = DEFAULT_CASTLE_NAME)
      castle = Pathname.new(castle)
      file = Pathname.new(file.chomp('/'))
      check_castle_existance(castle, 'track')

      absolute_path = file.expand_path
      relative_dir = absolute_path.relative_path_from(home_dir).dirname
      castle_path = Pathname.new(castle_dir(castle)).join(relative_dir)
      FileUtils.mkdir_p castle_path

      # Are we already tracking this or anything inside it?
      target = Pathname.new(castle_path.join(file.basename))
      if target.exist?
        if absolute_path.directory?
          move_dir_contents(target, absolute_path)
          absolute_path.rmtree
          subdir_remove(castle, relative_dir + file.basename)

        elsif more_recent? absolute_path, target
          target.delete
          mv absolute_path, castle_path
        else
          shell.say_status(:track,
                           "#{target} already exists, and is more recent than #{file}. Run 'homesick SYMLINK CASTLE' to create symlinks.",
                           :blue) unless options[:quiet]
        end
      else
        mv absolute_path, castle_path
      end

      inside home_dir do
        absolute_path = castle_path + file.basename
        home_path = home_dir + relative_dir + file.basename
        ln_s absolute_path, home_path
      end

      inside castle_path do
        git_add absolute_path
      end

      # are we tracking something nested? Add the parent dir to the manifest
      subdir_add(castle, relative_dir) unless relative_dir.eql?(Pathname.new('.'))
    end

    desc 'list', 'List cloned castles'
    def list
      inside_each_castle do |castle|
        say_status castle.relative_path_from(repos_dir).to_s,
                   `git config remote.origin.url`.chomp,
                   :cyan
      end
    end

    desc 'status CASTLE', 'Shows the git status of a castle'
    def status(castle = DEFAULT_CASTLE_NAME)
      check_castle_existance(castle, 'status')
      inside repos_dir.join(castle) do
        git_status
      end
    end

    desc 'diff CASTLE', 'Shows the git diff of uncommitted changes in a castle'
    def diff(castle = DEFAULT_CASTLE_NAME)
      check_castle_existance(castle, 'diff')
      inside repos_dir.join(castle) do
        git_diff
      end
    end

    desc 'show_path CASTLE', 'Prints the path of a castle'
    def show_path(castle = DEFAULT_CASTLE_NAME)
      check_castle_existance(castle, 'show_path')
      say repos_dir.join(castle)
    end

    desc 'generate PATH', 'generate a homesick-ready git repo at PATH'
    def generate(castle)
      castle = Pathname.new(castle).expand_path

      github_user = `git config github.user`.chomp
      github_user = nil if github_user == ''
      github_repo = castle.basename

      empty_directory castle
      inside castle do
        git_init
        if github_user
          url = "git@github.com:#{github_user}/#{github_repo}.git"
          git_remote_add 'origin', url
        end

        empty_directory 'home'
      end
    end

    desc 'destroy CASTLE', 'Delete all symlinks and remove the cloned repository'
    def destroy(name)
      check_castle_existance name, 'destroy'

      if shell.yes?('This will destroy your castle irreversible! Are you sure?')
        unlink(name)
        rm_rf repos_dir.join(name)
      end
    end

    desc 'cd CASTLE', 'Open a new shell in the root of the given castle'
    def cd(castle = DEFAULT_CASTLE_NAME)
      check_castle_existance castle, 'cd'
      castle_dir = repos_dir.join(castle)
      say_status "cd #{castle_dir.realpath}",
                 "Opening a new shell in castle '#{castle}'. To return to the original one exit from the new shell.",
                 :green
      inside castle_dir do
        system(ENV['SHELL'])
      end
    end

    desc 'open CASTLE',
         'Open your default editor in the root of the given castle'
    def open(castle = DEFAULT_CASTLE_NAME)
      unless ENV['EDITOR']
        say_status :error,
                   'The $EDITOR environment variable must be set to use this command',
                   :red

        exit(1)
      end
      check_castle_existance castle, 'open'
      castle_dir = repos_dir.join(castle)
      say_status "#{ENV['EDITOR']} #{castle_dir.realpath}",
                 "Opening the root directory of castle '#{castle}' in editor '#{ENV['EDITOR']}'.",
                 :green
      inside castle_dir do
        system(ENV['EDITOR'])
      end
    end

    desc 'exec CASTLE COMMAND',
         'Execute a single shell command inside the root of a castle'
    method_option :pretend,
                  type: :boolean,
                  default: false,
                  required: false,
                  desc: 'Perform a dry run of the command'
    method_option :quiet,
                  type: :boolean,
                  default: false,
                  required: false,
                  desc: 'Run a command without any output from Homesick'
    def exec(castle, *args)
      check_castle_existance castle, 'exec'
      unless args.count > 0
        say_status :error,
                   'You must pass a shell command to execute',
                   :red
        exit(1)
      end
      full_command = args.join(' ')
      say_status "exec '#{full_command}'",
                 "#{options[:pretend] ? 'Would execute' : 'Executing command'} '#{full_command}' in castle '#{castle}'",
                 :green unless options[:quiet]
      inside repos_dir.join(castle) do
        system(full_command) unless options[:pretend]
      end
    end

    desc 'exec_all COMMAND',
         'Execute a single shell command inside the root of every cloned castle'
    method_option :pretend,
                  type: :boolean,
                  default: false,
                  required: false,
                  desc: 'Perform a dry run of the command'
    method_option :quiet,
                  type: :boolean,
                  default: false,
                  required: false,
                  desc: 'Run a command without any output from Homesick'
    def exec_all(*args)
      unless args.count > 0
        say_status :error,
                   'You must pass a shell command to execute',
                   :red
        exit(1)
      end
      full_command = args.join(' ')
      inside_each_castle do |castle|
        say_status "exec '#{full_command}'",
                   "#{options[:pretend] ? 'Would execute' : 'Executing command'} '#{full_command}' in castle '#{castle}'",
                   :green unless options[:quiet]
        system(full_command) unless options[:pretend]
      end
    end

    desc 'version', 'Display the current version of homesick'
    def version
      say Homesick::Version::STRING
    end
  end
end
