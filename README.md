# ruby-example-app

Two small Sinatra services — `example-frontend` and `example-backend` — that call
each other over HTTP, backed by MySQL, packaged in a single Docker image built
from the local source tree (no registry pull of the app, no `git clone` inside
the build) and traced end to end with OpenTelemetry auto-instrumentation.

The point is the traces: one request to the frontend produces a single trace
spanning **three tiers** — HTTP client and server spans across a pod boundary,
the backend's internal spans, and a `db.client` span per SQL statement with the
statement text attached.

```
example-frontend  GET /order/:sku             (server)
├── connect / GET                             (client, Net::HTTP)
│   └── example-backend  GET /inventory/:sku  (server)
│       ├── select  SELECT sku, stock, warehouse FROM products WHERE sku = ?
│       └── inventory.validate                (internal)
├── connect / GET                             (client, Net::HTTP)
│   └── example-backend  GET /price/:sku      (server)
│       └── select  SELECT sku, name, price_cents, SLEEP(0.02) ...
└── order.assemble                            (internal)
```

`/checkout` adds a transaction — `begin`, `update`, `insert`, `commit` as four
separate `db.client` spans, with a rollback path when stock is short.

## Porting this to your own app

[SETUP.md](SETUP.md) is a step-by-step guide to getting the same result in a
different Ruby service: every Docker and Kubernetes change, what needs no code,
and a troubleshooting table of the failures hit while building this.

## One image, two roles

`APP_ROLE` selects which app `config.ru` runs, so both services ship from the
same build:

| File | Role |
| --- | --- |
| `lib/base_app.rb` | shared plumbing: JSON responses, error handling, `/health`, the tracer helper |
| `frontend.rb` | `FrontendApp` — fans out to the backend over HTTP |
| `backend.rb` | `BackendApp` — does the work, owns the internal spans |
| `config.ru` | `APP_ROLE=frontend\|backend` picks one |

`OTEL_SERVICE_NAME` defaults to `example-$APP_ROLE` in the image CMD, so a
backend container can never report spans under the frontend's service name. The
Kubernetes manifests set it explicitly anyway.

## Routes

**Frontend** (`example-frontend`)

| Path | Calls backend | Span shape |
| --- | --- | --- |
| `/` | no | service metadata, shows `"traced": true\|false` |
| `/health` | no | excluded from tracing (see below) |
| `/hello/:name` | no | one server span |
| `/order/:sku` | `/inventory/:sku`, `/price/:sku` | **11 spans, two services** — the flagship trace |
| `/checkout/:sku?qty=2` | `/inventory/:sku`, `/reserve` | cross-service; `qty > 10` fails in the backend and surfaces here |
| `/slow-path?ms=250` | `/slow` | latency owned entirely by the downstream |
| `/fail` | no | frontend-only error, for contrast |

**Backend** (`example-backend`)

| Path | Span shape |
| --- | --- |
| `/ready` | database-aware check: `SELECT 1`, 503 when MySQL is down |
| `/catalog` | one `select` returning all seeded rows |
| `/inventory/:sku` | `select` on `products` + `inventory.validate`; unknown or out-of-stock SKUs raise |
| `/price/:sku` | `select` with `SLEEP(0.02)` — the slowest leg, so the critical path is attributable to the database, not Ruby |
| `/reserve?sku=&qty=` | `reserve.transaction` wrapping `begin`/`update`/`insert`/`commit`; rolls back when stock is short, fails above qty 10 |
| `/work` | `work.pipeline` → `work.validate` / `work.transform` / `work.persist` |
| `/slow?ms=250` | `slow.sleep`, clamped to 5s |
| `/flaky?error_rate=0.3` | fails a fraction of the time, for a non-trivial error rate |

## Run the whole stack locally

Compose brings up MySQL plus the image twice, once per role. The backend waits
for MySQL's healthcheck, then creates and seeds the schema on its first query.

```sh
docker compose up --build

curl localhost:8081/ready                 # backend: is MySQL up?
curl localhost:8081/catalog               # the seeded products
curl localhost:8080/order/widget-1        # frontend -> backend -> mysql
curl 'localhost:8080/checkout/widget-1?qty=2'    # real stock decrement
curl 'localhost:8080/checkout/widget-1?qty=11'   # cross-service failure
```

MySQL is published on **3307** to avoid clashing with a local install:

```sh
docker compose exec mysql mysql -uexample -pexample example -e 'SELECT * FROM products'
```

Both containers run with `OTEL_TRACES_EXPORTER=console`, so the spans print to
the logs — no collector or credentials needed:

```sh
docker compose logs frontend | grep -A3 'SpanData'
docker compose logs backend  | grep '"service.name"'
```

