require "json"
require "net/http"
require "sinatra/base"
require "uri"

# Plumbing shared by both services: JSON responses, error handling, /health, and
# custom OpenTelemetry spans that no-op when the auto-instrumentation gem was not
# preloaded. Neither service requires an OpenTelemetry gem directly.
class BaseApp < Sinatra::Base
  set :host_authorization, permitted_hosts: []
  set :show_exceptions, false
  # Sinatra re-raises in the test environment by default; both services always
  # answer with the JSON error handler below, in every environment.
  set :raise_errors, false
  set :service_name, "base"

  BOOTED_AT = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  before do
    content_type "application/json"
  end

  get "/health" do
    json(status: "ok", service: settings.service_name, uptime_seconds: uptime_seconds)
  end

  not_found do
    json(error: "not found", service: settings.service_name, path: request.path_info)
  end

  error do
    json(error: env["sinatra.error"].message, service: settings.service_name)
  end

  private

  def uptime_seconds
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) - BOOTED_AT).round(3)
  end

  # nil unless the process was started with the auto-instrumentation gem
  # preloaded, so both services run identically without it (tests, plain rackup).
  def tracer
    return @tracer if defined?(@tracer)

    @tracer = defined?(OpenTelemetry) ? OpenTelemetry.tracer_provider.tracer(settings.service_name) : nil
  end

  def in_span(name, attributes: {})
    return yield(nil) if tracer.nil?

    tracer.in_span(name, attributes: attributes) { |span| yield(span) }
  end

  def json(payload)
    JSON.pretty_generate(payload) + "\n"
  end

  def hostname
    ENV.fetch("HOSTNAME", "unknown")
  end
end
