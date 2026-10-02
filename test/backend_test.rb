ENV["APP_ENV"] = "test"

require "minitest/autorun"
require "rack/test"
require_relative "../backend"

class BackendAppTest < Minitest::Test
  include Rack::Test::Methods

  def app
    BackendApp
  end

  # The DB-backed routes need a real MySQL. Probed once per run so the suite
  # still passes standalone (`ruby test/backend_test.rb`) and covers those
  # routes when run inside the compose network. See README.
  def self.db_available?
    return @db_available if defined?(@db_available)

    @db_available = DB.healthy?
  end

  def requires_db
    skip "MySQL not reachable at #{DB::CONFIG[:host]}:#{DB::CONFIG[:port]}" unless self.class.db_available?
  end

  # --- no database needed ---

  def test_root_reports_service_metadata
    get "/"

    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal "example-backend", body["service"]
    refute body["traced"], "tests run without the auto-instrumentation gem preloaded"
    assert_equal DB::CONFIG[:database], body.dig("mysql", "database")
  end

  def test_health_does_not_touch_mysql
    get "/health"

    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal "ok", body["status"]
    assert_equal "example-backend", body["service"]
    refute body.key?("mysql"), "/health must stay database-free so probes survive a DB blip"
  end

  def test_work_runs_every_stage
    get "/work"

    stages = JSON.parse(last_response.body)["stage_ms"]
    assert_equal %w[persist transform validate], stages.keys.sort
    stages.each_value { |ms| assert_operator ms, :>, 0 }
  end

  def test_slow_clamps_absurd_values
    get "/slow?ms=999999"

    assert_equal 5_000, JSON.parse(last_response.body)["slept_ms"]
  end

  def test_flaky_always_succeeds_at_zero_error_rate
    10.times do
      get "/flaky?error_rate=0"
      assert_equal 200, last_response.status
    end
  end

  def test_flaky_always_fails_at_full_error_rate
    get "/flaky?error_rate=1"

    assert_equal 500, last_response.status
  end

  def test_unknown_path_returns_404_json
    get "/nope"

    assert_equal 404, last_response.status
    assert_equal "not found", JSON.parse(last_response.body)["error"]
  end

  def test_reserve_rejects_a_non_positive_quantity
    get "/reserve?sku=widget-1&qty=0"

    assert_equal 500, last_response.status
    assert_match(/qty must be positive/, JSON.parse(last_response.body)["error"])
  end

  def test_reserve_rejects_above_the_limit_before_touching_mysql
    get "/reserve?sku=widget-1&qty=11"

    assert_equal 500, last_response.status
    assert_match(/limit is 10/, JSON.parse(last_response.body)["error"])
  end

  # --- database required ---

  def test_ready_reports_mysql_up
    requires_db
    get "/ready"

    assert_equal 200, last_response.status
    assert_equal "up", JSON.parse(last_response.body)["mysql"]
  end

  def test_catalog_returns_the_seeded_products
    requires_db
    get "/catalog"

    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal DB::SEED.size, body["count"]
    assert_equal DB::SEED.map(&:first).sort, body["products"].map { |p| p["sku"] }.sort
  end

  def test_inventory_reads_stock_and_warehouse
    requires_db
    get "/inventory/widget-0"

    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal "widget-0", body["sku"]
    assert_operator body["available"], :>=, 0
    assert_equal "euw1-a", body["warehouse"]
  end

  def test_inventory_rejects_an_unknown_sku
    requires_db
    get "/inventory/does-not-exist"

    assert_equal 500, last_response.status
    assert_match(/does not exist/, JSON.parse(last_response.body)["error"])
  end

  def test_price_is_in_euro_cents
    requires_db
    get "/price/widget-0"

    body = JSON.parse(last_response.body)
    assert_equal "EUR", body["currency"]
    assert_equal 499, body["cents"]
    assert_equal "Basic Widget", body["name"]
  end

  def test_reserve_decrements_stock_and_records_a_reservation
    requires_db
    before = JSON.parse((get("/inventory/widget-3"); last_response.body))["available"]

    get "/reserve?sku=widget-3&qty=2"
    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    assert body["reserved"]
    assert_operator body["reservation_id"].to_i, :>, 0

    get "/inventory/widget-3"
    assert_equal before - 2, JSON.parse(last_response.body)["available"]
  end

  def test_reserve_rolls_back_when_stock_is_short
    requires_db
    # widget-4 is seeded with stock 1, so asking for 10 cannot succeed.
    get "/reserve?sku=widget-4&qty=10"

    assert_equal 500, last_response.status
    assert_match(/insufficient stock/, JSON.parse(last_response.body)["error"])

    get "/inventory/widget-4"
    assert_operator JSON.parse(last_response.body)["available"], :>, 0, "rollback must leave stock intact"
  end
end
