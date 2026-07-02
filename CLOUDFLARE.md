# Cloudflare Tunnel Integration

This document explains how the Cloudflare Tunnel integration works, how it relates to the existing local-network access path, and how to reason about both. When discussing a deployment environment it uses a 3-node Raspberry Pi cluster as an example.

---

## What Cloudflare Tunnel does

Cloudflare Tunnel (`cloudflared`) runs as a Deployment inside your cluster and opens **outbound-only** persistent connections to Cloudflare's global edge network. When a request arrives at `https://books.yourdomain.com`, Cloudflare routes it through those connections to the `cloudflared` pod, which then forwards it directly to the BookOrbit ClusterIP Service (`http://bookorbit:3000`) over the cluster's internal network.

Nothing in your home network is exposed to the internet. No port forwarding. No public IP. Your home router is never in the path.

```
Internet
   │
   ▼
Cloudflare edge (TLS terminated, DDoS protection, optional Access policy)
   │  (outbound tunnel, initiated by cloudflared pod)
   ▼
cloudflared Deployment (inside MicroK8s)
   │  (plain HTTP, cluster-internal)
   ▼
bookorbit ClusterIP Service :3000
   │
   ▼
BookOrbit Pod
```

---

## Deployment design

The chart runs `cloudflared` as a Kubernetes **Deployment with 2 replicas**. Each replica opens its own set of persistent connections to Cloudflare's edge. Cloudflare load-balances incoming requests across all active connections, so both pods serve traffic simultaneously rather than one being a cold standby.

### Why 2 replicas, not a DaemonSet

`cloudflared` is a stateless outbound connector, not a node-level agent. It does not interact with node resources and does not need to run on every node. A DaemonSet would place one pod on each of the three Pis for no additional resilience:

- **DaemonSets are for node-local work.** They exist for pods that need to interact with *that specific node's* resources e.g. log shippers reading local files, monitoring agents reading local hardware/kernel stats, CNI/storage plugins mounting local devices. `cloudflared` just opens outbound TLS tunnels to Cloudflare's edge; it doesn't care which node it runs on, so pinning it to every node serves no functional purpose.
- **A 3rd pod wouldn't add fault tolerance.** The resilience goal is to survive the loss of any *one* Pi without dropping the tunnel. That's already achieved once 2 pods are scheduled on 2 different nodes (see pod anti-affinity below). Losing either node still leaves a pod on the other. A DaemonSet's 3rd pod (one per node) would be redundant capacity, not redundant protection, since the design only needs to tolerate a single node failure.

Cloudflare's connection multiplexing means a single healthy pod is already sufficient, and two is the recommended minimum for redundancy. A Deployment keeps the replica count explicit and predictable.

### Pod anti-affinity

The Deployment sets a `preferredDuringSchedulingIgnoredDuringExecution` pod anti-affinity rule using `topologyKey: kubernetes.io/hostname`. This tells the scheduler to prefer placing the two replicas on different nodes. On a 3-node cluster, the result is one `cloudflared` pod per node for two of the three Pis.

`preferred` (rather than `required`) is intentional: if only one node is schedulable e.g. during a rolling restart or after two nodes go down, Kubernetes will still schedule both replicas on the remaining node rather than leaving one pending. The tunnel stays up.

The practical effect is that losing any single Pi does not interrupt internet access to BookOrbit. The surviving `cloudflared` pod on a different node continues to hold its connections to Cloudflare's edge.

---

## The two access paths

### Path 1 — Local network (HTTPRoute + Traefik)

The existing `HTTPRoute` resource routes traffic from Traefik's Gateway (`traefik-gateway` in the `ingress` namespace) to BookOrbit. This path is used when you access BookOrbit from inside your home network, typically via a local DNS entry like `books.node-01.local`.

```
Browser (local network)
   │
   ▼
Traefik Gateway (MicroK8s ingress addon)
   │  (HTTPRoute match)
   ▼
bookorbit ClusterIP Service :3000
   │
   ▼
BookOrbit Pod
```

### Path 2 — Internet (Cloudflare Tunnel)

When `cloudflare.enabled=true`, a `cloudflared` Deployment and its ConfigMap are added to the cluster. This creates the internet path described above. It is completely independent of Traefik and the HTTPRoute so both can be active simultaneously.

