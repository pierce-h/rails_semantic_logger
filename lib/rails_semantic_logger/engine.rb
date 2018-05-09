module RailsSemanticLogger
  class Engine < ::Rails::Engine
    # Make the SemanticLogger config available in the Rails application config
    #
    # Example: Add the MongoDB logging appender in the Rails environment
    #          initializer in file config/environments/development.rb
    #
    #   Rails::Application.configure do
    #     # Add the MongoDB logger appender only once Rails is initialized
    #     config.after_initialize do
    #       appender = SemanticLogger::Appender::Mongo.new(
    #         uri: 'mongodb://127.0.0.1:27017/test'
    #       )
    #       config.semantic_logger.add_appender(appender: appender)
    #     end
    #   end
    config.semantic_logger = ::SemanticLogger

    config.rails_semantic_logger                   = ActiveSupport::OrderedOptions.new

    # Convert Action Controller and Active Record text messages to semantic data
    #   Rails -- Started -- { :ip => "127.0.0.1", :method => "GET", :path => "/dashboards/inquiry_recent_activity" }
    #   UserController -- Completed #index -- { :action => "index", :db_runtime => 54.64, :format => "HTML", :method => "GET", :mongo_runtime => 0.0, :path => "/users", :status => 200, :status_message => "OK", :view_runtime => 709.88 }
    config.rails_semantic_logger.semantic          = true

    # Change Rack started message to debug so that it does not appear in production
    config.rails_semantic_logger.started           = false

    # Change Processing message to debug so that it does not appear in production
    config.rails_semantic_logger.processing        = false

    # Change Action View render log messages to debug so that they do not appear in production
    #   ActionView::Base --   Rendered data/search/_user.html.haml (46.7ms)
    config.rails_semantic_logger.rendered          = false

    # Override the Awesome Print options for logging Hash data as text:
    #
    #  Any valid AwesomePrint option for rendering data.
    #  The defaults can changed be creating a `~/.aprc` file.
    #  See: https://github.com/michaeldv/awesome_print
    #
    #  Note: The option :multiline is set to false if not supplied.
    #  Note: Has no effect if Awesome Print is not installed.
    config.rails_semantic_logger.ap_options        = {multiline: false}

    # Whether to automatically add an environment specific log file appender.
    # For Example: 'log/development.log'
    #
    # Note:
    #   When Semantic Logger fails to log to an appender it logs the error to an
    #   internal logger, which by default writes to STDERR.
    #   Example, change the default internal logger to log to stdout:
    #     SemanticLogger::Processor.logger = SemanticLogger::Appender::File.new(io: STDOUT, level: :warn)
    config.rails_semantic_logger.add_file_appender = true

    # Silence asset logging
    config.rails_semantic_logger.quiet_assets      = false

    # Override the output format for the primary Rails log file.
    #
    # Valid options:
    # * :default
    #     Plain text output with no color.
    # * :color
    #     Plain text output with color.
    # * :json
    #     JSON output format.
    # * class
    #
    # * Proc
    #     A block that will be called to format the output.
    #     It is supplied with the `log` entry and should return the formatted data.
    #
    # Note:
    # * `:default` is automatically changed to `:color` if `config.colorize_logging` is `true`.
    #
    # JSON Example, in `application.rb`:
    #
    #   config.rails_semantic_logger.format = :json
    #
    # Custom Example, create `app/lib/my_formatter.rb`:
    #
    #   # My Custom colorized formatter
    #   class MyFormatter < SemanticLogger::Formatters::Color
    #     # Return the complete log level name in uppercase
    #     def level
    #       "#{color}log.level.upcase#{color_map.clear}"
    #     end
    #   end
    #
    #   # In application.rb:
    #   config.rails_semantic_logger.format = MyFormatter.new
    config.rails_semantic_logger.format            = :default

    # DEPRECATED
    # Instead, supply a Hash to config.log_tags
    config.rails_semantic_logger.named_tags        = nil

    # Add a filter to the file logger [Regexp|Proc]
    #   RegExp: Only include log messages where the class name matches the supplied
    #           regular expression. All other messages will be ignored.
    #   Proc: Only include log messages where the supplied Proc returns true.
    #         The Proc must return true or false.
    config.rails_semantic_logger.filter            = nil

    # Initialize SemanticLogger. In a Rails environment it will automatically
    # insert itself above the configured rails logger to add support for its
    # additional features

    # Replace Rails logger initializer
    Rails::Application::Bootstrap.initializers.delete_if { |i| i.name == :initialize_logger }

    initializer :initialize_logger, group: :all do
      config                       = Rails.application.config

      # Set the default log level based on the Rails config
      SemanticLogger.default_level = config.log_level

      # Existing loggers are ignored because servers like trinidad supply their
      # own file loggers which would result in duplicate logging to the same log file
      Rails.logger                 = config.logger = begin
        if config.rails_semantic_logger.add_file_appender
          path = config.paths['log'].first
          FileUtils.mkdir_p(File.dirname(path)) unless File.exist?(File.dirname(path))

          # Add the log file to the list of appenders
          # Use the colorized formatter if Rails colorized logs are enabled
          ap_options = config.rails_semantic_logger.ap_options
          formatter  = config.rails_semantic_logger.format
          formatter  = {color: {ap: ap_options}} if (formatter == :default) && (config.colorize_logging != false)

          # Set internal logger to log to file only, in case another appender experiences errors during writes
          appender                         = SemanticLogger::Appender::File.new(file_name: path, level: config.log_level, formatter: formatter)
          appender.name                    = 'SemanticLogger'
          SemanticLogger::Processor.logger = appender

          # Check for previous file or stdout loggers
          if SemanticLogger::VERSION.to_f >= 4.2
            SemanticLogger.appenders.each { |appender| appender.formatter = formatter if appender.is_a?(SemanticLogger::Appender::File) }
          elsif config.colorize_logging == false
            SemanticLogger.appenders.each { |appender| appender.formatter = SemanticLogger::Formatters::Default.new if appender.is_a?(SemanticLogger::Appender::File) }
          end
          SemanticLogger.add_appender(file_name: path, formatter: formatter, filter: config.rails_semantic_logger.filter)
        end

        SemanticLogger[Rails]
      rescue StandardError => exc
        # If not able to log to file, log to standard error with warning level only
        SemanticLogger.default_level = :warn

        SemanticLogger::Processor.logger = SemanticLogger::Appender::File.new(io: STDERR)
        SemanticLogger.add_appender(io: STDERR)

        logger = SemanticLogger[Rails]
        logger.warn(
          "Rails Error: Unable to access log file. Please ensure that #{path} exists and is chmod 0666. " +
            "The log level has been raised to WARN and the output directed to STDERR until the problem is fixed.",
          exc
        )
        logger
      end

      # Replace Rails loggers
      [:active_record, :action_controller, :action_mailer, :action_view].each do |name|
        ActiveSupport.on_load(name) { include SemanticLogger::Loggable }
      end
      ActiveSupport.on_load(:action_cable) { self.logger = SemanticLogger['ActionCable'] }
    end

    # Support fork frameworks
    config.after_initialize do
      # Silence asset logging by applying a filter to the Rails logger itself, not any of the appenders.
      if config.rails_semantic_logger.quiet_assets && config.assets.prefix #&& defined?(Rails::Rack::Logger)
        assets_regex = %r(\A/{0,2}#{config.assets.prefix})
        if Rails.version.to_i >= 5
          Rails::Rack::Logger.logger.filter = -> log { log.payload[:path] !~ assets_regex if log.payload }
        else
          # Also strips the empty log lines
          Rails::Rack::Logger.logger.filter = -> log { log.payload.nil? ? (log.message != '') : (log.payload[:path] !~ assets_regex) }
        end
      end

      # Passenger provides the :starting_worker_process event for executing
      # code after it has forked, so we use that and reconnect immediately.
      if defined?(PhusionPassenger)
        PhusionPassenger.on_event(:starting_worker_process) do |forked|
          ::SemanticLogger.reopen if forked
        end
      end

      # Re-open appenders after Resque has forked a worker
      if defined?(Resque)
        Resque.after_fork { |job| ::SemanticLogger.reopen }
      end

      # Re-open appenders after Spring has forked a process
      if defined?(Spring)
        Spring.after_fork { |job| ::SemanticLogger.reopen }
      end
    end

    # Before any initializers run, but after the gems have been loaded
    config.before_initialize do
      # # Replace the Mongo Loggers
      # Mongoid.logger          = SemanticLogger[Mongoid] if defined?(Mongoid)
      # Moped.logger            = SemanticLogger[Moped] if defined?(Moped)
      # Mongo::Logger.logger    = SemanticLogger[Mongo] if defined?(Mongo::Logger)

      # # Replace the Resque Logger
      # Resque.logger           = SemanticLogger[Resque] if defined?(Resque) && Resque.respond_to?(:logger)

      # # Replace the Sidekiq logger
      # Sidekiq::Logging.logger = SemanticLogger[Sidekiq] if defined?(Sidekiq)

      # # Replace the Sidetiq logger
      # Sidetiq.logger          = SemanticLogger[Sidetiq] if defined?(Sidetiq)

      # # Replace the Bugsnag logger
      # Bugsnag.configure { |config| config.logger = SemanticLogger[Bugsnag] } if defined?(Bugsnag)

      # Set the logger for concurrent-ruby
      Concurrent.global_logger = SemanticLogger[Concurrent] if defined?(Concurrent)

      # Rails Patches
      require('rails_semantic_logger/extensions/action_cable/tagged_logger_proxy') if defined?(ActionCable)
      require('rails_semantic_logger/extensions/action_controller/live') if defined?(ActionController::Live)
      require('rails_semantic_logger/extensions/action_dispatch/debug_exceptions') if defined?(ActionDispatch::DebugExceptions)
      require('rails_semantic_logger/extensions/action_view/streaming_template_renderer') if defined?(ActionView::StreamingTemplateRenderer::Body)
      require('rails_semantic_logger/extensions/active_job/logging') if defined?(ActiveJob)
      require('rails_semantic_logger/extensions/active_model_serializers/logging') if defined?(ActiveModelSerializers)

      if config.rails_semantic_logger.semantic
        require('rails_semantic_logger/extensions/rails/rack/logger') if defined?(Rails::Rack::Logger)
        require('rails_semantic_logger/extensions/action_controller/log_subscriber') if defined?(ActionController)
        require('rails_semantic_logger/extensions/active_record/log_subscriber') if defined?(ActiveRecord::LogSubscriber)
      end

      unless config.rails_semantic_logger.started
        require('rails_semantic_logger/extensions/rails/rack/logger_info_as_debug') if defined?(Rails::Rack::Logger)
      end

      unless config.rails_semantic_logger.rendered
        require('rails_semantic_logger/extensions/action_view/log_subscriber') if defined?(ActionView::LogSubscriber)
      end

      if config.rails_semantic_logger.processing
        require('rails_semantic_logger/extensions/action_controller/log_subscriber_processing') if defined?(ActionView::LogSubscriber)
      end

      # Backward compatibility
      if config.rails_semantic_logger.named_tags
        config.log_tags = config.rails_semantic_logger.named_tags
      end
    end

    # After any initializers run, but after the gems have been loaded
    config.after_initialize do
      # Replace the Bugsnag logger
      Bugsnag.configure { |config| config.logger = SemanticLogger[Bugsnag] } if defined?(Bugsnag)
    end

  end
end
