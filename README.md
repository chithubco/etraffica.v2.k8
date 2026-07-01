# eTraffica v2 — Kubernetes manifests

Plain-YAML Kubernetes manifests for the **eTraffica v2** platform, deployed as **full split
microservices**: the API gateway + 24 routed backend services + an optional legacy `core-service`
+ 5 workers + 4 frontends, each as its own Deployment/Service in the `etraffica` namespace, fronted
by an NGINX Ingress with cert-manager TLS.

Images come from Docker Hub (`0680/*`) and are pinned to dated tags (`DD.MM.YY.NN`). The current
pins are **`30.06.26.01`** for the `etraffica.v2.*` backend services + api-gateway (including the
`feedback` / `learning` / `notification` services) and **`29.06.26.01`** for the frontends, workers,
and legacy `core-service` (their newest build).

> Modelled on the conventions of the `chithubco/emudee.k8` sample repo.

## Layout

```
namespace.yaml                   Namespace: etraffica
configmap.yaml                   etraffica-config           — shared non-secret env (all pods)
service-routing-configmap.yaml   etraffica-service-routing  — 24 *_SERVICE_URL (gateway only)
secrets.yaml.example             etraffica-secrets template — copy to secrets.yaml, fill in
api-gateway.yaml                 Deployment + Service (port 4300)
services/<name>.yaml             one Deployment + ClusterIP Service per backend service
workers.yaml                     5 worker Deployments (no Service, no probe)
frontends/<name>.yaml            web (3000) + admin-web / violator-web / product-website (80)
cert-manager-issuer.yaml         letsencrypt-prod ClusterIssuer (HTTP-01 via nginx)
ingress.yaml                     NGINX Ingress + cert-manager TLS (host-based routing)
```

## How the split works

The gateway image is a unified runtime that *can* embed every service in-process. The
`etraffica-service-routing` ConfigMap sets one `<SERVICE>_SERVICE_URL` per service (e.g.
`IDENTITY_SERVICE_URL=http://identity-service:4302`). When these are present the gateway **proxies**
`/api/v1/*` to the matching ClusterIP Service instead of embedding it. If you remove a routing entry,
the gateway will silently run that service itself again.

Each backend service binds a **fixed port (4302–4326)** and exposes `/api/v1/health/live` and
`/api/v1/health/ready` (used for the probes). Workers are pure RabbitMQ consumers — no port.

## Ingress / TLS routing

`ingress.yaml` routes by host (replace `etraffica.example.com` with your real domain):

| Host | Service | Port | Serves |
|---|---|---|---|
| `api.<domain>` | api-gateway | 4300 | REST API (+ proxies `/api/v1/*`) |
| `app.<domain>` | web | 3000 | Next.js app (`/admin`, `/violator`, `/product`) |
| `admin.<domain>` | admin-web | 80 | static admin portal |
| `violator.<domain>` | violator-web | 80 | static violator portal |
| `<domain>` (apex) | product-website | 80 | marketing site |

TLS is issued automatically into the `etraffica-tls` secret by cert-manager via the
`letsencrypt-prod` ClusterIssuer (HTTP-01 challenge solved through the NGINX controller).

## Prerequisites

- A Kubernetes cluster and `kubectl` pointed at it.
- An **NGINX ingress controller** installed (provides `ingressClassName: nginx` and the external
  LoadBalancer IP). e.g.
  `kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml`
- **cert-manager** installed (for TLS issuance):
  `kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml`
- **DNS**: point each host (`api.`, `app.`, `admin.`, `violator.`, apex) at the ingress controller's
  external IP. cert-manager won't issue the cert until DNS resolves to the cluster.
- A shared **persistence backend** reachable from the cluster. Split mode needs a real datastore —
  the local `file` mode writes a per-pod JSON file and breaks across pods. `configmap.yaml` defaults
  `PERSISTENCE_MODE=postgres`; supply `POSTGRES_URL` / `DATABASE_URL` (and `MONGODB_URL`,
  `REDIS_URL`, `RABBITMQ_URL`) in `secrets.yaml`.
- `regcred` image pull secret **only if the `0680/*` repositories are private** (they currently pull
  anonymously). Create it with:
  ```bash
  kubectl create secret docker-registry regcred \
    --docker-server=https://index.docker.io/v1/ \
    --docker-username=<dockerhub-user> --docker-password=<token> \
    -n etraffica
  ```
  If the repos are public you can ignore this — the `imagePullSecrets: regcred` reference is harmless
  when the secret is absent.

## Deploy

```bash
# 1. Namespace
kubectl apply -f namespace.yaml

# 2. Secrets — fill in real values first
cp secrets.yaml.example secrets.yaml
#    edit secrets.yaml, replacing every CHANGE_ME
kubectl apply -f secrets.yaml

# 3. Config
kubectl apply -f configmap.yaml -f service-routing-configmap.yaml

# 4. Backend services, gateway, workers, frontends
kubectl apply -f services/
kubectl apply -f api-gateway.yaml
kubectl apply -f workers.yaml
kubectl apply -f frontends/

# 5. TLS issuer + ingress (after editing ingress.yaml hosts + DNS)
kubectl apply -f cert-manager-issuer.yaml
kubectl apply -f ingress.yaml
```

Or apply everything at once (after creating `secrets.yaml` and editing `ingress.yaml`):

```bash
kubectl apply -f . -R
```

> `core-service` is optional (legacy composite). Skip it with
> `kubectl delete -f services/core-service.yaml` or simply don't apply that file.

## Verify

```bash
kubectl get pods -n etraffica
kubectl get svc  -n etraffica
kubectl get ingress -n etraffica
# Certificate issuance:
kubectl get certificate -n etraffica
kubectl describe certificate etraffica-tls -n etraffica
# Gateway should resolve external service URLs (not embed):
kubectl logs -l app=api-gateway -n etraffica --tail=100
# Smoke test the gateway directly (no ingress needed):
kubectl port-forward svc/api-gateway 4300:4300 -n etraffica
curl -s http://localhost:4300/api/v1/health/ready
curl -s http://localhost:4300/api/v1/roles      # routed -> identity-service
# Through the ingress once DNS + TLS are live:
curl -s https://api.<domain>/api/v1/health/ready
```

## Bump the image tag

The CI auto-tags images `DD.MM.YY.NN` (Africa/Lagos). Find the latest tag for a repo:

```bash
curl -s "https://hub.docker.com/v2/repositories/0680/etraffica.v2.api-gateway/tags/?page_size=5&ordering=last_updated" \
  | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{console.log(JSON.parse(d).results.map(t=>t.name).join('\n'))})"
```

Update the dated tags in the manifests to the new tag, then:

```bash
kubectl apply -f services/ -f api-gateway.yaml -f workers.yaml -f frontends/
kubectl rollout status deployment/api-gateway -n etraffica --timeout=180s
```

To pick up changed secrets/config without a tag change:

```bash
kubectl rollout restart deployment -n etraffica
```

## Image reference

| Component | Image | Port |
|---|---|---|
| api-gateway | `0680/etraffica.v2.api-gateway` | 4300 |
| 21 routed services | `0680/etraffica.v2.<name>` | 4302–4322 |
| core-service (legacy, optional) | `0680/etraffica.api.core` | 4323 |
| worker-outbox / -notifications / -payments / -workflow / -media | `0680/etraffica.worker.<x>` | — |
| web | `0680/etraffica.web` | 3000 |
| admin-web / violator-web / product-website | `0680/etraffica.<name>` | 80 |
