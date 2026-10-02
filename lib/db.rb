require "trilogy"

# Minimal MySQL access layer for the backend service.
#
# Example-grade, not production: one connection per thread (Puma runs 5), lazy
# schema bootstrap on first use, and no real pooling or retry/backoff policy.
# Every query goes through Trilogy, which the OpenTelemetry auto-instrumentation
# patches, so each statement becomes a db.client span inside the request trace.
module DB
  CONFIG = {
    host: ENV.fetch("MYSQL_HOST", "127.0.0.1"),
    port: ENV.fetch("MYSQL_PORT", "3306").to_i,
    username: ENV.fetch("MYSQL_USER", "example"),
    password: ENV.fetch("MYSQL_PASSWORD", "example"),
    database: ENV.fetch("MYSQL_DATABASE", "example"),
    connect_timeout: 5,
    read_timeout: 10,
    write_timeout: 10
  }.freeze

  SEED = [
    ["widget-0", "Basic Widget",     499,  14, "euw1-a"],
    ["widget-1", "Standard Widget",  1_250, 9, "euw1-b"],
    ["widget-2", "Premium Widget",   3_400, 4, "euw1-a"],
    ["widget-3", "Bulk Widget",      890,  27, "euw1-c"],
    ["widget-4", "Limited Widget",   7_999, 1, "euw1-b"]
  ].freeze

  BOOTSTRAP_LOCK = Mutex.new

  class << self
    # Connections are per-thread: a Trilogy connection is not safe to share
    # across Puma's worker threads.
    #
    # Deliberately no ping-before-use. Trilogy#ping is itself instrumented, so
    # checking liveness on every call added four db.client "ping" spans per
    # request — noise with no diagnostic value, plus a round trip. Instead a
    # dropped connection is detected when a query fails, and retried once.
    def connection
      Thread.current[:trilogy] ||= Trilogy.new(**CONFIG)
    end

    def query(sql)
      ensure_schema
      execute(sql)
    end

    def rows(sql)
      result = query(sql)
      result.rows.map { |row| result.fields.zip(row).to_h }
    end

    def one(sql)
      rows(sql).first
    end

    def escape(value)
      connection.escape(value.to_s)
    end

    def transaction
      # Before BEGIN, not inside it: the bootstrap runs DDL, and DDL causes an
      # implicit commit in MySQL, which would silently break the transaction.
      ensure_schema

      connection.query("BEGIN")
      result = yield
      connection.query("COMMIT")
      result
    rescue StandardError
      begin
        connection.query("ROLLBACK")
      rescue StandardError
        nil
      end
      raise
    end

    # Does not bootstrap the schema: this answers "is MySQL reachable", nothing
    # more. Goes through execute so a dead cached connection self-heals.
    def healthy?
      execute("SELECT 1")
      true
    rescue StandardError
      reconnect!
      false
    end

    private

    # One reconnect attempt, so a MySQL restart or an idle-timeout kill costs a
    # single failed query rather than every request on that thread.
    def execute(sql)
      connection.query(sql)
    rescue Trilogy::BaseConnectionError
      reconnect!
      connection.query(sql)
    end

    def reconnect!
      begin
        Thread.current[:trilogy]&.close
      rescue StandardError
        nil
      end
      Thread.current[:trilogy] = nil
    end

    # Idempotent, so every replica can run it and a fresh/empty database
    # (emptyDir volume, recreated container) comes back seeded.
    def ensure_schema
      return if @schema_ready

      BOOTSTRAP_LOCK.synchronize do
        return if @schema_ready

        connection.query(<<~SQL)
          CREATE TABLE IF NOT EXISTS products (
            sku         VARCHAR(64)  NOT NULL PRIMARY KEY,
            name        VARCHAR(128) NOT NULL,
            price_cents INT          NOT NULL,
            stock       INT          NOT NULL,
            warehouse   VARCHAR(32)  NOT NULL
          ) ENGINE=InnoDB
        SQL

        connection.query(<<~SQL)
          CREATE TABLE IF NOT EXISTS reservations (
            id         BIGINT      NOT NULL AUTO_INCREMENT PRIMARY KEY,
            sku        VARCHAR(64) NOT NULL,
            qty        INT         NOT NULL,
            created_at TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
            INDEX idx_reservations_sku (sku)
          ) ENGINE=InnoDB
        SQL

        values = SEED.map do |sku, name, cents, stock, warehouse|
          "('#{connection.escape(sku)}', '#{connection.escape(name)}', #{cents.to_i}, #{stock.to_i}, '#{connection.escape(warehouse)}')"
        end.join(", ")

        connection.query(<<~SQL)
          INSERT INTO products (sku, name, price_cents, stock, warehouse)
          VALUES #{values}
          ON DUPLICATE KEY UPDATE sku = sku
        SQL

        @schema_ready = true
      end
    end
  end
end