To run just one role from the image directly:

```sh
docker build -t ruby-example-app:local .
docker run --rm -p 8081:8080 -e APP_ROLE=backend ruby-example-app:local
docker run --rm -p 8080:8080 -e APP_ROLE=frontend \
  -e BACKEND_BASE_URL=http://host.docker.internal:8081 ruby-example-app:local
```

## How the Dockerfile is laid out

- **Stage `gems`** installs gems against `Gemfile` + `Gemfile.lock` only, so the
  dependency layer stays cached until those two files change. `build-essential`
  lives here for native extensions (`puma` needs it) and never reaches the
  runtime image.
- **Runtime stage** copies `/usr/local/bundle` from the build stage, then copies
  the app source from the local build context, and runs as the non-root `app`
  user. `BUNDLE_FROZEN=true` means a `Gemfile` change without a matching
  lockfile fails the build instead of silently re-resolving.
- `HEALTHCHECK` hits `/health` with plain Ruby stdlib, so the image needs no
  `curl`.
- The server binds `[::]`, not `0.0.0.0`. A dual-stack socket serves IPv4 and
  IPv6; binding `0.0.0.0` on an IPv6 cluster fails readiness with `connect:
  connection refused` because the kubelet probes the pod's IPv6 address.

`.dockerignore` keeps `.git`, local bundles, logs and `.env` files out of the
build context.

## Tests

Minitest + `rack-test`, plus `webmock` so the frontend's backend calls can be
asserted without a live backend. The `test` group is excluded from the image, so
run them in the full Ruby image.

Standalone — the seven DB-backed backend tests **skip** rather than fail:

```sh
docker run --rm -v "$PWD":/app -w /app -e BUNDLE_PATH=/tmp/bundle ruby:3.3 sh -c \
  'bundle install --quiet && bundle exec ruby test/backend_test.rb && bundle exec ruby test/frontend_test.rb'
```

Against the live MySQL from `docker compose up` — nothing skips:

```sh
docker run --rm --network ruby-example-app_default -v "$PWD":/app -w /app \
  -e BUNDLE_PATH=/tmp/bundle -e MYSQL_HOST=mysql ruby:3.3 sh -c \
  'bundle install --quiet && bundle exec ruby test/backend_test.rb && bundle exec ruby test/frontend_test.rb'
```

## Updating dependencies

After editing the `Gemfile`, regenerate the lockfile in a Linux container so the
recorded platforms match the image:

```sh
docker run --rm -v "$PWD":/app -w /app ruby:3.3-slim \
  bundle lock --add-platform aarch64-linux --add-platform x86_64-linux
```

## Push to Docker Hub

```sh
export IMAGE=<your-registry>/ruby-example-app   # e.g. docker.io/<user> or an ECR/GAR host
export TAG=0.4.0
docker login
```

**Build for the cluster's architecture, not your laptop's.** An arm64-only image
fails on an amd64 node with `exec format error`:

```sh
docker buildx build --platform linux/amd64,linux/arm64 -t $IMAGE:$TAG --push .
```

If that errors with "multiple platforms feature is currently not supported",
create a container-driver builder first:

```sh
docker buildx create --name multi --driver docker-container --use --bootstrap
```

Confirm what landed, and grab the digest:

```sh
docker buildx imagetools inspect $IMAGE:$TAG
```

## Deploy to Kubernetes

`k8s/` holds the Namespace, a Deployment+Service pair per service, MySQL with its
credentials Secret, and an optional load generator — one replica each.
Everything pins `namespace: ruby-test`, so nothing can land in the wrong
namespace by accident.

The manifests ship with a placeholder image, so point them at your registry
first:

```sh
sed -i '' "s|<your-registry>|${IMAGE%/*}|" k8s/frontend.yaml k8s/backend.yaml
```

```sh
kubectl config use-context <your-context>     # be deliberate about this
kubectl apply -f k8s/
kubectl rollout status -n ruby-test deploy/mysql --timeout=300s
kubectl rollout status -n ruby-test deploy/example-backend
kubectl rollout status -n ruby-test deploy/example-frontend
kubectl get pods,svc -n ruby-test
```

Total requested: **210m CPU / 544Mi memory** — MySQL is 100m/256Mi of that, with
a 512Mi limit, and is by far the heaviest piece. Its `innodb-buffer-pool-size` is
trimmed to 64M; an untuned MySQL 8 wants roughly 1Gi. The data lives in an
`emptyDir`, so it is lost when the pod restarts and the backend simply re-creates
and re-seeds the schema — swap in a PVC if you want it kept.

The frontend reaches the backend at
`http://example-backend.ruby-test.svc.cluster.local` (`BACKEND_BASE_URL`), which
is the Service on port 80.

