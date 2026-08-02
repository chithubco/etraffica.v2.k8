# NestJS + TypeORM backend — deployment reference

The backend is 24 idiomatic NestJS + TypeORM services (`apps/services-nest/<svc>/`), each owning its
own Postgres schema. **The strangler cutover is complete**: the legacy split embedded runtimes
(formerly `services/<svc>.yaml` + `apps/services/<svc>-service` in the app repo) have been **deleted**.
The gateway proxies every `/api/v1/*` route family to the owning `<svc>-nest` Service via its
`<SVC>_SERVICE_URL` in `etraffica-service-routing` (`service-routing-configmap.yaml`). `legacy-parity`
has no nest twin — its URL is unset, so the gateway embeds it in-process to serve `/api/v1/legacy`.

## Artifacts

| File | What |
|---|---|
| `services-nest/<svc>-nest.yaml` (×24) | Deployment + ClusterIP Service for each nest service. Same per-service image, `command` runs `npm run start:<svc>-nest`; extra env wires the read-model bridge / identity / broker. **Generated** by `tools/generate-nest-manifests.js`. |
| `service-routing-configmap.yaml` | `etraffica-service-routing` — every `<SVC>_SERVICE_URL` → the `<svc>-nest` Service. **Generated** (consumed only by the gateway). |
| `workers-nest.yaml` | `worker-rmq-relay` Deployment — the event-relay consumer (catch-all queue → apply into owning collections). AMQP-gated. |
| `jobs/nest-db-migrate.yaml` | One-shot Job running every `seed:<svc>-service-nest` (TypeORM migrations + seeds). Run before the nest Deployments. |

Regenerate after any service/port change: `node tools/generate-nest-manifests.js`
(CI drift guard: `node tools/generate-nest-manifests.js --check`).

## Prerequisites

- The backend code is in the `0680/etraffica.v2.<svc>` images (they carry the whole repo +
  `typeorm`/`@nestjs/typeorm` deps); the images bake `start:<svc>-service-nest` as the default CMD and
  the `-nest` Deployments also set it explicitly. Pin real `DD.MM.YY.NN` tags in place of `:latest`
  before applying.
- `etraffica-secrets` must carry `DATABASE_URL` (Postgres), `RABBITMQ_URL` (→ `AMQP_URL`), and
  `INTERNAL_SERVICE_TOKEN`. `etraffica-config` already sets `PERSISTENCE_MODE=postgres`.

## Roll-out order

```bash
# 1. provision every nest service's schema + tables + seed rows (idempotent)
kubectl apply -f jobs/nest-db-migrate.yaml
kubectl -n etraffica wait --for=condition=complete job/nest-db-migrate --timeout=600s

# 2. routing (points the gateway at the -nest Services) + the nest runtimes
kubectl apply -f service-routing-configmap.yaml
kubectl apply -f services-nest/

# 3. the event-relay worker (AMQP-gated; consumes the catch-all queue)
kubectl apply -f workers-nest.yaml

# 4. roll the gateway so it picks up the routing (envFrom is NOT hot-reloaded)
kubectl -n etraffica rollout restart deployment/api-gateway

# 5. sanity-check readiness
kubectl -n etraffica get pods -l variant=nest
```

To repoint one service (e.g. to a new image or a temporary instance), patch its `<SVC>_SERVICE_URL`
in `etraffica-service-routing` and `rollout restart deployment/api-gateway`.

## Notes

- Probes are `tcpSocket` (the nest bootstrap does not guarantee an HTTP health route on every
  service). Swap to `httpGet /api/v1/health/ready` for services that expose it.
- The `worker-rmq-relay` worker makes the nest services' dropped foreign writes durable (a producer
  emits a domain event; the relay applies it into the owning collection). It stays until each service
  grows its own `@EventPattern` consumer, at which point the relay's handler for that event is a no-op.
