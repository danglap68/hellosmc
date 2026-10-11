module Workbook
  # Serializes every write to one spreadsheet (transactions and remitter
  # transfers alike) with a session-level Postgres advisory try-lock. A busy
  # lock raises HelloSmcWriter::LockBusy and the job retries, so Sidekiq threads
  # never block on it.
  module SheetLock
    module_function

    def with(spreadsheet_id)
      key = "hello-smc-workbook:#{spreadsheet_id}"
      connection = ActiveRecord::Base.connection
      acquired = connection.select_value(
        ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_try_advisory_lock(hashtext(?))", key ])
      )
      raise HelloSmcWriter::LockBusy, "workbook write in progress for #{spreadsheet_id}" unless acquired == true || acquired == "t"

      begin
        yield
      ensure
        begin
          connection.execute(ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_advisory_unlock(hashtext(?))", key ]))
        rescue StandardError => error
          Rails.logger.warn("workbook advisory unlock failed: #{error.message}")
        end
      end
    end
  end
end