| | HTTPRoute path | Cloudflare Tunnel path |
|---|---|---|
| Entrypoint | Traefik Gateway | Cloudflare edge |
| Reachable from | Local network only | Internet (and local, via public DNS) |
| TLS | Depends on your Traefik config | Always HTTPS via Cloudflare |
| Auth layer | None (unless you add middleware) | Optional: Cloudflare Access (SSO, IP rules) |
| Latency | Sub-millisecond (in-cluster) | Adds Cloudflare round-trip |
| Home IP exposed | No | No |

---

## Implications of running both paths

- **Same pod, two entrances.** Both paths ultimately reach the same BookOrbit pod. There is no data isolation between requests that arrive via local vs. internet paths.
- **`APP_URL` matters.** BookOrbit uses `config.appUrl` to generate absolute URLs (e.g. for OAuth callbacks, email links). If you set it to the public Cloudflare hostname, local deep links will point to the public URL. If you set it to the local hostname, public-facing links will break. Set it to whichever you use as your primary access point.
- **Cloudflare sees your traffic.** All requests through the tunnel pass through Cloudflare's network. This includes request content. For a self-hosted book tracker this is typically acceptable; be aware if you consider the data sensitive.
- **Cloudflare Access (recommended).** Without it, your BookOrbit **login page** is public. Cloudflare Access lets you gate the tunnel behind Google/GitHub SSO or email OTP for free. Add a policy in the Cloudflare Zero Trust dashboard for `books.yourdomain.com`.

---

## Unifying the two paths

You can eliminate the split by making Cloudflare Tunnel the **single** access path for both local and internet access:

1. **Disable the HTTPRoute** (`httpRoute.enabled: false`) so Traefik is no longer involved.
2. **Configure your local DNS** (Pi-hole, router, `/etc/hosts`) to resolve `books.yourdomain.com` to the Cloudflare edge IP (or just let it use the public DNS CNAME as it resolves fine from inside your network too).
3. All traffic — local and remote — goes `browser → Cloudflare edge → tunnel → pod`.

**Trade-off:** Local traffic now makes a round-trip to Cloudflare's edge even when your phone and your server are on the same Wi-Fi network. For a book tracking app this is imperceptible in practice. The upside is one URL everywhere, one TLS certificate, one auth policy, and no split-brain `APP_URL` problem.

Alternatively, keep both paths and use [Cloudflare Split Tunnels](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/private-net/cloudflared/) or a local DNS override so that `books.yourdomain.com` resolves to your Traefik IP when inside the home network and to Cloudflare when outside. This gives low-latency local access while preserving the public hostname. This is the more complex option and requires a local DNS resolver you control (e.g. Pi-hole).

---

## Setup steps

### 1. Prerequisites

- A domain using Cloudflare as its DNS provider (nameservers pointed at Cloudflare). Cloudflare does not need to be your registrar. You can register the domain anywhere and just switch its nameservers to Cloudflare's, or optionally transfer registration too.
- [`cloudflared`](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/) CLI installed on your local machine (not on the cluster — `cloudflared` runs in Kubernetes as a container; the CLI is only needed here to create the tunnel and generate credentials)

### 2. Create the tunnel and Kubernetes Secret

```sh
cloudflared tunnel login
```

```sh
cloudflared tunnel list
```

```sh
APP_DOMAIN=books.yourdomain.com
TUNNEL_ID=$(cloudflared tunnel create -o json bookorbit | jq -r '.id')
cloudflared tunnel route dns bookorbit $APP_DOMAIN # Add CNAME books.yourdomain.com which will route to this tunnelID
```

```sh
kubectl create secret generic cloudflared-credentials \
  --from-file=credentials.json=$HOME/.cloudflared/$TUNNEL_ID.json \
  --namespace bookorbit
```

### 3. Install / upgrade the Helm chart

After packaging the chart and pushing it to the desired registry:

```sh
# from the MicroK8s built-in registry
CHART="oci://node-01.local:32000/charts/bookorbit"
# or from the GHCR
CHART="oci://ghcr.io/<github-user>/charts/bookorbit"
VERSION= # choose a version to deploy
```

```sh
echo $CHART
echo $TUNNEL_ID
echo $APP_DOMAIN
echo $VERSION
```

