# Books

Helm chart for [BookOrbit](https://bookorbit.app), a self-hosted e-book management application. Great for a homelab running [MicroK8s](https://canonical.com/microk8s) + [MicroCeph](https://canonical.com/microk8s/docs/how-to-ceph) on a [Raspberry Pi](https://www.raspberrypi.com/products/) cluster.

By default it targets a Kubernetes cluster with the Ceph RBD storage class and Gateway API HTTPRoute ingress. It supports optional access from the internet via a [Cloudflare Tunnel](CLOUDFLARE.md).

## Table of Contents

- [Architecture](#architecture)
- [TL;DR](#tldr)
- [Prerequisites](#prerequisites)
- [Install](#install)
  - [First-time setup](#first-time-setup)
  - [Key config values:](#key-config-values)
  - [HPA](#hpa)
- [Publishing the chart](#publishing-the-chart)
  - [OCI registry (recommended)](#oci-registry-recommended)
    - [MicroK8s built-in registry](#microk8s-built-in-registry)
    - [GitHub Container Registry (GHCR)](#github-container-registry-ghcr)
  - [Classic HTTP chart repository (e.g. GitHub Pages)](#classic-http-chart-repository-eg-github-pages)
  - [Versioning](#versioning)
- [Data and backups](#data-and-backups)
  - [Backup](#backup)
- [Uninstall](#uninstall)
  - [Switching install source (e.g. local → MicroK8s registry → GHCR)](#switching-install-source-eg-local--microk8s-registry--ghcr)
  - [Cloudflare Tunnel cleanup](#cloudflare-tunnel-cleanup)
- [Health monitoring](#health-monitoring)
- [Rotating secrets](#rotating-secrets)
- [Glossary](#glossary)

## Architecture

![Arch diagram](books-architecture.drawio.svg)

## TL;DR

You can install the chart from source, publish to your own registry and install from there, or install from my registry:
```bash
bash scripts/gen-secrets.sh

helm upgrade --install bookorbit oci://ghcr.io/santisbon/charts/bookorbit \
  --version 0.1.0 \
  --namespace bookorbit --create-namespace \
  --set config.appUrl="https://books.internal" \
  --set 'httpRoute.hostnames[0]=books.internal' \
  --set persistence.books.storageClass=ceph-rbd \
  --set persistence.data.storageClass=ceph-rbd \
  --set postgres.persistence.storageClass=ceph-rbd \
  -f my-secrets.yaml
```

For access from the internet you can use a Cloudflare Tunnel and your own domain:
```sh
helm upgrade --install bookorbit oci://ghcr.io/santisbon/charts/bookorbit \
  --version 0.1.0 \
  --namespace bookorbit --create-namespace \
  --set config.appUrl=https://$APP_DOMAIN \
  --set 'httpRoute.hostnames[0]=books.internal' \
  --set persistence.books.storageClass=ceph-rbd \
  --set persistence.data.storageClass=ceph-rbd \
  --set postgres.persistence.storageClass=ceph-rbd \
  -f my-secrets.yaml
  --set cloudflare.enabled=true \
  --set cloudflare.tunnelId=$TUNNEL_ID \
  --set cloudflare.hostname=$APP_DOMAIN \
```

You can edit your `/etc/hosts` to point `books.internal` to a k8s node LAN IP for access within your local network. For access from the internet see `CLOUDFLARE.md`.

To create a backup:

```bash
cp backup-config.yaml.example backup-config.yaml
# fill in your S3 profile, bucket, and namespace, then:
bash scripts/backup.sh
```

## Prerequisites

- Helm 3
- A Kubernetes cluster with `gateway.networking.k8s.io` CRDs and a provisioned Gateway (the MicroK8s `ingress` addon satisfies both, providing a `traefik-gateway` Gateway in the `ingress` namespace)
- A StorageClass for the data PVCs (defaults to `ceph-rbd`; set `persistence.books.storageClass`, `persistence.data.storageClass`, and `postgres.persistence.storageClass` to use a different one)
- A kubeconfig pointing at the cluster. If you're running Helm from a machine that is not a cluster node, copy the kubeconfig from any node and replace the loopback address with the node's LAN IP or host name. If your cluster node user is `ubuntu` and a node is `node-01.local`:

  ```bash
  ssh ubuntu@node-01.local "microk8s config" \
    | sed 's/127.0.0.1/node-01.local/' \
    > ~/.kube/microk8s.yaml
  export KUBECONFIG=~/.kube/microk8s.yaml
  ```

  To avoid setting `KUBECONFIG` in every shell session, add the export to your `~/.bashrc` or `~/.zshrc`, or merge it into your existing `~/.kube/config`:

  ```bash
  KUBECONFIG=~/.kube/config:~/.kube/microk8s.yaml \
    kubectl config view --flatten > ~/.kube/config
  ```

## Install

Run the script to generate `my-secrets.yaml` with random credentials as shown in the TL;DR section.

**Install directly from this repository** when you have the source checked out locally and are deploying to a single cluster you manage yourself. This is the simplest path: no packaging or publishing step required, and changes to the chart take effect on the next Helm installation command.

Credentials must be provided at install time. Use a values file (keep it out of source control) rather than `--set` flags so they don't appear in your shell history.

This creates `my-secrets.yaml` (gitignored) with random values for `postgresPassword`, `jwtSecret`, and `setupBootstrapToken`. Re-running the script is a no-op if the file already exists, so existing credentials are never accidentally rotated.

Then install, setting `config.appUrl` and the HTTPRoute hostname via `--set`:

```bash
helm upgrade --install bookorbit ./charts/bookorbit \
  --namespace bookorbit --create-namespace \
  --set config.appUrl="http://books.internal" \
  --set 'httpRoute.hostnames[0]=books.internal' \
  -f my-secrets.yaml
```

**Publish the chart to a registry or repository** (see [Publishing the chart](#publishing-the-chart)) when you need to share it across multiple clusters, teams, or CI/CD pipelines, or when you want to pin deployments to a specific released version rather than whatever is currently on disk.

**Local network access by hostname:** Set a hostname and add a corresponding entry to `/etc/hosts` on any machine that needs to reach it. This allows running multiple apps on the same cluster. Each app gets its own hostname pointing to the same IP, and Traefik reads the `Host` header to route each request to the correct service. Any node's IP works since Traefik runs as a DaemonSet on every node.

```
# /etc/hosts
192.168.1.100  books.internal
```

**Exposing to the internet without port forwarding:** Use [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) (`cloudflared`), which opens an outbound-only connection from your network to Cloudflare's edge. No open inbound ports or router configuration needed. It's free, works with a custom domain you manage in Cloudflare, and handles HTTPS automatically. Run `cloudflared` as a service on the MicroK8s node pointing at the node's LAN IP and port, and set `httpRoute.hostnames` to your Cloudflare-managed domain. As an alternative, [ngrok](https://ngrok.com) is simpler to set up but the free tier assigns a random URL that changes every time the agent restarts.

### First-time setup

On first access BookOrbit will prompt for your `SETUP_BOOTSTRAP_TOKEN` to create an admin account. After setup is complete the token is no longer used.

### Key config values:

| Value | Default | Description |
|---|---|---|
| `image.tag` | `"1.12.0"` | BookOrbit image tag |
| `config.appUrl` | `""` | Required: full URL BookOrbit is served from |
| `config.nodeMaxOldSpaceSize` | `1024` | Node.js heap limit in MB; keep below container memory limit to prevent OOM on memory-constrained nodes |
| `process.puid` | `1000` | UID the BookOrbit process runs as |
| `process.pgid` | `1000` | GID the BookOrbit process runs as (also sets `fsGroup`) |
| `resources.limits.memory` | `1536Mi` | Container memory limit; prevents system OOM on memory-constrained nodes (e.g. 4 GiB Raspberry Pi) |
| `resources.requests.cpu` | `250m` | CPU request |
| `resources.requests.memory` | `512Mi` | Memory request |
| `httpRoute.enabled` | `true` | Create the Gateway API HTTPRoute for local network access |
| `httpRoute.parentRefs` | `traefik-gateway / ingress` | Gateway the HTTPRoute attaches to |
| `httpRoute.hostnames` | `[]` | Hostnames to match (empty = all) |
| `credentials.postgresPassword` | `""` | Required: PostgreSQL password |
| `credentials.jwtSecret` | `""` | Required: JWT signing secret |
| `credentials.setupBootstrapToken` | `""` | Required: one-time setup token |
| `credentials.existingSecret` | `""` | Use a pre-existing Secret instead |
| `postgres.enabled` | `true` | Deploy bundled PostgreSQL |
| `postgres.host` | `""` | External DB host (when `postgres.enabled=false`) |
| `persistence.books.storageClass` | `ceph-rbd` | StorageClass for the books PVC |
| `persistence.books.size` | `10Gi` | Books PVC size |
| `persistence.data.storageClass` | `ceph-rbd` | StorageClass for the data PVC |
| `persistence.data.size` | `1Gi` | Data PVC size |
| `postgres.persistence.storageClass` | `ceph-rbd` | StorageClass for the PostgreSQL PVC |
| `postgres.persistence.size` | `5Gi` | PostgreSQL PVC size |
| `cloudflare.enabled` | `false` | Deploy the cloudflared Deployment for internet access |
| `cloudflare.tunnelId` | `""` | Required when enabled: tunnel ID from `cloudflared tunnel create` |
| `cloudflare.hostname` | `""` | Required when enabled: public hostname, e.g. `books.yourdomain.com` |
| `cloudflare.credentialsSecret` | `"cloudflared-credentials"` | Secret containing `credentials.json` for the tunnel |
| `cloudflare.image.tag` | `"2026.6.1"` | cloudflared image tag |


### HPA

HPA is not recommended for this setup. The workload is low and predictable (personal book tracker), so there are no traffic spikes to react to. In the case of a Raspberry Pi cluster, the nodes are memory-constrained. An unexpected scale-out adds another ~1.5 GiB pod and could destabilize the node it lands on. PostgreSQL is the real bottleneck anyway, so scaling BookOrbit replicas doesn't help when the single DB instance is under load. If you want crash resilience, a static `replicas: 2` with pod anti-affinity is simpler and more predictable than HPA on this hardware.

## Publishing the chart

Helm supports two publishing models: **OCI registries** (the modern path) and **classic HTTP chart repositories**. Both are shown below.

All install commands below follow the same pattern as the local install: run the script to generate `my-secrets.yaml` with random credentials first, then supply credentials and `appUrl` at install time.

### OCI registry (recommended)

OCI lets you push charts to any container registry, including the MicroK8s built-in registry.

```bash
helm package charts/bookorbit
```

#### MicroK8s built-in registry

The MicroK8s registry addon exposes an unauthenticated registry on port 32000 on every node. Use any node's LAN IP or host name to reach it from your laptop.

```bash
# Push (Helm 3.8+)
helm push bookorbit-*.tgz oci://node-01.local:32000/charts --plain-http
```

View published charts:

```bash
# List all repositories in the registry
curl -s http://node-01.local:32000/v2/_catalog | jq

# List available versions of the chart
curl -s http://node-01.local:32000/v2/charts/bookorbit/tags/list | jq

# Inspect chart metadata for a specific version
helm show chart oci://node-01.local:32000/charts/bookorbit --version 0.1.0 --plain-http
```

Install directly from it:

*To make BookOrbit available from the internet, see `CLOUDFLARE.md`.*
```bash
helm upgrade --install bookorbit oci://node-01.local:32000/charts/bookorbit \
  --version 0.1.0 --plain-http \
  --namespace bookorbit --create-namespace \
  --set config.appUrl="http://books.internal" \
  --set 'httpRoute.hostnames[0]=books.internal' \
  -f my-secrets.yaml
```

#### GitHub Container Registry (GHCR)

**Using the `gh` CLI** (recommended; uses credentials from `gh auth login`, no token management needed):

`gh auth login` does not request `write:packages` by default. Add it once before pushing:

```bash
gh auth refresh -s write:packages
```

```bash
gh auth token | helm registry login ghcr.io --username <github-user> --password-stdin

helm push bookorbit-*.tgz oci://ghcr.io/<github-user>/charts
```

GHCR defaults new packages to private. `helm push` uses the OCI protocol which has no visibility concept, so there is no way to set it at push time. Make the package public once after the first push. It stays public for all subsequent pushes to the same package. Go to **github.com → your profile → Packages → charts/bookorbit → Package settings → Change visibility → Public**.

View published charts:

```bash
gh api /user/packages/container/charts%2Fbookorbit/versions --jq '.[].metadata.container.tags'
```

**Using a personal access token (PAT):** Create one at **GitHub → Settings → Developer settings → Personal access tokens** with `write:packages` to push and `read:packages` to query, then set it in your shell:

```bash
export GITHUB_TOKEN=ghp_...
```

```bash
echo $GITHUB_TOKEN | helm registry login ghcr.io --username <github-user> --password-stdin

helm push bookorbit-*.tgz oci://ghcr.io/<github-user>/charts
```

View published charts:

```bash
curl -s -H "Authorization: Bearer $GITHUB_TOKEN" \
  "https://api.github.com/user/packages/container/charts%2Fbookorbit/versions" \
  | jq '.[].metadata.container.tags'
```

Inspect chart metadata for a specific version (works with either auth method):

```bash
helm show chart oci://ghcr.io/<github-user>/charts/bookorbit --version 0.1.0
```

Install:

*To make BookOrbit available from the internet, see `CLOUDFLARE.md`.*
```bash
helm upgrade --install bookorbit oci://ghcr.io/<github-user>/charts/bookorbit \
  --version 0.1.0 \
  --namespace bookorbit --create-namespace \
  --set config.appUrl="http://books.internal" \
  --set 'httpRoute.hostnames[0]=books.internal' \
  -f my-secrets.yaml
```

### Classic HTTP chart repository (e.g. GitHub Pages)

A classic repo is a static directory containing packaged `.tgz` files and an `index.yaml` manifest, served over HTTP.

1. **Package the chart:**

   ```bash
   helm package charts/bookorbit --destination .deploy/
   ```

2. **Generate or update the index:**

   ```bash
   # First publish: build the index from scratch
   helm repo index .deploy/ --url https://<github-user>.github.io/<repo>

   # Subsequent publishes: merge into an existing hosted index
   helm repo index .deploy/ --url https://<github-user>.github.io/<repo> \
     --merge <(curl -s https://<github-user>.github.io/<repo>/index.yaml)
   ```

3. **Publish** the contents of `.deploy/` to the `gh-pages` branch (or whichever branch GitHub Pages serves from).

4. **Add the repo and install:**

   ```bash
   helm repo add books https://<github-user>.github.io/<repo>
   helm repo update
   helm upgrade --install bookorbit books/bookorbit \
     --namespace bookorbit --create-namespace \
     --set config.appUrl="http://books.internal" \
     --set 'httpRoute.hostnames[0]=books.internal' \
     -f my-secrets.yaml
   ```

5. **View published charts:**

   ```bash
   helm search repo books
   ```

   Or inspect the raw index directly:

   ```bash
   curl -s https://<github-user>.github.io/<repo>/index.yaml
   ```

### Versioning

Bump `version` in `charts/bookorbit/Chart.yaml` before every publish. `appVersion` tracks the upstream BookOrbit release and is independent of the chart version.

## Data and backups

The chart provisions three PersistentVolumeClaims:

| PVC | Mount | Contents |
|---|---|---|
| `books` | `/books` | Book files managed by the library |
| `data` | `/data` | Book covers, author images, book-dock inbox |
| `postgres` | `/var/lib/postgresql/data` | PostgreSQL cluster (all structured data) |

**`/books`** holds the actual book files. BookOrbit organises uploads into `Author/Title` subdirectories here.

**`/data`** holds derived assets written by the app:
- `covers/<bookId>/` — cover images extracted from books (`cover_extracted.*`) or manually uploaded by the user (`cover_custom.*`), plus a `thumbnail.jpg`
- `authors/<authorId>/` — author photos fetched from the internet, plus a `thumbnail.jpg`
- `book-dock/` — drop folder for books to be auto-imported (override with `BOOK_DOCK_PATH`)

**`/var/lib/postgresql/data`** holds the entire PostgreSQL cluster: books, libraries, reading history, series, users, auth tokens, email config, and all other structured data.

### Backup

```sh
cp backup-config.yaml.example backup-config.yaml
```
and fill in your profile, bucket, and namespace.

Then run the backup script to stream all three to an S3-compatible RGW bucket. Credentials and endpoint are read from the named profile in `~/.aws/config` and `~/.aws/credentials`.
```bash
bash scripts/backup.sh
```

Backups are written to `s3://<bucket>/bookorbit/<timestamp>/` as three gzip-compressed archives: `postgres.sql.gz`, `books.tar.gz`, and `data.tar.gz`.

To list all backups or inspect a specific one:

```bash
# List all backup runs
aws s3 ls s3://bookorbit-backups/bookorbit/ --profile <profile>

# List the contents of a specific backup
aws s3 ls s3://bookorbit-backups/bookorbit/20260616T175400Z/ --profile <profile>
```

**Consistency note:** The three archives are captured at different points in time. `pg_dump` is safe while the database is running (it takes a consistent snapshot via MVCC), but `tar` is not snapshot-aware. Files being written mid-backup may be captured in a partially-written state. More critically, if BookOrbit writes a new book to `/books` and its database record between the `pg_dump` and the `/books` tar, a restore would have the file but no record (or vice versa). For a home setup this is an acceptable trade-off; a library re-scan after restore will reconcile any mismatches. For a fully consistent backup, scale the deployment to zero first, back up, then scale back up (at the cost of downtime):

```bash
kubectl scale deploy -n bookorbit --replicas=0 --all
bash scripts/backup.sh
kubectl scale deploy -n bookorbit --replicas=1 --all
```

**Restore priority:** PostgreSQL is the only irreplaceable store; restore it first. `/books` can be restored from originals if you have them. Most of `/data` (extracted covers, author photos) can be regenerated by re-scanning the library; the only non-recoverable part is `cover_custom.*` files (covers manually uploaded through the UI).

## Uninstall

```bash
helm uninstall bookorbit --namespace bookorbit
```

This removes all Kubernetes resources created by the chart, **including the three PVCs**. Your books, covers, and PostgreSQL data will be deleted. Back up first if you need to keep that data.

### Switching install source (e.g. local → MicroK8s registry → GHCR)

You do not need to uninstall to switch where the chart is installed from. `helm upgrade --install` with a new source updates the release in-place. PVCs and data are untouched.

### Cloudflare Tunnel cleanup

The credentials Secret is created outside Helm and must be deleted manually:

```bash
kubectl delete secret cloudflared-credentials --namespace bookorbit
```

Then delete the tunnel and its DNS route from Cloudflare. Run these after the Helm release is uninstalled (no active connections):

```bash
cloudflared tunnel delete bookorbit
```

This removes the tunnel and its associated DNS CNAME. If the delete fails because the route is still registered, remove it first from the [Cloudflare dashboard](https://dash.cloudflare.com) under **DNS → Records**, then retry.

## Health monitoring

The BookOrbit health endpoint is `/api/v1/health` so if you've deployed it to `https://books.yourdomain.com` you should point your monitoring solution to `https://books.yourdomain.com/api/v1/health`.

If you don't already have a health monitoring solution in place I recommend Uptime Kuma which you can easily deploy with https://github.com/santisbon/uptime.


If you're using the Cloudflare Tunnel with *Bot Fight Mode* enabled it will interfere with monitoring products like Uptime Kuma. If both BookOrbit and Uptime Kuma are in the same k8s cluster you can monitor the service directly, bypassing Cloudflare.

In that case use the fully-qualified cluster DNS name `http://bookorbit.bookorbit.svc.cluster.local:3000/api/v1/health`

Breakdown:
- `bookorbit` - service name
- `bookorbit` - namespace
- `svc.cluster.local` - standard K8s DNS suffix
- `3000` - port from the ClusterIP service
- `/api/v1/health` - path from the Helm chart liveness/readiness probes

## Rotating secrets

`my-secrets.yaml` (generated by `scripts/gen-secrets.sh`) is the source of truth for `credentials.postgresPassword`, which flows into the `bookorbit` k8s Secret's `postgres-password` key. Both the `bookorbit` app pod and the `bookorbit-postgres` pod read that same secret key.

Regenerating `my-secrets.yaml` and redeploying updates the k8s Secret and the app's env var, but **it does not change the password actually stored inside Postgres**. The `POSTGRES_PASSWORD` env var on the Postgres container only takes effect the first time its data directory is initialized (i.e. `initdb`, on a fresh PVC). Once the PVC has data, changing that env var does nothing. Postgres keeps using whatever password it was initialized with.

So after rotating the Postgres password, the app pod will crash-loop with:
```
error: password authentication failed for user "bookorbit"
...
code: '28P01', routine: 'auth_failed'
```

**Do not trust a `psql -h localhost` test from inside the Postgres pod as proof the password is correct**. `pg_hba.conf` sets `trust` for loopback connections, so local connections succeed regardless of password. Test over the real network path instead:
```bash
kubectl exec -n bookorbit deploy/bookorbit-postgres -- env PGPASSWORD='<password-from-secret>' \
  psql -U bookorbit -d bookorbit -h bookorbit-postgres -p 5432 -c '\conninfo'
```
A failure here (not a `localhost` test) confirms the mismatch.

**Fix — sync Postgres's actual role password to the new secret value:**
```bash
kubectl exec -n bookorbit deploy/bookorbit-postgres -- \
  psql -U bookorbit -d bookorbit -h localhost -c "ALTER USER bookorbit WITH PASSWORD '<password-from-secret>';"
```
Then force the app pod to retry immediately instead of waiting out its CrashLoopBackOff timer. The pod is managed by a Deployment/ReplicaSet, so deleting it doesn't remove the workload. The controller immediately creates a fresh replacement pod that picks up the corrected credentials:
```bash
kubectl delete pod -n bookorbit -l app.kubernetes.io/name=bookorbit
```

## Glossary

- **Bot Fight Mode** — A Cloudflare security feature that blocks automated traffic; can interfere with external uptime monitors like Uptime Kuma.
- **Ceph RBD** — RADOS Block Device, a Ceph storage backend that provides block-level Kubernetes PersistentVolumes (the default StorageClass here).
- **CRD** — Custom Resource Definition, extends the Kubernetes API with new resource types (here, the Gateway API's `HTTPRoute`).
- **DaemonSet** — A Kubernetes workload type that runs exactly one pod on every (matching) node. Traefik runs this way, which is why any node's IP works for routing.
- **fsGroup** — A Kubernetes pod security setting that sets the group ownership of mounted volumes; set via `process.pgid`.
- **Gateway API** — The Kubernetes API for configuring traffic routing (`Gateway`, `HTTPRoute`), the modern successor to Ingress.
- **`gh` (CLI)** — GitHub's official command-line tool, used here to authenticate and publish to GHCR.
- **GHCR** — GitHub Container Registry, one option for hosting the packaged Helm chart as an OCI artifact.
- **GID** — Group ID, the numeric Linux group identifier a process runs as.
- **HPA** — Horizontal Pod Autoscaler, a Kubernetes controller that scales replica count based on load. Not recommended for this chart.
- **HTTPRoute** — A Gateway API resource that defines HTTP routing rules from a Gateway to a Service.
- **Ingress** — The general term (and older Kubernetes API) for routing external traffic into a cluster; here, the MicroK8s `ingress` addon provisions the Gateway.
- **`jq`** — A command-line JSON processor, used here to parse `cloudflared` and GitHub API output.
- **JWT** — JSON Web Token, used here to sign BookOrbit's authentication tokens (`credentials.jwtSecret`).
- **K8s** — Shorthand for Kubernetes.
- **kubeconfig / `KUBECONFIG`** — The file (and environment variable pointing to it) containing credentials and connection info for a Kubernetes cluster.
- **`kubectl`** — The Kubernetes command-line tool.
- **LAN** — Local Area Network.
- **MicroCeph** — Canonical's lightweight Ceph distribution, providing the cluster's storage backend.
- **MicroK8s** — Canonical's lightweight Kubernetes distribution.
- **MVCC** — Multiversion Concurrency Control, PostgreSQL's mechanism for taking a consistent snapshot (`pg_dump`) without locking out concurrent writers.
- **ngrok** — A third-party tunneling service, mentioned as a simpler but less stable alternative to Cloudflare Tunnel.
- **OCI (registry)** — Open Container Initiative image format/protocol; Helm charts can be pushed to and pulled from an OCI-compliant registry.
- **OOM** — Out Of Memory. When a container exceeds its memory limit, Kubernetes kills it.
- **PAT** — Personal Access Token, used to authenticate to GHCR as an alternative to the `gh` CLI.
- **`pg_dump`** — PostgreSQL's built-in logical backup utility, used by the backup script.
- **PVC** — PersistentVolumeClaim, a Kubernetes request for storage bound to a StorageClass. This chart provisions three.
- **RGW** — RADOS Gateway, Ceph's S3-compatible object storage interface, used as the backup destination.
- **S3** — Amazon's Simple Storage Service API, and by extension any S3-compatible object store (like Ceph RGW).
- **StorageClass** — A Kubernetes resource that defines how PersistentVolumes are dynamically provisioned (e.g. `ceph-rbd`).
- **TLS / HTTPS** — Transport Layer Security, the encryption protocol behind HTTPS. Cloudflare provides this automatically for the tunnel path.
- **UID** — User ID, the numeric Linux user identifier a process runs as (`process.puid`).
- **Uptime Kuma** — An open-source, self-hosted uptime monitoring tool, suggested here for health checks.
