# Enable OpenTelemetry in your Ruby app

Traces from your Ruby service with **no application code**: HTTP spans in and
out, SQL spans, and trace context propagated between services automatically.

Three steps: change your Dockerfile, test it locally, set three env vars in
Kubernetes.

---

## Step 1 — Dockerfile

Add these three things.

```dockerfile
# 1. Install the gem OUTSIDE your Gemfile. It must load before your app,
#    so Bundler cannot be what loads it.
RUN gem install --no-document opentelemetry-auto-instrumentation

# 2. Rails calls Bundler.require itself; Sinatra/Rack/Puma do not.
ENV OTEL_RUBY_REQUIRE_BUNDLER=true

# 3. Preload the gem via RUBYOPT. Note: no `bundle exec`.
CMD ["sh", "-c", "RUBYOPT=\"-r opentelemetry-auto-instrumentation\" rackup config.ru -s puma -o :: -p ${PORT}"]
```

Rails is the same idea:

```dockerfile
CMD ["sh", "-c", "RUBYOPT=\"-r opentelemetry-auto-instrumentation\" rails server -b '[::]' -p ${PORT}"]
```

**Four things not to do:**

- Don't add the gem to your `Gemfile`.
- Don't use `bundle exec` — it hides the gem (`LoadError`).
- Don't set `BUNDLE_PATH` — it hides your bundle from the gem.
- Don't set `RUBYOPT` as an `ENV` — then every `ruby -e` in the container boots a
  tracing SDK too. Keep it in the CMD.

---

## Step 2 — Kubernetes

Put the credentials in a Secret:

```sh
kubectl create secret generic otel-creds -n <namespace> \
  --from-literal=headers='Authorization=Bearer <token>,X-Scope-OrgID=<tenant>'
```

Add this to your Deployment's container `env`:

```yaml
- name: OTEL_SERVICE_NAME
  value: my-service
- name: OTEL_EXPORTER_OTLP_TRACES_ENDPOINT
  value: https://euw1-01.t.xscalerlabs.com/otlp/v1/traces
- name: OTEL_EXPORTER_OTLP_HEADERS
  valueFrom:
    secretKeyRef:
      name: otel-creds
      key: headers
- name: OTEL_METRICS_EXPORTER
  value: none
- name: OTEL_LOGS_EXPORTER
  value: none
# Keep health probes out of your traces — they fire every few seconds forever.
- name: OTEL_RUBY_INSTRUMENTATION_RACK_CONFIG_OPTS
  value: untraced_endpoints=/health
```

Use `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`, **not** the bare
`OTEL_EXPORTER_OTLP_ENDPOINT` — the bare one gets a default path appended and
returns a confusing 403.
