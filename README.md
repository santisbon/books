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
  - [Restore](#restore)
- [Upgrading](#upgrading)
  - [Routine upgrade](#routine-upgrade)
  - [Before upgrading, check the upstream release](#before-upgrading-check-the-upstream-release)
  - [PostgreSQL major version upgrade](#postgresql-major-version-upgrade)
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

VERSION= # choose a version to deploy

helm upgrade --install bookorbit oci://ghcr.io/santisbon/charts/bookorbit \
  --version $VERSION \
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
  --version $VERSION \
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

- Helm
- A Kubernetes cluster with `gateway.networking.k8s.io` CRDs and a provisioned Gateway (the MicroK8s `ingress` addon satisfies both, providing a `traefik-gateway` Gateway in the `ingress` namespace)
- A StorageClass for the data PVCs (defaults to `ceph-rbd`; set `persistence.books.storageClass`, `persistence.data.storageClass`, and `postgres.persistence.storageClass` to use a different one)
- A kubeconfig pointing at the cluster. If you're running Helm from a machine that is not a cluster node, copy the kubeconfig from any node and replace the loopback address with the node's LAN IP or host name. If your cluster node user is `ubuntu` and a node is `node-01.local`:

  ```bash
  ssh ubuntu@node-01.local "microk8s config" \
    | sed 's/127.0.0.1/node-01.local/' \
    > ~/.kube/microk8s.yaml
  export KUBECONFIG=~/.kube/microk8s.yaml
  ```

  To avoid setting `KUBECONFIG` in every shell session, add the export to your `~/.bashrc` or `~/.zshrc`, or merge it into your existing `~/.kube/config`. Don't redirect the merged output directly back into `~/.kube/config`. The shell truncates that file to set up the redirect before `kubectl` runs, so `kubectl` ends up reading an already-empty file for that half of the merge and silently drops everything that was in it. Write to a temp file first, then move it into place once the merge is done:

  ```bash
  KUBECONFIG=~/.kube/config:~/.kube/microk8s.yaml \
    kubectl config view --flatten > /tmp/kubeconfig-merged.yaml \
    && mv /tmp/kubeconfig-merged.yaml ~/.kube/config
  ```

  If instead you reach the cluster through a wrapper that runs `kubectl` and `helm` on a node over SSH (so there is no workstation kubeconfig at all), substitute that wrapper for `kubectl` and `helm` in every command below. `scripts/backup.sh` has a `KUBECTL` environment variable for this. Two consequences worth knowing: files referenced by `-f` must be readable *on the node running the command*, not on your workstation, so install from an OCI reference with `--reset-then-reuse-values` rather than a local chart directory and a local `-f my-secrets.yaml`; and any command piping local data in (`gunzip -c ... | kubectl exec -i`) only works if the wrapper passes stdin through.

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
| `image.tag` | `"2.3.0"` | BookOrbit image tag |
| `replicaCount` | `1` | App replicas. Only `0` or `1` are meaningful; set `0` to hold the app down across a `helm upgrade` |
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
| `postgres.image.tag` | `pg18` | pgvector image tag. Changing the major version requires a dump and restore, see [Upgrading](#postgresql-major-version-upgrade) |
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

HPA is not recommended for this setup, and with the chart's default storage it cannot work at all.

The blocker is the volumes. The `books` and `data` PVCs are ReadWriteOnce, which binds each volume to a single node. A second app replica scheduled onto another node stays `Pending` on `FailedAttachVolume` forever. This is also why the Deployment uses the `Recreate` strategy: even a rolling update would deadlock, with the new pod waiting for a volume the old pod has not released yet. Pod anti-affinity makes this worse rather than better, since it forces the second replica onto a different node, guaranteeing the failure. Genuine multi-replica operation would need ReadWriteMany volumes (CephFS rather than Ceph RBD) *and* an application that tolerates concurrent instances sharing a library directory, which BookOrbit does not claim to.

The workload does not call for it either. It is low and predictable (personal book tracker), so there are no traffic spikes to react to, and PostgreSQL is the real bottleneck anyway, so adding app replicas would not help when the single DB instance is under load. On memory-constrained nodes (e.g. a 4 GiB Raspberry Pi) an unexpected scale-out would add another ~1.5 GiB pod and could destabilize the node it lands on.

For crash resilience, rely on the Deployment controller: if a node fails, the single replica is rescheduled and the RWO volume reattaches on the new node. That is a restart rather than a failover, so expect brief downtime instead of continuous availability. Use `replicaCount` as a `0`/`1` switch for maintenance, not as a scaling knob.

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
helm show chart oci://node-01.local:32000/charts/bookorbit --version $VERSION --plain-http
```

Install directly from it:

*To make BookOrbit available from the internet, see `CLOUDFLARE.md`.*
```bash
helm upgrade --install bookorbit oci://node-01.local:32000/charts/bookorbit \
  --version $VERSION --plain-http \
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
helm show chart oci://ghcr.io/<github-user>/charts/bookorbit --version $VERSION
```

Install:

*To make BookOrbit available from the internet, see `CLOUDFLARE.md`.*
```bash
helm upgrade --install bookorbit oci://ghcr.io/<github-user>/charts/bookorbit \
  --version $VERSION \
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

**CPU/IO priority:** the `/books` and `/data` archives are captured by `tar`/`gzip` running *inside* the BookOrbit container via `kubectl exec`, sharing its CPU and memory limits. On constrained nodes, compressing a large library at full priority can starve the app of CPU long enough to fail its health checks and get restarted mid-backup. If the underlying storage is Ceph RBD (as in this chart), the node also runs the kernel RBD client for that volume, which must periodically renew a heartbeat ("watch") with the Ceph OSDs to keep its session alive. The same CPU starvation can delay that renewal, causing Ceph to blocklist the client and produce spurious I/O errors on the mount until it's reset. To avoid this, the script runs those `tar` invocations under `nice -n 19` (lowest CPU priority) and, if available in the container image, `ionice -c3` (best-effort/idle IO class). This way the backup only uses resources the app isn't currently using, at the cost of taking longer under load.

To list all backups or inspect a specific one:

```bash
# List all backup runs
aws s3 ls s3://bookorbit-backups/bookorbit/ --profile <profile>

# List the contents of a specific backup
aws s3 ls s3://bookorbit-backups/bookorbit/20260616T175400Z/ --profile <profile>
```

**Consistency note:** The three archives are captured at different points in time. `pg_dump` is safe while the database is running (it takes a consistent snapshot via MVCC), but `tar` is not snapshot-aware. Files being written mid-backup may be captured in a partially-written state. More critically, if BookOrbit writes a new book to `/books` and its database record between the `pg_dump` and the `/books` tar, a restore would have the file but no record (or vice versa). For a home setup this is an acceptable trade-off; a library re-scan after restore will reconcile any mismatches. For a fully consistent backup, scale the deployment to zero first, back up, then scale back up (at the cost of downtime):

```bash
kubectl scale deploy/bookorbit -n bookorbit --replicas=0
bash scripts/backup.sh
kubectl scale deploy/bookorbit -n bookorbit --replicas=1
```

Anatomy of `bash scripts/backup.sh`: it runs `pg_dump` through `kubectl exec` into the PostgreSQL pod, then tars `/books` and `/data` through `kubectl exec` into a pod that has those volumes mounted — normally the running app pod. When the app is scaled to zero there is no app pod to exec into, so the script detects this and starts a short-lived `backup-helper` pod that mounts the two PVCs read-only, tars from there, and deletes it when done (the same pattern as `restore-helper.yaml` in [Restore](#restore); the RWO volumes are free because nothing else holds them).

Two constraints follow. Scale only the app Deployment, not `--all`: PostgreSQL must stay up for `pg_dump` to have a pod to exec into. And if a `helm upgrade` might land while the app is held down, use `--set replicaCount=0` instead of `kubectl scale`, since an upgrade resets a plain scale.

**Restore priority:** PostgreSQL is the only irreplaceable store; restore it first. `/books` can be restored from originals if you have them. Most of `/data` (extracted covers, author photos) can be regenerated by re-scanning the library; the only non-recoverable part is `cover_custom.*` files (covers manually uploaded through the UI).

### Restore

Restore reverses the backup: load `postgres.sql.gz` back into PostgreSQL, then extract `books.tar.gz` and `data.tar.gz` back into the `/books` and `/data` volumes. It assumes the chart is already installed, so the PVCs and the PostgreSQL pod exist. For disaster recovery on a fresh cluster, install the chart first (`scripts/gen-secrets.sh` then `helm upgrade --install`, see [Install](#install)); that creates empty PVCs and an initialized empty database to restore into. The dump does not carry the PostgreSQL role password, so the database keeps the password `initdb` set from your `my-secrets.yaml` and the app connects without a mismatch. No secret rotation is needed.

**Migrating to new cluster hardware:** restoring into a completely different cluster is the same procedure with one addition up front. Install the chart on the new cluster, then run the numbered steps below against the new cluster's kubeconfig (see [Prerequisites](#prerequisites) for pointing `kubectl`/`helm` at it). The backup lives in S3 independently of any cluster, so step 1 works unchanged from the new machine. Because you still have the old cluster's `my-secrets.yaml`, carry it over instead of generating fresh secrets:

- **Reuse `my-secrets.yaml`.** Copy it from the old cluster and install with `-f my-secrets.yaml`. Keeping the same `credentials.jwtSecret` preserves existing login sessions; a new one invalidates every token and forces all users to sign in again. Keeping the same `credentials.postgresPassword` is optional but tidy, since `initdb` sets the new database to whatever is in the file and the dump carries no role password, so the app and database stay in sync either way. `credentials.setupBootstrapToken` no longer matters once the admin account exists in the restored database.
- **Set environment-specific values for the new cluster.** Provide `config.appUrl`, the HTTPRoute hostname, and the three `storageClass` values as needed. If the public URL and domain are unchanged, `appUrl` stays the same.
- **Re-create out-of-band resources.** If you expose BookOrbit through a Cloudflare Tunnel, re-create the `cloudflared-credentials` Secret on the new cluster (it lives outside Helm, see `CLOUDFLARE.md`) and repoint `cloudflared` at a new node's LAN IP; the tunnel ID can be reused. If you reach it by hostname on your LAN, update the `/etc/hosts` entry to a new node IP.

Once the restore is verified on the new cluster, decommission the old one.

Restore priority follows the [backup note](#backup): PostgreSQL is the only irreplaceable store, so restore it first.

1. **Download the backup.** The helper script pulls the most recent run into a local directory named after its timestamp:

   ```bash
   bash scripts/download-backup.sh
   TS=<timestamp>   # the directory the script just created
   ```

   To restore an older run instead, list the runs and copy one down by hand:

   ```bash
   aws s3 ls s3://bookorbit-backups/bookorbit/ --profile <profile>
   aws s3 cp s3://bookorbit-backups/bookorbit/<timestamp>/ "<timestamp>/" \
     --recursive --profile <profile>
   ```

2. **Restore PostgreSQL.** Scale the app to zero first so nothing writes to the database while it is being replaced. The PostgreSQL pod is a separate Deployment and stays up:

   ```bash
   kubectl scale deploy/bookorbit -n bookorbit --replicas=0
   kubectl wait --for=delete pod -l app.kubernetes.io/name=bookorbit -n bookorbit --timeout=60s
   ```

   The dump is a plain SQL dump of the `bookorbit` database with no `DROP`/`CREATE DATABASE`, so load it into an empty schema. Drop and recreate `public` to clear anything the app's migrations created on a fresh install, then stream the dump in. `psql` connects over the local socket, which `pg_hba.conf` trusts, so no password is needed:

   ```bash
   kubectl exec -i -n bookorbit deploy/bookorbit-postgres -- \
     psql -U bookorbit -d bookorbit -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;'

   gunzip -c "$TS/postgres.sql.gz" \
     | kubectl exec -i -n bookorbit deploy/bookorbit-postgres -- \
         psql -U bookorbit -d bookorbit -v ON_ERROR_STOP=1
   ```

   `ON_ERROR_STOP=1` makes the restore fail on the first error instead of leaving a half-loaded database. The dump recreates the `vector` extension it needs; the bundled `pgvector` image already ships it.

3. **Bring the app back up:**

   ```bash
   kubectl scale deploy/bookorbit -n bookorbit --replicas=1
   kubectl rollout status deploy/bookorbit -n bookorbit
   ```

4. **Restore the files.** The archives store paths relative to `/` (`books/…` and `data/…`), so extract each at `/` from inside the running app pod, mirroring how the backup captured them:

   ```bash
   kubectl exec -i -n bookorbit deploy/bookorbit -- tar xzf - -C / < "$TS/books.tar.gz"
   kubectl exec -i -n bookorbit deploy/bookorbit -- tar xzf - -C / < "$TS/data.tar.gz"
   ```

5. **Re-scan the library** from the BookOrbit UI to reconcile any file/record mismatch left by the archives being captured at slightly different times (see the [consistency note](#backup)).

**Replace vs. merge:** extraction overwrites matching paths but leaves unrelated existing files in place, so restoring onto a non-empty library merges the two. For an exact replacement, clear the directories first (leave `lost+found`):

```bash
kubectl exec -n bookorbit deploy/bookorbit -- sh -c 'rm -rf /books/* /data/*'
```

**Ownership:** `kubectl exec` runs as the image's default user. When that is root, `tar` restores each file's original owner from the archive, which matches the container's `process.puid`/`process.pgid` (1000 by default). If files land with the wrong owner, fix them from inside the pod with `chown -R 1000:1000 /books /data`.

**Fully quiescent file restore (optional):** restoring files into the running app pod mirrors the backup and is fine for a home setup. To keep the volumes completely idle instead, leave the app scaled to zero and extract into a short-lived pod that mounts the two PVCs, then delete it and scale the app back up:

```yaml
# restore-helper.yaml
apiVersion: v1
kind: Pod
metadata:
  name: restore-helper
  namespace: bookorbit
spec:
  restartPolicy: Never
  securityContext:
    fsGroup: 1000
  containers:
    - name: helper
      image: busybox
      command: ["sleep", "3600"]
      volumeMounts:
        - { name: books, mountPath: /books }
        - { name: data, mountPath: /data }
  volumes:
    - name: books
      persistentVolumeClaim:
        claimName: bookorbit-books
    - name: data
      persistentVolumeClaim:
        claimName: bookorbit-data
```

```bash
kubectl apply -f restore-helper.yaml
kubectl wait --for=condition=Ready pod/restore-helper -n bookorbit --timeout=60s
kubectl exec -i -n bookorbit restore-helper -- tar xzf - -C / < "$TS/books.tar.gz"
kubectl exec -i -n bookorbit restore-helper -- tar xzf - -C / < "$TS/data.tar.gz"
kubectl delete pod restore-helper -n bookorbit
kubectl scale deploy/bookorbit -n bookorbit --replicas=1
```

This works because the app is at zero replicas, so the ReadWriteOnce `books` and `data` PVCs are free for the helper pod to attach.

## Upgrading

### Routine upgrade

Most upgrades are a new BookOrbit release, which reaches you as a bumped `image.tag` default in a new chart version. Use `--reset-then-reuse-values` (Helm ≥ 3.14): it resets to the new chart's defaults, re-applies the values you supplied at install time (including `my-secrets.yaml`), and merges any `--set` overrides on top:

```bash
VERSION=  # the new chart version

helm upgrade bookorbit oci://ghcr.io/santisbon/charts/bookorbit \
  --version $VERSION \
  --namespace bookorbit \
  --reset-then-reuse-values
```

Dry-run first with `--dry-run --debug` to see what changes. `helm rollback bookorbit -n bookorbit` reverts a bad upgrade.

Do **not** use `--reuse-values` for chart version upgrades. Despite the name, it re-renders using the *old* chart's coalesced values, old defaults included, so the new chart's bumped defaults (`image.tag`, `postgres.image.tag`) are silently discarded: you get the new chart version with the old images. Per `helm upgrade --help`, `--reuse-values` "reuse[s] the last release's values", while `--reset-then-reuse-values` "reset[s] the values to the ones built into the chart, appl[ies] the last release's values and merge[s] in any overrides". `--reuse-values` is only appropriate when re-running the *same* chart version to tweak one `--set` flag.

One caveat applies to both flags: anything you pinned explicitly stays pinned. If you installed with `--set image.tag=...`, that value survives the upgrade and masks the chart's new default. Check with `helm get values bookorbit -n bookorbit` (careful, that prints your secret values to the terminal).

### Before upgrading, check the upstream release

The chart's `appVersion` tracks the BookOrbit release in `image.tag`. Before bumping it, read the [release notes](https://github.com/bookorbit/bookorbit/releases) for anything that needs action on your side, and diff the upstream [compose file](https://github.com/bookorbit/bookorbit/blob/main/docker-compose.yml) against this chart's `values.yaml`. The compose file is where upstream declares the PostgreSQL image it develops against, and a change there is easy to miss because it usually lands as a routine `build(docker)` commit rather than a headline in the release notes.

BookOrbit does not require the exact PostgreSQL major version upstream ships, so a mismatch is not urgent. Tracking it keeps you on the version that actually gets tested.

### PostgreSQL major version upgrade

Changing `postgres.image.tag` across a major version (`pg16` → `pg18`) is not a drop-in edit. PostgreSQL cannot read a data directory written by a different major version, so the new image will refuse to start on the existing PVC and the pod will crash-loop complaining that the database files are incompatible. The data has to leave through `pg_dump` and come back through `psql`, which is the same path the [Restore](#restore) section already describes.

Your books and covers are not involved. Only the PostgreSQL PVC is replaced; `bookorbit-books` and `bookorbit-data` are untouched throughout.

Do this in one sitting, with the app down from start to finish. Step 2 is the point of no return for the old volume.

1. **Back up, and keep the dump local** so the restore does not depend on a download:

   ```bash
   bash scripts/backup.sh
   bash scripts/download-backup.sh
   TS=<timestamp>   # the directory the script just created
   gunzip -t "$TS/postgres.sql.gz" && echo "dump readable"
   ```

2. **Stop everything, then discard the old volume.** Helm recreates the PVC empty on the next upgrade:

   ```bash
   kubectl scale deploy -n bookorbit --replicas=0 --all
   kubectl wait --for=delete pod --all -n bookorbit --timeout=120s
   kubectl delete pvc bookorbit-postgres -n bookorbit
   ```

   Here `--all` is correct and deliberate, unlike in the backup note above: nothing needs to exec into PostgreSQL at this point, and the volume cannot be deleted while a pod holds it.

3. **Upgrade to the chart version carrying the new tag,** keeping the app down through the upgrade. PostgreSQL comes up on a fresh volume, which `initdb` initializes with the password from your `my-secrets.yaml`:

   ```bash
   helm upgrade bookorbit oci://ghcr.io/santisbon/charts/bookorbit \
     --version $VERSION \
     --namespace bookorbit --reset-then-reuse-values \
     --set replicaCount=0
   kubectl rollout status deploy/bookorbit-postgres -n bookorbit
   ```

   `replicaCount=0` matters. Left at 1, the app starts against the empty database and runs its migrations before you restore. Step 4 would still overwrite that, but there is no reason to let the app touch a database you are about to replace.

4. **Restore the dump.** The dump is a plain SQL dump with no `DROP`/`CREATE DATABASE`, so clear the schema `initdb` left behind and stream it in. `psql` connects over the local socket, which `pg_hba.conf` trusts, so no password is needed:

   ```bash
   kubectl exec -i -n bookorbit deploy/bookorbit-postgres -- \
     psql -U bookorbit -d bookorbit -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;'

   gunzip -c "$TS/postgres.sql.gz" \
     | kubectl exec -i -n bookorbit deploy/bookorbit-postgres -- \
         psql -U bookorbit -d bookorbit -v ON_ERROR_STOP=1
   ```

   The dump recreates the `vector` extension it needs, and the `pgvector` image ships the same extension series across PostgreSQL majors, so it restores without a version pin.

5. **Bring the app back up and verify:**

   ```bash
   helm upgrade bookorbit oci://ghcr.io/santisbon/charts/bookorbit \
     --version $VERSION --namespace bookorbit --reset-then-reuse-values \
     --set replicaCount=1
   kubectl exec -n bookorbit deploy/bookorbit-postgres -- \
     psql -U bookorbit -d bookorbit -c 'select version();'
   ```

   Then check the UI: book count, covers, and that your session survived.

**Rollback** is to set `postgres.image.tag` back to the old major, delete the PVC again, and restore the same dump. That is why step 1 keeps a local copy.

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
