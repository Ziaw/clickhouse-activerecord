require 'active_record/connection_adapters/abstract_adapter'
require 'active_record/connection_adapters/clickhouse/oid/date'
require 'active_record/connection_adapters/clickhouse/oid/date_time'
require 'active_record/connection_adapters/clickhouse/oid/big_integer'
require 'active_record/connection_adapters/clickhouse/schema_definitions'
require 'active_record/connection_adapters/clickhouse/schema_creation'
require 'active_record/connection_adapters/clickhouse/schema_statements'
require 'net/http'

module ActiveRecord
  class Base
    class << self
      # Establishes a connection to the database that's used by all Active Record objects
      def clickhouse_connection(config)
        config = config.symbolize_keys.reverse_merge(port: 8123)

        if config.key?(:database)
          database = config[:database]
        else
          raise ArgumentError, 'No database specified. Missing argument: database.'
        end
        ConnectionAdapters::ClickhouseAdapter.new(
          nil,
          logger,
          config,
          { user: config[:username], password: config[:password], database: database }.compact
        )
      end
    end
  end

  module TypeCaster
    class Map
      def is_view
        types.is_view
      end
    end
  end

  module ModelSchema
     module ClassMethods
      def is_view
        @is_view || false
      end
       # @param [Boolean] value
      def is_view=(value)
        @is_view = value
      end

      def arel_table # :nodoc:
        @arel_table ||= ClickhouseActiverecord::Arel::Table.new(table_name, type_caster: type_caster)
      end

    end
   end

  module ConnectionAdapters
    class ClickhouseColumn < Column

    end

    class ClickhouseAdapter < AbstractAdapter
      ADAPTER_NAME = 'Clickhouse'.freeze

      NATIVE_DATABASE_TYPES = {
        string: { name: 'String' },
        integer: { name: 'UInt32' },
        bigint: { name: 'UInt64' },
        big_integer: { name: 'UInt64' },
        float: { name: 'Float32' },
        decimal: { name: 'Decimal' },
        datetime: { name: 'DateTime' },
        date: { name: 'Date' },
        boolean: { name: 'UInt8' },
        primary_key: { name: 'UInt64' }
      }.freeze

      include Clickhouse::SchemaStatements

      # Initializes and connects a Clickhouse adapter.
      def initialize(connection, logger, connection_parameters, config, debug = false)
        super(connection, logger)
        @connection_parameters = connection_parameters
        @config = config
        @debug = debug

        @prepared_statements = false
        @visitor = ClickhouseActiverecord::Arel::Visitors::ToSql.new self

        connect
      end

      def arel_visitor # :nodoc:
        ClickhouseActiverecord::Arel::Visitors::ToSql.new(self)
      end

      def native_database_types #:nodoc:
        NATIVE_DATABASE_TYPES
      end

      def valid_type?(type)
        !native_database_types[type].nil?
      end

      def extract_limit(sql_type) # :nodoc:
        case sql_type
          when /(Nullable)?\(?String\)?/
            super('String')
          when /(Nullable)?\(?U?Int8\)?/
            super('int2')
          when /(Nullable)?\(?U?Int(16|32)\)?/
            super('int4')
          when /(Nullable)?\(?U?Int(64)\)?/
            8
          else
            super
        end
      end

      def initialize_type_map(m) # :nodoc:
        super
        register_class_with_limit m, %r(String), Type::String
        register_class_with_limit m, 'Date',  Clickhouse::OID::Date
        register_class_with_limit m, 'DateTime',  Clickhouse::OID::DateTime
        m.register_type 'UInt64', Clickhouse::OID::BigInteger.new
        register_class_with_limit m, %r(Uint8), Type::UnsignedInteger
        m.alias_type 'UInt16', 'UInt8'
        m.alias_type 'UInt32', 'UInt8'
        register_class_with_limit m, %r(UInt64), Type::UnsignedInteger
        register_class_with_limit m, %r(Int8), Type::Integer
        m.alias_type 'Int16', 'Int8'
        m.alias_type 'Int32', 'Int8'
        register_class_with_limit m, %r(Int64), Type::Integer
      end

      # Queries the database and returns the results in an Array-like object
      def query(sql, _name = nil)
        res = @connection.post("/?#{@config.merge(query: '').to_param}", "#{sql} FORMAT JSONCompact")
        raise ActiveRecord::ActiveRecordError, "Response code: #{res.code}:\n#{res.body}" unless res.code.to_i == 200
        JSON.parse res.body
      end

      # Quoting time without microseconds
      def quoted_date(value)
        if value.acts_like?(:time)
          zone_conversion_method = ActiveRecord::Base.default_timezone == :utc ? :getutc : :getlocal

          if value.respond_to?(zone_conversion_method)
            value = value.send(zone_conversion_method)
          end
        end

        value.to_s(:db)
      end

      def column_name_for_operation(operation, node) # :nodoc:
        OPERATION_ALIASES.fetch(operation) { operation.downcase }
      end

      OPERATION_ALIASES = { # :nodoc:
        "maximum" => "max",
        "minimum" => "min",
        "average" => "avg",
      }.freeze

      # Executes insert +sql+ statement in the context of this connection using
      # +binds+ as the bind substitutes. +name+ is logged along with
      # the executed +sql+ statement.

      # SCHEMA STATEMENTS ========================================

      def primary_key(table_name) #:nodoc:
        pk = table_structure(table_name).first
        return 'id' if pk.present? && pk[0] == 'id'
        false
      end

      def create_schema_dumper(options) # :nodoc:
        ClickhouseActiverecord::SchemaDumper.create(self, options)
      end

      # Create a new ClickHouse database.
      def create_database(name)
        sql = "CREATE DATABASE #{quote_table_name(name)}"
        log_with_debug(sql, adapter_name) do
          res = @connection.post("/?#{@config.except(:database).to_param}", "CREATE DATABASE #{quote_table_name(name)}")
          process_response(res)
        end
      end

      # Drops a ClickHouse database.
      def drop_database(name) #:nodoc:
        sql = "DROP DATABASE IF EXISTS #{quote_table_name(name)}"
        log_with_debug(sql, adapter_name) do
          res = @connection.post("/?#{@config.except(:database).to_param}", sql)
          process_response(res)
        end
      end

      def drop_table(table_name, options = {}) # :nodoc:
        do_execute "DROP TABLE#{' IF EXISTS' if options[:if_exists]} #{quote_table_name(table_name)}"
      end

      def variable_to_s(var)
        return 'NULL' if var.value.nil?

        case var.type
        when ActiveModel::Type::ImmutableString, ActiveModel::Type::DateTime, ActiveModel::Type::Date
          quote var.value_for_database
        when ActiveModel::Type::Boolean
          var.value ? '1' : '0'
        else
          var.value_for_database
        end
      end

      def apply_binds(sql, binds)
        # Very dirty and naive binds implementation
        # TODO at least skip '?' in string literals
        sql.gsub(/\?/) { variable_to_s(binds.shift) }
      end



      protected

      def last_inserted_id(result)
        result
      end

      private

      def connect
        @connection = Net::HTTP.start(
          @connection_parameters[:host],
          @connection_parameters[:port],
          nil,
          nil,
          nil,
          nil,
          @connection_parameters
        )
      end
    end
  end
end
