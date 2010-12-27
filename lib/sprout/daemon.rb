
module Sprout

  ##
  # The Sprout::Daemon class exposes the Domain Specific Language
  # provided by the Sprout::Executable, along with
  # enhancements (and modifications) to support long-lived processes
  # (like FDB and FCSH).
  #
  #   ##
  #   # The Foo class extends Sprout::Daemon
  #   class Foo < Sprout::Daemon
  #
  #     ##
  #     # Keep in mind that we're still working
  #     # with Executable, so add_param is available
  #     # for the initialization of the process.
  #     add_param :input, File
  #
  #     ##
  #     # Expose the do_something action after
  #     # the process is started.
  #     add_action :do_something
  #
  #     ##
  #     # Expose the do_something_else action after
  #     # the process is started.
  #     add_action :do_something_else
  #   end
  #
  # You can also create a globally-accessible rake task to use
  # your new Daemon instance by creating a method like the following:
  #
  #   def foo *args, &block
  #     foo_tool = Foo.new
  #     foo_tool.to_rake *args, &block
  #   end
  #
  # The previous Rake task could be used like:
  #
  #   foo 'Bar.txt' do |t|
  #     t.do_something
  #     t.do_something_else
  #   end
  #
  class Daemon < Executable::Base

    class << self

      ##
      # Add an action that can be called while
      # the long-lived process is active.
      #
      # This method should raise a Sprout::Errors::UsageError
      # if the provided action name is already defined for 
      # the provided instance.
      #
      # @param name [Symbol, String] The name of the method.
      # @param arguments [Array<Object>] An array of arguments that the method accepts.
      # @param options [Hash] The options hash is reserved for future use.
      #
      #   class Foo < Sprout::Daemon
      #     
      #     add_action :continue
      #
      #     add_action :quit
      #   end
      #
      # @return [nil]
      def add_action name, arguments=nil, options=nil
        options ||= {}
        options[:name] = name
        options[:arguments] = arguments
        create_action_method options
        nil
      end

      ##
      # Create an (often shorter) alias to an existing
      # action name.
      #
      # @return [nil]
      #
      # @see add_action
      def add_action_alias alias_name, source_name
        define_method(alias_name) do |*params|
          self.send(source_name, params)
        end
        nil
      end

      private

      ##
      # Actually create the method for a provided
      # action.
      #
      # This method should explode if the method name
      # already exists.
      def create_action_method options
        name = options[:name]
        accessor_can_be_defined_at name

        define_method(name) do |*params|
          action = name.to_s
          action = "y" if name == :confirm # Convert affirmation
          action << " #{params.join(' ')}" unless params.nil?
          action_stack << action
          execute_actions if process_launched?
        end
      end

      ##
      # TODO: Raise an exception if the name is 
      # already taken?
      def accessor_can_be_defined_at name
      end

    end


    ##
    # The prompt expression for this daemon process.
    #
    # When executing a series of commands, the
    # wrapper will wait until it matches this expression
    # on stdout before continuing the series.
    #
    # For FDB, this value is set like:
    #
    #   set :prompt, /^\(fdb\) /
    #
    # Most processes can trigger a variety of different
    # prompts, these can be expressed here using the | (or) operator.
    #
    # FDB actually uses the following:
    #
    #   set :prompt, /^\(fdb\) |\(y or n\) /
    #
    # @return [Regexp]
    attr_accessor :prompt


    ##
    # The Sprout::ProcessRunner that delegates to the long-running process,
    # via stdin, stdout and stderr.
    attr_reader :process_runner

    ##
    # @return [Array<Hash>] Return or create a new array.
    def action_stack
      @action_stack ||= []
    end

    ##
    # Execute the Daemon executable, followed
    # by the collection of stored actions in 
    # the order they were called.
    #
    # If none of the stored actions result in
    # terminating the process, the underlying
    # daemon will be connected to the terminal
    # for user (manual) input.
    #
    # You can also send wait=false to connect
    # to a daemon process from Ruby and execute
    # actions over time. This might look like:
    #
    #    fdb = FlashSDK::FDB.new
    #    fdb.execute false
    #
    #    # Do something else while FDB
    #    # is open, then:
    #    
    #    fdb.run
    #    fdb.break "AsUnitRunner:12"
    #    fdb.continue
    #    fdb.kill
    #    fdb.confirm
    #    fdb.quit
    #
    # @param wait [Boolean] default true. Send false to
    #   connect to a daemon from Ruby code.
    #
    def execute wait=true
      @process_runner = super()
      @process_launched = true
      wait_for_prompt
      execute_actions
      handle_user_session if wait
      Process.wait process_runner.pid if wait
    end

    ##
    # Wait for the underlying process to present
    # an input prompt, so that another action
    # can be submitted, or user input can be
    # collected.
    def wait_for_prompt expected_prompt=nil
      expected_prompt = expected_prompt || prompt
      line = ''

      while process_runner.alive? do
        return false if process_runner.r.eof?
        char = process_runner.readpartial 1
        line << char
        if char == "\n"
          line = ''
        end
        Sprout::Log.printf char
        Sprout::Log.flush
        return true unless line.match(expected_prompt).nil?
      end
    end

    protected

    def process_launched?
      @process_launched
    end

    ##
    # This is the override of the underlying
    # Sprout::Executable template method so that we
    # create a 'task' instead of a 'file' task.
    #
    # @return [Rake::Task]
    def create_outer_task *args
      task *args do
        execute
      end
    end

    ##
    # This is the override of the underlying
    # Sprout::Executable template method so that we
    # are NOT added to the CLEAN collection.
    # (Work performed in the Executable)
    #
    # @return [String]
    def update_rake_task_name_from_args *args
      self.rake_task_name = parse_rake_task_arg args.last
    end

    ##
    # This is the override of the underlying
    # Sprout::Executable template method so that we
    # create the process in a thread 
    # in order to read and write to it.
    #
    # @return [Thread]
    def system_execute binary, params
      Sprout.current_system.execute_thread binary, params
    end

    private

    ##
    # Execute the collection of provided actions.
    def execute_actions
      action_stack.each do |action|
        break unless execute_action action
      end
    end

    ##
    # Execute a single action.
    def execute_action action, silence=false
      action = action.strip
      Sprout::Log.puts(action) unless silence
      process_runner.puts action
      wait_for_prompt
    end

    ##
    # Expose the running process to manual
    # input on the terminal, and write stdout
    # back to the user.
    def handle_user_session
      while !process_runner.r.eof?
        input = $stdin.gets.chomp!
        execute_action input, true
        wait_for_prompt
      end
    end

  end
end

