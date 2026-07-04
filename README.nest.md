# NestJS + TypeORM migration — deployment & cutover (Phase N)

The 24 migrated services run as idiomatic NestJS + TypeORM apps (`apps/services-nest/<svc>/`),
each owning its own Postgres schema. In production they are deployed **alongside** their legacy
split-runtime counterparts (`services/<svc>.yaml`) under a distinct `<svc>-nest` name on the same
port, and cut over **one at a time** behind the existing strangler switch — the gateway's
`<SVC>_SERVICE_URL` in `etraffica-service-routing`.

Everything here is **prep** — nothing changes the running system until you repoint a
`<SVC>_SERVICE_URL` and restart the gateway (the per-service cutover, gated on the Issue #6 soak).

## Artifacts

| File | What |
|---|---|
| `services-nest/<svc>-nest.yaml` (×24) | Deployment + ClusterIP Service for each nest service. Same per-service image, `command` overridden to `npm run start:<svc>-nest`; extra env wires the read-model bridge / identity / broker. **Generated** by `tools/generate-nest-manifests.js`. |
| `workers-nest.yaml` | `worker-rmq-relay` Deployment — the event-relay consumer (catch-all queue → apply). AMQP-gated (safe to deploy pre-cutover). |
| `jobs/nest-db-migrate.yaml` | One-shot Job running every `seed:<svc>-service-nest` (TypeORM migrations + seeds). Run before the nest Deployments. |
| `service-routing-configmap.nest.yaml` | The **cutover overlay** — repoints every `<SVC>_SERVICE_URL` to `<svc>-nest`. **Generated.** Do NOT apply wholesale; it documents the target state. |

Regenerate after any service/port change: `node tools/generate-nest-manifests.js`
(CI drift guard: `node tools/generate-nest-manifests.js --check`).

## Prerequisites

- The migrated code is already in the `0680/etraffica.v2.<svc>` images (they carry the whole repo
  + `typeorm`/`@nestjs/typeorm` deps); the `-nest` Deployments just override the start command, so
  **no new images are required**. Pin real `DD.MM.YY.NN` tags in place of `:latest` before applying.
- `etraffica-secrets` must carry `DATABASE_URL` (Postgres), `RABBITMQ_URL` (→ `AMQP_URL`), and
  `INTERNAL_SERVICE_TOKEN`. `etraffica-config` already sets `PERSISTENCE_MODE=postgres`.

## Roll-out order (stand up, no cutover yet)

```bash
# 1. provision every nest service's schema + tables + seed rows (idempotent)
kubectl apply -f jobs/nest-db-migrate.yaml
kubectl -n etraffica wait --for=condition=complete job/nest-db-migrate --timeout=600s

# 2. stand up the nest runtimes (coexist with legacy; nothing routes to them yet)
kubectl apply -f services-nest/

# 3. deploy the event-relay worker (AMQP-gated; consumes the catch-all queue)
kubectl apply -f workers-nest.yaml

# 4. sanity-check readiness
kubectl -n etraffica get pods -l variant=nest
```

## Per-service cutover (the strangler flip — one service, gated on the soak)

```bash
SVC=enforcement-service ; ENV=ENFORCEMENT_SERVICE_URL ; PORT=4319
# point the gateway at the nest runtime for this ONE service
kubectl -n etraffica patch configmap etraffica-service-routing \
  --type merge -p "{\"data\":{\"$ENV\":\"http://$SVC-nest:$PORT\"}}"
kubectl -n etraffica rollout restart deployment/api-gateway   # envFrom is NOT hot-reloaded

# soak 24h: watch golden parity + 0 pending outbox. On ANY drift, roll back:
kubectl -n etraffica patch configmap etraffica-service-routing \
  --type merge -p "{\"data\":{\"$ENV\":\"http://$SVC:$PORT\"}}"
kubectl -n etraffica rollout restart deployment/api-gateway   # RTO < 60s
```

`service-routing-configmap.nest.yaml` lists the target URL for every service. Apply it in full
only after **every** service has individually soaked green; then retire the legacy `services/*.yaml`
Deployments (Phase-N cleanup) once the relay has been idle 7 days.

## Notes

- Probes are `tcpSocket` (the nest bootstrap does not guarantee an HTTP health route on every
  service). Swap to `httpGet /api/v1/health/ready` for services that expose it.
- The relay worker is a **transition bridge**: once a service is flipped, its own `@EventPattern`
  consumer will handle its events and the relay's handler for those becomes a no-op — the relay is
  decommissioned in Phase-N cleanup.
