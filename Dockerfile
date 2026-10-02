# syntax=docker/dockerfile:1

# Build stage: resolve and install gems against the local Gemfile.
#
# Deliberately NOT setting BUNDLE_PATH. The official image already has
# GEM_HOME=/usr/local/bundle with /usr/local/bundle/bin on PATH; setting
# BUNDLE_PATH switches Bundler to a nested layout that plain RubyGems cannot
# see, which both hides the bundle from the OTel auto-instrumentation gem and
# leaves the rackup/puma binstubs off PATH.
FROM ruby:3.3-slim AS gems

ENV BUNDLE_WITHOUT=development:test \
    BUNDLE_FROZEN=true \
    BUNDLE_JOBS=4 \
    BUNDLE_RETRY=3

WORKDIR /app

# build-essential for native extensions; libssl-dev + pkg-config because the
# trilogy MySQL client compiles against OpenSSL. None of this reaches the
# runtime stage, which already has libssl3 via Ruby itself.
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential libssl-dev pkg-config \
 && rm -rf /var/lib/apt/lists/*

# Copy only the dependency manifests first so this layer is cached
# until Gemfile/Gemfile.lock actually change.
COPY Gemfile Gemfile.lock ./
RUN bundle install && rm -rf /usr/local/bundle/cache

# OpenTelemetry auto-instrumentation is installed as a plain system gem and
# deliberately kept OUT of the Gemfile: it must load before the app, so Bundler
# cannot be the thing that loads it. It shares GEM_HOME with the bundle, so it
# travels with the bundle copy in the runtime stage.
RUN gem install --no-document opentelemetry-auto-instrumentation

# Runtime stage: no compilers, no bundler cache, non-root user.
FROM ruby:3.3-slim

ENV BUNDLE_WITHOUT=development:test \
    BUNDLE_FROZEN=true \
    APP_ENV=production \
    PORT=8080 \
    APP_ROLE=frontend \
    OTEL_TRACES_EXPORTER=otlp \
    OTEL_METRICS_EXPORTER=none \
    OTEL_LOGS_EXPORTER=none \
    OTEL_RUBY_REQUIRE_BUNDLER=true

WORKDIR /app

COPY --from=gems /usr/local/bundle /usr/local/bundle

# The application source comes straight from the local build context.
COPY . .

RUN useradd --create-home --shell /usr/sbin/nologin app \
 && chown -R app:app /app
USER app

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD ruby -e "require 'net/http'; exit(Net::HTTP.get_response(URI(\"http://127.0.0.1:#{ENV['PORT']}/health\")).code == '200' ? 0 : 1)"

# Bind [::] rather than 0.0.0.0: a dual-stack socket serves IPv4 and IPv6, so
# this works on IPv6-only and dual-stack clusters where probes target the pod's
# IPv6 address. Binding 0.0.0.0 there fails readiness with connection refused.
#
# No `bundle exec`: it would restrict the load path and hide the system-installed
# OTel gem. RUBYOPT is scoped to this process so `kubectl exec ... ruby -e` and
# the healthcheck above do not each boot a tracing SDK.
#
# One image serves both services; APP_ROLE picks which one config.ru runs.
# OTEL_SERVICE_NAME is derived from the role unless set explicitly, so a backend
# container can never report spans under the frontend's service name.
CMD ["sh", "-c", ": \"${OTEL_SERVICE_NAME:=example-${APP_ROLE}}\"; export OTEL_SERVICE_NAME; RUBYOPT=\"-r opentelemetry-auto-instrumentation\" rackup config.ru -s puma -o :: -p ${PORT} -E ${APP_ENV}"]
