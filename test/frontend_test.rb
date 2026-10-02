ENV["APP_ENV"] = "test"
ENV["BACKEND_BASE_URL"] = "http://backend.test"

require "minitest/autorun"
require "rack/test"
require "webmock/minitest"
require_relative "../frontend"

class FrontendAppTest < Minitest::Test
  include Rack::Test::Methods

  BACKEND = "http://backend.test".freeze

  def app
    FrontendApp
  end

  def stub_backend(path, body, status: 200)
    stub_request(:get, "#{BACKEND}#{path}")
      .to_return(status: status, body: JSON.generate(body), headers: { "Content-Type" => "application/json" })
  end

  def test_root_reports_service_and_backend
    get "/"

    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal "example-frontend", body["service"]
    assert_equal BACKEND, body["backend"]
    refute body["traced"], "tests run without the auto-instrumentation gem preloaded"
  end

  def test_health_needs_no_backend
    get "/health"

    assert_equal 200, last_response.status
    assert_equal "example-frontend", JSON.parse(last_response.body)["service"]
  end

  def test_hello_is_served_locally
    get "/hello/world"

    assert_equal "Hello, world!", JSON.parse(last_response.body)["greeting"]
  end

  def test_order_combines_both_backend_calls
    stub_backend("/inventory/widget-1", { sku: "widget-1", available: 7, warehouse: "euw1-b", service: "example-backend" })
    stub_backend("/price/widget-1", { sku: "widget-1", cents: 1_250, currency: "EUR", service: "example-backend" })

    get "/order/widget-1"

    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal 7, body["available"]
    assert_equal 1_250, body["total_cents"]
    assert_equal "euw1-b", body["warehouse"]
    assert_requested :get, "#{BACKEND}/inventory/widget-1"
    assert_requested :get, "#{BACKEND}/price/widget-1"
  end

  def test_order_surfaces_a_backend_failure
    stub_backend("/inventory/ghost", { error: "sku ghost is not stocked" }, status: 500)

    get "/order/ghost"

    assert_equal 500, last_response.status
    error = JSON.parse(last_response.body)["error"]
    assert_match(/returned 500/, error)
    assert_match(/not stocked/, error)
  end

  def test_order_does_not_call_price_when_inventory_fails
    stub_backend("/inventory/ghost", { error: "boom" }, status: 500)
    price = stub_backend("/price/ghost", { cents: 1 })

    get "/order/ghost"

    assert_not_requested price
  end

  def test_checkout_reserves_through_the_backend
    stub_backend("/inventory/widget-1", { sku: "widget-1", available: 9, warehouse: "euw1-a", service: "example-backend" })
    stub_backend("/reserve?sku=widget-1&qty=2", { reserved: true, sku: "widget-1", qty: 2, service: "example-backend" })

    get "/checkout/widget-1?qty=2"

    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal "complete", body["checkout"]
    assert_equal 2, body["qty"]
  end

  def test_checkout_propagates_a_reservation_failure
    stub_backend("/inventory/widget-1", { sku: "widget-1", available: 9, warehouse: "euw1-a", service: "example-backend" })
    stub_backend("/reserve?sku=widget-1&qty=11", { error: "cannot reserve 11 of widget-1: limit is 10" }, status: 500)

    get "/checkout/widget-1?qty=11"

    assert_equal 500, last_response.status
    assert_match(/limit is 10/, JSON.parse(last_response.body)["error"])
  end

  def test_slow_path_reports_backend_latency
    stub_backend("/slow?ms=120", { slept_ms: 120, service: "example-backend" })

    get "/slow-path?ms=120"

    assert_equal 120, JSON.parse(last_response.body)["waited_on_backend_ms"]
  end

  def test_fail_never_touches_the_backend
    get "/fail"

    assert_equal 500, last_response.status
    assert_equal "deliberate frontend failure for trace testing", JSON.parse(last_response.body)["error"]
  end

  def test_unknown_path_returns_404_json
    get "/nope"

    assert_equal 404, last_response.status
    assert_equal "not found", JSON.parse(last_response.body)["error"]
  end
end
