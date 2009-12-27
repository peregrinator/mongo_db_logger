require 'erb'
require 'mongo'

class MongoLogger < ActiveSupport::BufferedLogger
  default_capsize = (Rails.env == 'production') ? 250.megabytes : 100.megabytes
  
  db_configuration = {
    'host'    => 'localhost',
    'port'    => 27017,
    'capsize' => default_capsize}.merge( YAML::load(ERB.new(IO.read(File.join(Rails.root, 'config/database.yml'))).result)[Rails.env]['mongo'] )

  begin
    @mongo_collection_name      = "#{Rails.env}_log"
    @mongo_connection ||= Mongo::Connection.new(db_configuration['host'], db_configuration['port'], :auto_reconnect => true).db(db_configuration['database'])

    # setup the capped collection if it doesn't already exist
    unless @mongo_connection.collection_names.include?(@mongo_collection_name)
      @mongo_connection.create_collection(@mongo_collection_name, {:capped => true, :size => db_configuration['capsize']})
    end
  rescue => e
    puts "=> !! A connection to mongo could not be established - the logger will function like a normal ActiveSupport::BufferedLogger !!"
  end

  class << self
    attr_reader :mongo_collection_name, :mongo_connection
  end
  
  RESERVED_MONGO_LOGGER_KEYS = [:messages, :request_time, :ip, :runtime]
  
  def initialize(level=DEBUG)
    super(File.join(Rails.root, "log/#{Rails.env}.log"), level)
  end

  def level_to_sym(level)
    case level
      when 0 then :debug
      when 1 then :info
      when 2 then :warn
      when 3 then :error
      when 4 then :fatal
      when 5 then :unknown
    end
  end
  
  def mongoize(options={})   
    @mongo_record = options.merge({
      :messages => Hash.new { |hash, key| hash[key] = Array.new },
      :request_time => Time.now.utc
    })
    runtime = Benchmark.measure do
      yield
    end
    @mongo_record[:runtime]     = (runtime.real * 1000).ceil
    self.class.mongo_connection[self.class.mongo_collection_name].insert(@mongo_record) rescue nil
  end

  def add_metadata(options={})
    options.keys.each do |key|
      raise ArgumentError, ":#{key} is a reserved key for the mongo logger. Please choose a different key" if RESERVED_MONGO_LOGGER_KEYS.include?(key.to_sym)
    end

    @mongo_record.recursive_merge!(options)
  end

  def add(severity, message = nil, progname = nil, &block)
    unless @level > severity
      if ActiveRecord::Base.colorize_logging
        # remove colorization done by rails and just save the actual message
        @mongo_record[:messages][level_to_sym(severity)] << message.gsub(/(\e(\[([\d;]*[mz]?))?)?/, '').strip rescue nil
      else
        @mongo_record[:messages][level_to_sym(severity)] << message
      end
    end

    super
  end
end # class MongoLogger

class Hash
  # Taken from Ruby facets - http://facets.rubyforge.org/apidoc/api/core/classes/Hash.html
  def recursive_merge(other)
    hash = self.dup
    other.each do |key, value|
      myval = self[key]
      if value.is_a?(Hash) && myval.is_a?(Hash)
        hash[key] = myval.recursive_merge(value)
      else
        hash[key] = value
      end
    end
    hash
  end
  
  def recursive_merge!(other)
    other.each do |key, value|
      myval = self[key]
      if value.is_a?(Hash) && myval.is_a?(Hash)
        myval.recursive_merge!(value)
      else
        self[key] = value
      end
    end
    self
  end
end