Smoke-test through the frontend Service without exposing anything publicly:

```sh
kubectl port-forward -n ruby-test svc/example-frontend 8080:80
curl localhost:8080/order/widget-1
```

Tear everything down by deleting the namespace:

```sh
kubectl delete namespace ruby-test
```

### What the manifests assume

- **Probes** all hit `/health`. The `startupProbe` gives Puma up to 30s to boot
  before the liveness probe can kill the pod; readiness gates Service traffic.
- **Security context** matches the image: UID/GID 1000 (the `app` user),
  `runAsNonRoot`, no privilege escalation, all capabilities dropped, and a
  read-only root filesystem with an `emptyDir` at `/tmp` for Rack/Puma. Verified
  by running the image with `--read-only --tmpfs /tmp --user 1000:1000
  --cap-drop ALL`.
- **`maxUnavailable: 0`** means rollouts add a new pod before retiring an old
  one, so there's no capacity dip.
- **No CPU limit**, only a request — a CPU limit would throttle Puma under
  burst. Memory has both, since memory isn't compressible.

### Private Docker Hub repository

A public repo needs no credentials. For a private one, create a pull secret and
add `imagePullSecrets` to both deployments:

```sh
kubectl create secret docker-registry dockerhub -n ruby-test \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username=<registry-user> \
  --docker-password=<access-token>
```

Use a Hub **access token**, not your password.

### Shipping a new version

Tags in the manifests are immutable on purpose, so a deploy is: build, push, bump
both.

```sh
export TAG=0.4.1
docker buildx build --platform linux/amd64,linux/arm64 -t $IMAGE:$TAG --push .
kubectl set image -n ruby-test deploy/example-backend  web=$IMAGE:$TAG
kubectl set image -n ruby-test deploy/example-frontend web=$IMAGE:$TAG
kubectl rollout status -n ruby-test deploy/example-frontend
```

Roll back with `kubectl rollout undo -n ruby-test deploy/<name>`. For full
reproducibility, deploy the digest instead of the tag —
`web=$IMAGE@sha256:<digest>` from the `imagetools inspect` output above.

## OpenTelemetry auto-instrumentation

