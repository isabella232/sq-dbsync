require 'sq/dbsync/config'
require 'sq/dbsync/batch_load_action'
require 'sq/dbsync/incremental_load_action'
require 'sq/dbsync/refresh_recent_load_action'
require 'sq/dbsync/pipeline'
require 'sq/dbsync/table_registry'
require 'sq/dbsync/database/connection'
require 'sq/dbsync/error_handler'

# The manager orchestrates the high level functions of the sync, such as
# keeping the database up-to-date and batch loading.
#
# This is the main entry point for the application.
class Sq::Dbsync::Manager
  class UnknownTablesError < RuntimeError; end

  include Sq::Dbsync

  EPOCH = Date.new(2000, 1, 1).to_time
  MAX_RETRIES = 10

  def initialize(config, plans)
    @config        = Sq::Dbsync::Config.make(config)
    @plans         = plans
    @error_handler = ErrorHandler.new(config)
  end

  def batch(tables = :all)
    error_handler.wrap do
      batch_nonactive(tables)
      refresh_recent(tables)
    end
  end

  def increment
    error_handler.wrap do
      incremental
    end
  end

  def batch_nonactive(tables = :all)
    registry.ensure_storage_exists

    measure(:batch_total) do
      raise_all_if_pipeline_failure(
        run_load(BatchLoadAction, Pipeline::ThreadedContext, tables)
      )
    end
  end

  def refresh_recent(tables = :all)
    registry.ensure_storage_exists

    measure(:refresh_recent_total) do
      raise_all_if_pipeline_failure(
        run_load(RefreshRecentLoadAction, Pipeline::ThreadedContext, tables)
      )
    end
  end

  def incremental
    @running = true
    counter = 0

    loop_with_retry_on(->{ @running }, transient_exceptions) do
      incremental_once

      if (counter += 1) % 100 == 1
        # No need to do this every cycle, 100 is chosen to be as good as any
        # other number. It should run on the very first cycle however so that
        # the specs will cover it.
        purge_registry
      end
    end
  end

  def incremental_once
    # In theory, this ensures that any changes to the source IP (such as from a
    # virtual IP flip) are picked up.
    sources.each do |_, db|
      db.disconnect
    end

    raise_if_pipeline_failure(
      # ThreadedContext would be ideal here, but it leaks memory in JRuby. Not
      # sure why yet, but mass creation of threads seems like an obvious
      # candidate for brokenness.
      #
      # TODO: Above comment probably isn't true with 1.7 and ThreadedContext
      # fixes.
      run_load(incremental_action, Pipeline::SimpleContext)
    )
  end

  def stop!
    @running = false
  end

  def target
    opts = config[:target]
    @target ||= Sq::Dbsync::Database::Connection.create(opts, :target)
  end

  def tables_to_load
    plans_with_sources.map do |plan, source|
      plan.tables(source).map do |x|
        x.update(source_db: source)
      end
    end.reduce([], :+).uniq {|x| x[:table_name] }
  end

  def plans_with_sources
    @plans_with_sources ||= plans.map do |plan, source_name|
      [plan, sources.fetch(source_name)]
    end
  end

  def sources
    @sources ||= Hash[config[:sources].map do |name, opts|
      [name, Sq::Dbsync::Database::Connection.create(opts, :source)]
    end]
  end

  attr_accessor :config, :plans, :error_handler

  private

  def run_load(action, context, tables = :all)
    if tables != :all
      table_names = tables_to_load.map { |p| p[:table_name] }
      unknown_tables = Set.new tables - table_names
      if unknown_tables.size > 0
        raise(UnknownTablesError, "Unknown tables: #{unknown_tables.to_a}")
      end
    end

    items = tables_to_load.map do |tplan|
      if tables != :all
        next unless tables.include?(tplan[:table_name])

        # Force loading of specified tables, otherwise it would be impossible
        # to batch load tables that were not regularly loaded.
        tplan[:batch_load] = true

        # Force refresh of tables, this is expected behaviour if you are
        # calling the refresh-recent script with an explicit table list.
        tplan[:refresh_recent] = true
      end

      if tplan[:refresh_recent].is_a?(Symbol)
        tplan[:aux_timestamp_column] = tplan[:refresh_recent]
      end

      action.new(db, tplan, registry, logger, config[:clock])
    end.compact
    Pipeline.new(items, *LoadAction.stages).run(context)
  end

  # This is necessary so that old tables that are no longer being synced do not
  # break our lag calculations.
  def purge_registry
    registry.purge_except(expected_table_names)
  end

  def expected_table_names
    tables_to_load.map {|x| x[:table_name] } + config.fetch(:extra_tables, [])
  end

  def loop_with_retry_on(guard, transient_exceptions, &block)
    consecutive_fails = 0

    while guard.call
      begin
        block.call
        consecutive_fails = 0
      rescue *transient_exceptions
        consecutive_fails += 1
        raise if consecutive_fails >= MAX_RETRIES
      end
    end
  end

  def raise_if_pipeline_failure(results)
    results.each do |result|
      if result.is_a?(Pipeline::Failure)
        raise result.wrapped_exception
      end
    end
  end

  def raise_all_if_pipeline_failure(results)
    failed = false
    results.each do |result|
      if result.is_a?(Pipeline::Failure)
        error_handler.notify_error(result.task.tag, result.wrapped_exception)
        failed = true
      end
    end

    if failed
      raise Database::ExtractError,
        "One or more loads failed, see other exceptions for details."
    end
  end

  def measure(label, &block)
    logger.measure(label) do
      block.call
    end
  end

  def registry
    TableRegistry.new(target)
  end

  def logger
    config[:logger]
  end

  def db
    @db ||= Database::Connection.create(config[:target], :target)
  end

  def transient_exceptions
    [
      Database::ExtractError,
      Database::TransientError
    ]
  end

  def incremental_action
    config.fetch(:incremental_action, IncrementalLoadAction)
  end

end
