require 'active_record/connection_adapters/postgresql_adapter'
#This module monkey patches the postgres adapter from rails v3.0.3, since table_exists? checks all existing tables, irreguardless of the
#schema search path.  See:
# https://rails.lighthouseapp.com/projects/8994/tickets/6457-disregard-for-schema-search-path-in-postgresql_adapterrb#ticket-6457-1
module PostgresAdapterPatch
  ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.class_eval do
    alias_method :schema_unfriendly_table_exists?, :table_exists?
    def table_exists?(name)
        name          = name.to_s
        schema, table = name.split('.', 2)
       unless table # A table was provided without a schema
          table  = schema
          schema = nil
        end

        if name =~ /^"/ # Handle quoted table names
          table  = name
          schema = nil
        end

        # `AND schemaname = ANY (current_schemas(false))` added so only tables in the current search path are included
        query(<<-SQL).first[0].to_i > 0
            SELECT COUNT(*)
            FROM pg_tables
            WHERE tablename = '#{table.gsub(/(^"|"$)/,'')}'
            #{schema ? "AND schemaname = '#{schema}'" : ''}
            AND schemaname = ANY (current_schemas(false))
        SQL
      end
  end
end

# this monkey patch is needed because the location of the migrations `db/migrate` is effectively hard coded into the rails source
# Rails team has no intent of changing this: https://rails.lighthouseapp.com/projects/8994/tickets/343-assume_migrated_upto_version-doesn-t-work-with-non-standard-migrations-path
# If I understand correctly, this alias won't be available outside of code that doesn't require the migration
module SchemaStatementsPatch
  ActiveRecord::Schema.class_eval do
      class << self
        alias_method :schema_unfriendly_migrations_path, :migrations_path
        # File activerecord/lib/active_record/schema.rb, line 35
        def migrations_path
          'vendor/plugins/pg_active_schema/db/migrate'
        end
      end
  end
end