Traces come from the
[`opentelemetry-auto-instrumentation`](https://github.com/open-telemetry/opentelemetry-ruby-instrumentation)
gem. No application file requires it.

### How it's wired

1. **Installed as a system gem, not a Gemfile entry** (`Dockerfile`): it has to
   load *before* the app, so Bundler must not be what loads it.
   ```dockerfile
   RUN gem install --no-document opentelemetry-auto-instrumentation
   ```
2. **Preloaded via `RUBYOPT`, and no `bundle exec`.** Sinatra doesn't call
   `Bundler.require` the way Rails does, so `OTEL_RUBY_REQUIRE_BUNDLER=true`
   (set in the image) tells the gem to require the bundle itself. `RUBYOPT` is
   scoped to the server process rather than set as an image `ENV`, so
   `kubectl exec ... ruby -e` and the `HEALTHCHECK` don't each boot a tracing
   SDK.
3. **Endpoint and credentials come from the environment** — see
   `k8s/frontend.yaml` and `k8s/backend.yaml`. Nothing sensitive is baked into
   the image.

Two constraints worth not re-learning: `bundle exec` restricts the load path and
hides the system gem (`LoadError`), and setting `BUNDLE_PATH` switches Bundler to
a nested layout invisible to RubyGems, which hides the *bundle* from the gem and
surfaces as `You have already activated logger 1.6.0, but your Gemfile requires
logger 1.7.0`.

### What is auto vs. manual

Auto-instrumentation gives every `GET /...` server span, every Net::HTTP client
span, route templating (`/order/:sku`, not `/order/widget-1`), status codes and
error status — with zero application code. Measured overhead: ~15 MiB RSS
(38 MiB with, 23 MiB without), well inside the 256Mi limit.

The named internal spans (`inventory.lookup`, `price.fetch`, `work.persist`,
`order.assemble`) are manual, because auto-instrumentation can only see library
boundaries, not the structure inside a handler. They go through a helper that
no-ops when the gem was not preloaded, so the services and their tests run
identically without any OpenTelemetry present:

```ruby
def tracer
  return @tracer if defined?(@tracer)

  @tracer = defined?(OpenTelemetry) ? OpenTelemetry.tracer_provider.tracer(settings.service_name) : nil
end
```

`defined?(@tracer)` rather than `@tracer ||=` because the value is legitimately
`nil` and `||=` never caches a falsy result. `/` reports
`"traced": true|false` so you can see which mode a process is in.

### Pointing it at xScaler

Always the **signal-specific** variable. The bare `OTEL_EXPORTER_OTLP_ENDPOINT`
gets a default path appended and returns an opaque 403:

```sh
OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=https://euw1-01.t.xscalerlabs.com/otlp/v1/traces
OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer <token>,X-Scope-OrgID=<tenant-id>"
```

`euw1` is the environment name reported by xScaler's telemetry sources. The
bearer token lives in a Secret, never in a manifest:

```sh
kubectl create secret generic otel-xscaler -n ruby-test \
  --from-literal=headers='Authorization=Bearer <token>,X-Scope-OrgID=<tenant-id>'
```

### Probe traffic is excluded

`OTEL_RUBY_INSTRUMENTATION_RACK_CONFIG_OPTS=untraced_endpoints=/health` keeps the
Kubernetes probes out of the trace stream — they fire every 5-10s per pod and
would otherwise swamp the tenant. Verified: six requests to `/health` emitted no
spans while other routes each emitted one. The env var convention is
`OTEL_RUBY_INSTRUMENTATION_<NAME>_CONFIG_OPTS`, `;`-separated `key=value` pairs,
with array values comma-separated.

### Verifying

Env vars being set proves nothing. Check, in order:

```sh
# 1. the gem is actually preloaded in the running process
kubectl exec -n ruby-test deploy/example-frontend -- sh -c 'cat /proc/1/cmdline | tr "\0" " "'

# 2. the SDK initialized and installed instrumentations
kubectl logs -n ruby-test deploy/example-frontend | grep -i 'Auto-instrumentation\|Instrumentation:'

# 3. generate cross-service traffic
kubectl port-forward -n ruby-test svc/example-frontend 8080:80 >/dev/null 2>&1 &
sleep 3
for i in $(seq 1 15); do
  curl -s localhost:8080/order/widget-$((RANDOM % 5))      >/dev/null
  curl -s "localhost:8080/checkout/widget-1?qty=2"         >/dev/null
  curl -s "localhost:8080/slow-path?ms=$((RANDOM % 400))"  >/dev/null
done
curl -s "localhost:8080/checkout/widget-1?qty=11" >/dev/null   # cross-service error
curl -s localhost:8080/fail                        >/dev/null   # frontend-only error
kill %1
```

Then query xScaler. Export failures show up in the pod logs as OTLP exporter
errors, so check those too if nothing appears.

```
{resource.service.name="example-frontend"}
{resource.service.name="example-frontend" && name="GET /order/:sku"}
{resource.service.name="example-backend" && status=error}
{name="price.fetch" && duration > 30ms}
{resource.service.name="example-frontend" && duration > 200ms}
```

A trace from `/order/:sku` should show both `example-frontend` and
`example-backend` in its service list — that's the thing a single-service setup
cannot show.

## MySQL and the DB spans

`lib/db.rb` is the whole data layer: a connection per Puma thread, a lazy
idempotent schema bootstrap (`CREATE TABLE IF NOT EXISTS` plus an `INSERT ...
ON DUPLICATE KEY UPDATE` seed), and a `transaction` helper. Example-grade on
purpose — no real pooling, no migrations.

Spans arrive with `db.system=mysql`, `db.name`, `db.user` and an **obfuscated**
`db.statement` (`WHERE sku = ?`), so values never reach the tracing backend.

### Why trilogy, not mysql2

Both are auto-instrumented, but `mysql2` links `libmysqlclient`, which would mean
installing a MySQL client library in the runtime image too. Trilogy implements
the protocol itself, so the runtime stage stays clean. It does need OpenSSL
headers at **build** time:

```dockerfile
RUN apt-get install -y --no-install-recommends build-essential libssl-dev pkg-config
```

Without `libssl-dev` the native extension fails with
`fatal error: openssl/err.h: No such file or directory`. Nothing extra is needed
at runtime — Ruby already links `libssl3`.

### Two traps worth not re-learning

**Don't ping to check liveness.** `Trilogy#ping` is itself instrumented, so a
ping-before-use pattern added four `db.client` "ping" spans per request — pure
noise, plus a round trip. `lib/db.rb` keeps the cached connection and instead
reconnects once when a query raises `Trilogy::BaseConnectionError`.

**Bootstrap before `BEGIN`, never inside it.** DDL causes an implicit commit in
MySQL, so running the schema bootstrap inside a transaction silently breaks it.
`DB.transaction` calls `ensure_schema` first.

### Probes stay database-free

`/health` never touches MySQL, so a database blip doesn't get the pods killed and
restarted. `/ready` is the database-aware check (`SELECT 1`, 503 when down) and
is deliberately *not* wired to a probe — point a readiness probe at it only if
you want pods pulled from the Service when MySQL goes away.
