require_relative "lib/base_app"
require_relative "lib/db"

# The downstream service. Reads and writes MySQL, so its spans carry the SQL
# statements the auto-instrumentation records, plus the internal spans that show
# where time goes inside a request.
class BackendApp < BaseApp
  set :service_name, "example-backend"

  get "/" do
    json(
      service: settings.service_name,
      ruby: RUBY_VERSION,
      hostname: hostname,
      traced: !tracer.nil?,
      mysql: { host: DB::CONFIG[:host], database: DB::CONFIG[:database] },
      endpoints: ["/", "/health", "/ready", "/catalog", "/inventory/:sku", "/price/:sku",
                  "/reserve?sku=&qty=", "/work", "/slow?ms=250", "/flaky?error_rate=0.3"]
    )
  end

  # Deliberately does NOT touch MySQL: probes must not fail the pod when the
  # database is briefly unavailable, and this path is excluded from tracing.
  # Use /ready for a database-aware check.
  get "/ready" do
    if DB.healthy?
      json(status: "ready", mysql: "up", service: settings.service_name)
    else
      status 503
      json(status: "not ready", mysql: "down", service: settings.service_name)
    end
  end

  # One SELECT returning several rows.
  get "/catalog" do
    products = DB.rows(<<~SQL)
      SELECT sku, name, price_cents, stock, warehouse
      FROM products
      ORDER BY sku
    SQL

    json(count: products.size, products: products, service: settings.service_name)
  end

  # SELECT plus a validation span.
  get "/inventory/:sku" do
    sku = params["sku"]

    product = DB.one("SELECT sku, stock, warehouse FROM products WHERE sku = '#{DB.escape(sku)}'")

    in_span("inventory.validate", attributes: { "inventory.sku" => sku }) do |span|
      raise "sku #{sku} does not exist" if product.nil?

      span&.set_attribute("inventory.available", product["stock"])
      raise "sku #{sku} is out of stock" if product["stock"].to_i.zero?
    end

    json(
      sku: product["sku"],
      available: product["stock"],
      warehouse: product["warehouse"],
      service: settings.service_name
    )
  end

  # The slowest leg of an order trace: a join plus a deliberate sleep in SQL, so
  # the critical path is obvious and attributable to the database rather than Ruby.
  get "/price/:sku" do
    sku = params["sku"]

    product = DB.one(<<~SQL)
      SELECT sku, name, price_cents, SLEEP(0.02) AS throttle
      FROM products
      WHERE sku = '#{DB.escape(sku)}'
    SQL

    raise "sku #{sku} does not exist" if product.nil?

    json(
      sku: product["sku"],
      name: product["name"],
      cents: product["price_cents"],
      currency: "EUR",
      service: settings.service_name
    )
  end

  # A write in a transaction: BEGIN, conditional UPDATE, INSERT, COMMIT — four
  # db.client spans, and a rollback path when stock is short.
  get "/reserve" do
    sku = params["sku"].to_s
    qty = params["qty"].to_i

    raise "qty must be positive" unless qty.positive?
    raise "cannot reserve #{qty} of #{sku}: limit is 10" if qty > 10

    reservation_id = in_span("reserve.transaction", attributes: { "reserve.sku" => sku, "reserve.qty" => qty }) do
      DB.transaction do
        updated = DB.query(<<~SQL)
          UPDATE products
          SET stock = stock - #{qty}
          WHERE sku = '#{DB.escape(sku)}' AND stock >= #{qty}
        SQL

        raise "insufficient stock for #{sku}" if updated.affected_rows.zero?

        DB.query(<<~SQL)
          INSERT INTO reservations (sku, qty)
          VALUES ('#{DB.escape(sku)}', #{qty})
        SQL

        DB.one("SELECT LAST_INSERT_ID() AS id")["id"]
      end
    end

    json(reserved: true, reservation_id: reservation_id, sku: sku, qty: qty, service: settings.service_name)
  end

  # Nested custom spans, one per stage. No database involvement.
  get "/work" do
    stages = in_span("work.pipeline") do |span|
      span&.set_attribute("work.stage_count", 3)
      %w[validate transform persist].each_with_object({}) do |stage, acc|
        acc[stage] = in_span("work.#{stage}", attributes: { "work.stage" => stage }) do
          ms = rand(5..25)
          sleep(ms / 1000.0)
          ms
        end
      end
    end

    json(work: "done", stage_ms: stages, service: settings.service_name)
  end

  # Predictable latency, so you can query for slow traces on purpose.
  get "/slow" do
    ms = (params["ms"] || 250).to_i.clamp(0, 5_000)
    in_span("slow.sleep", attributes: { "slow.requested_ms" => ms }) { sleep(ms / 1000.0) }
    json(slept_ms: ms, service: settings.service_name)
  end

  # Fails a fraction of the time, for a non-trivial error rate to alert on.
  get "/flaky" do
    rate = (params["error_rate"] || 0.3).to_f.clamp(0.0, 1.0)
    raise "flaky failure (error_rate=#{rate})" if rand < rate

    json(status: "ok", error_rate: rate, service: settings.service_name)
  end
end