*Add `--plain-http` for MicroK8s*
```sh
helm upgrade --install bookorbit $CHART \
  --version $VERSION \
  --namespace bookorbit --create-namespace \
  --set cloudflare.enabled=true \
  --set cloudflare.tunnelId=$TUNNEL_ID \
  --set cloudflare.hostname=$APP_DOMAIN \
  --set config.appUrl=https://$APP_DOMAIN \
  --set 'httpRoute.hostnames[0]=books.internal' \
  -f my-secrets.yaml
```

### 4. Verify

```sh
kubectl get pods -n <namespace>                  # cloudflared pod should be Running
kubectl logs -n <namespace> -l app.kubernetes.io/name=bookorbit-cloudflared
```

Visit `https://books.yourdomain.com`. Cloudflare provides the TLS certificate automatically.

### 5. (Recommended) Lock it down with Cloudflare Access

In the [Cloudflare Zero Trust dashboard](https://one.dash.cloudflare.com):

1. Go to **Access → Applications → Add an application → Self-hosted**
2. Set the application domain to `books.yourdomain.com`
3. Add a policy (e.g. allow your email address via OTP, or a GitHub/Google SSO rule)

This adds an authentication gate in front of BookOrbit at Cloudflare's edge. Requests that fail the policy never reach your cluster.

---

## Glossary

- **Access (Cloudflare Access)** — Cloudflare's feature for gating a hostname behind an authentication policy (SSO, OTP, IP rules) before traffic reaches your tunnel.
- **CLI** — Command Line Interface. Used here for the `cloudflared` binary run on your local machine.
- **CNAME** — Canonical Name, a DNS record type that aliases one hostname to another. Cloudflare adds one to route your domain to the tunnel.
- **cloudflared** — Cloudflare's tunnel daemon/client. Runs as a pod in your cluster to open the outbound tunnel, and as a CLI on your machine to create/manage tunnels.
- **ClusterIP Service** — A Kubernetes Service type reachable only from inside the cluster, not from outside it (e.g. `bookorbit:3000`).
- **ConfigMap** — A Kubernetes object for storing non-sensitive configuration data used by pods.
- **DaemonSet** — A Kubernetes workload type that runs exactly one pod on every (matching) node, used for node-local agents.
- **DDoS** — Distributed Denial of Service, a flood-based attack. Cloudflare's edge filters this before traffic reaches your cluster.
- **Deployment** — A Kubernetes workload type that manages a set of replica pods without pinning them to specific nodes.
- **DNS** — Domain Name System, which resolves hostnames (like `books.yourdomain.com`) to routing information.
- **GHCR** — GitHub Container Registry, one option for hosting the packaged Helm chart.
- **Helm chart** — A packaged set of Kubernetes manifests, templated and versioned, installed with the `helm` CLI.
- **HTTPRoute** — A Kubernetes Gateway API resource that defines HTTP routing rules (used here by Traefik for the local-network path).
- **HTTP / HTTPS** — Hypertext Transfer Protocol (and its encrypted form via TLS).
- **IP (address)** — Internet Protocol address, the numeric address of a device on a network.
- **JSON** — JavaScript Object Notation, the format of the tunnel credentials file and `cloudflared` CLI output.
- **kubectl** — The Kubernetes command-line tool used to inspect and manage cluster resources.
- **MicroK8s** — A lightweight Kubernetes distribution from Canonical, used as the cluster runtime here.
- **Namespace** — A Kubernetes mechanism for logically partitioning resources within a cluster (e.g. `bookorbit`).
- **OCI (registry)** — Open Container Initiative image format/protocol; Helm charts can be pushed to and pulled from an OCI-compliant registry.
- **OTP** — One-Time Password, an authentication method Cloudflare Access can require.
- **Pod** — The smallest deployable unit in Kubernetes, running one or more containers.
- **Pod anti-affinity** — A Kubernetes scheduling rule that discourages (or forbids) placing certain pods on the same node as each other.
- **Secret** — A Kubernetes object for storing sensitive data (e.g. the tunnel's `credentials.json`).
- **SSO** — Single Sign-On, an authentication method Cloudflare Access can require (e.g. via Google or GitHub).
- **TLS** — Transport Layer Security, the encryption protocol behind HTTPS.
- **Traefik** — An open-source reverse proxy / ingress controller; here it's the entrypoint for the local-network access path.
- **Tunnel ID** — The unique identifier `cloudflared` assigns to a tunnel when it's created, used to reference it in DNS routes and Kubernetes config.
- **Zero Trust (dashboard)** — Cloudflare's dashboard for configuring Access policies and other security controls.
