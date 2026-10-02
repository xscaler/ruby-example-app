require_relative "lib/base_app"

# The upstream service. Owns no business logic: every interesting route fans out
# to the backend over HTTP, which is what produces cross-service traces.
class FrontendApp < BaseApp
  set :service_name, "example-frontend"

  # In-cluster this is the backend Service, so each call crosses a pod boundary.
  BACKEND = ENV.fetch("BACKEND_BASE_URL", "http://example-backend.ruby-test.svc.cluster.local")

  get "/" do
    json(
      service: settings.service_name,
      ruby: RUBY_VERSION,
      hostname: hostname,
      traced: !tracer.nil?,
      backend: BACKEND,
      endpoints: ["/", "/health", "/hello/:name", "/order/:sku",
                  "/checkout/:sku?qty=2", "/slow-path?ms=250", "/fail"]
    )
  end

  get "/hello/:name" do
    json(greeting: "Hello, #{params[:name]}!", service: settings.service_name)
  end

  # Two sequential backend calls. One trace: frontend server span, two client
  # spans, two backend server spans, plus the backend's own internal spans.
  get "/order/:sku" do
    sku = params["sku"]

    inventory = backend_get("/inventory/#{sku}")
    price = backend_get("/price/#{sku}")

    in_span("order.assemble", attributes: { "order.sku" => sku }) do |span|
      span&.set_attribute("order.total_cents", price.fetch("cents"))
    end

    json(
      sku: sku,
      available: inventory.fetch("available"),
      warehouse: inventory.fetch("warehouse"),
      total_cents: price.fetch("cents"),
      currency: price.fetch("currency"),
      served_by: { frontend: hostname, backend: inventory.fetch("service") }
    )
  end

  # Checks stock, then reserves. qty > 10 makes the backend fail, so the error
  # surfaces on spans in both services within one trace.
  get "/checkout/:sku" do
    sku = params["sku"]
    qty = (params["qty"] || 1).to_i

    inventory = backend_get("/inventory/#{sku}")
    reservation = backend_get("/reserve?sku=#{sku}&qty=#{qty}")

    json(
      checkout: "complete",
      sku: sku,
      qty: reservation.fetch("qty"),
      available_before: inventory.fetch("available"),
      served_by: { frontend: hostname }
    )
  end

  get "/slow-path" do
    ms = (params["ms"] || 250).to_i.clamp(0, 5_000)
    downstream = backend_get("/slow?ms=#{ms}")

    json(waited_on_backend_ms: downstream.fetch("slept_ms"), service: settings.service_name)
  end

  # Fails in the frontend itself, with no backend involvement.
  get "/fail" do
    raise "deliberate frontend failure for trace testing"
  end

  private

  def backend_get(path)
    uri = URI("#{BACKEND}#{path}")

    response = Net::HTTP.start(uri.hostname, uri.port, open_timeout: 2, read_timeout: 10) do |http|
      http.request(Net::HTTP::Get.new(uri))
    end

    unless response.is_a?(Net::HTTPSuccess)
      detail = begin
        JSON.parse(response.body).fetch("error", response.body)
      rescue JSON::ParserError
        response.body
      end
      raise "backend #{path} returned #{response.code}: #{detail}"
    end

    JSON.parse(response.body)
  end
end