class PgActiveSchema
  include PostgresAdapterPatch
  include SchemaStatementsPatch
  class NoSchema < StandardError; end
  class SQLInjectableSchemaName < StandardError; end
  class SchemaNotCreatedWithTenant < StandardError; end
  class CreateSchemaError < StandardError
    attr_reader :search_path
    def initialize(message = nil, search_path = nil)
      @message = message
      @search_path = search_path
    end
  end
  class DropSchemaError < StandardError
    attr_reader :search_path
    def initialize(message = nil, search_path = nil)
      @message = message
      @search_path = search_path
    end
  end

  def self.assert_safe_schema_name name
    raise PgActiveSchema::SQLInjectableSchemaName.new("Schema name #{name} is subject to inject attack") if name.match(/(^[A-Za-z]+[A-Za-z0-9]*$|\$user)/).nil?
  end

  #name will be sanitized by this method
  def self.create_schema name
    assert_safe_schema_name name
    begin
      ActiveRecord::Base.connection.execute("CREATE SCHEMA #{name}")
    rescue Exception => e
      #drop_schema name if list_schemata.include?(name) #dont' want a 1/2 finished schema hanging around
      raise PgActiveSchema::CreateSchemaError.new(e.message, search_path)
    end
  end

  def self.drop_schema name
    begin
      ActiveRecord::Base.connection.execute("DROP SCHEMA #{name} CASCADE;")
    rescue Exception => e
      raise PgActiveSchema::DropSchemaError.new(e.message, search_path)
    end
  end

  def self.list_schemata
    ActiveRecord::Base.connection.query('SELECT nspname AS "Schema Name" FROM pg_namespace  WHERE nspname !~ \'^pg_.*\';').flatten
  end

  def self.search_path
    ActiveRecord::Base.connection.query('SHOW search_path;')[0].first
  end

  def self.current_schema
    ActiveRecord::Base.connection.query('select current_schema();')[0].first
  end
  
  #reset_models an array of contants of classes that will need to be reloaded, if you have the same table name with different attribtes in different schemas
  #def self.search_path= name, include_public=false  #origonal method sig...doesn't work the way you think it does
  def self.search_path= name
    assert_safe_schema_name name
    #path_parts = [name, ("public" if include_public)].compact
    path_parts = name
    #Rails.logger.info "--Setting search path to: " + path_parts.join(',')
    Rails.logger.info "--Setting search path to: " + path_parts
    begin
      #this will throw `ActiveRecord::StatementInvalid` if the search path doesn't exist
      #http://api.rubyonrails.org/classes/ActiveRecord/ConnectionAdapters/PostgreSQLAdapter.html#method-i-schema_search_path-3D
      #says not to call this directly, but internally it's doing the same thing I was going to do anyway
      @prior_search_path = self.search_path
      #ActiveRecord::Base.connection.schema_search_path = "#{path_parts.join(',')}"
      ActiveRecord::Base.connection.schema_search_path = "#{path_parts}"
    rescue Exception => e
      restore_search_path
      raise PgActiveSchema::NoSchema.new(e.message)
    end
  end

  def self.restore_search_path
    self.search_path= @prior_search_path
  end

  def self.default_search_path 
    self.search_path= '"$user",public'
  end

  def self.set_search_path_and_reset name, reset_models = []
    assert_safe_schema_name name
    path_parts = name
    #Rails.logger.info "--Setting search path to: " + path_parts.join(',')
    Rails.logger.info "--Setting search path to: " + path_parts
    begin
      #this will throw `ActiveRecord::StatementInvalid` if the search path doesn't exist
      #http://api.rubyonrails.org/classes/ActiveRecord/ConnectionAdapters/PostgreSQLAdapter.html#method-i-schema_search_path-3D
      #says not to call this directly, but internally it's doing the same thing I was going to do anyway
      @prior_search_path = self.search_path
      #ActiveRecord::Base.connection.schema_search_path = "#{path_parts.join(',')}"
      ActiveRecord::Base.connection.schema_search_path = "#{path_parts}"
      reset_models.each{|model| model.reset_column_information}
    rescue Exception => e
      restore_search_path
      reset_models.each{|model| model.reset_column_information}
      raise PgActiveSchema::NoSchema.new(e.message)
    end
  end
  def self.restore_search_path_and_reset reset_models=[]  
    self.set_search_path_and_reset @prior_search_path, reset_models
  end

  def self.default_search_path_and_reset reset_models=[]  
    self.set_search_path_and_reset '"$user",public', reset_models
  end

  #run this to create a new tenant, and initialize with the 'authorative' schema in pg_active_schema/db/schema.rb
  #this plugin schema will have to be managed by hand for now
  #the version listed there should represent our desired latest migration.  The `schema_migrations table` in each postgres schema
  #will tell us whether or not those migrations where actually applied, incase there was some kind of failure.
  #initializes from db seeds and also takes a block if you have special seeding to do
  #pass a proc as a block by &my_proc_name
  #pass an array of contants of classes that will need to be reloaded, if you have the same table name with different attribtes in different schemas
  def self.create_tenant name, reset_models = []
    create_schema name
    #self.search_path = name
    self.set_search_path_and_reset name, reset_models

    raise PgActiveSchema::SchemaNotCreatedWithTenant.new("search path(#{self.search_path}) does not equal tenant name (#{name})") unless self.search_path == name #double check to make sure the search path was set
    begin #need to catch any errors that happen here or else the database will be left on the user's schema
      #right from db:schema:load rake task
      file = "#{Rails.root}/vendor/plugins/pg_active_schema/db/schema.rb"
      if File.exists?(file)
        load(file)
      else
        abort %{#{file} vendor/plugins/pg_active_schema/db/schema.rb doesn't exist."}
      end
      file = "#{Rails.root}/vendor/plugins/pg_active_schema/db/seeds.rb"
      if File.exists?(file)
        load(file)
      end

      if block_given?
        yield
      end
    rescue Exception => e
      restore_search_path_and_reset reset_models
      raise PgActiveSchema::SchemaNotCreatedWithTenant.new(e.message)
    end
  #else
  #  restore_search_path
  #  raise PgActiveSchema::SchemaNotCreatedWithTenant
  #end

    restore_search_path_and_reset reset_models
  end

  #use this to get rid of tenants (i.e. the tenants schema)
  def self.drop_tenant name
    drop_schema name
  end

end
