# Dgraph

Two deployments of the official [Dgraph chart](https://charts.dgraph.io), both pinned to
**v25.4.0** and pulled from the Harbor mirror.

| | `ci/` | `demo/` |
|---|---|---|
| Pattern | Basic Cluster | HA Cluster |
| Namespace | `dgraph-ci` | `dgraph` |
| Zeros | 1 | 3 |
| Alphas | 1 | 3 |
| Replication (`shardReplicaCount`) | 1 | 3 |
| Groups | 1 | 1 |
| Tolerates | nothing | 1 node loss |
| TLS | on, unverified by clients | on, verified against public roots |

```
./deploy-dgraph.sh ci        # disposable fixture
./deploy-dgraph.sh demo      # HA
./deploy-dgraph.sh mirror    # re-copy pinned images into Harbor
```

## Architecture

Dgraph splits into two node types:

- **Zero** — control plane. Tracks membership, assigns predicates to groups, coordinates
  transactions, and rebalances tablets every 8-10 minutes. Zeros form Raft **group 0**.
- **Alpha** — data plane. Stores the graph, holds indexes, serves DQL/GraphQL. Alphas form
  Raft **groups 1..n**.

Sharding is **by predicate**, not by node. Each predicate lives in exactly one group, and every
Alpha in that group serves an identical copy. `shardReplicaCount` is how many Alphas serve a
group; it is Zero's `--replicas`, and the chart's most misread key — it does not set the
number of Zeros.

## Scaling

**This is the part that decides the shape of the cluster.**

Writes get faster with **cores**, and slower with **nodes**. Every mutation must reach Raft
consensus inside its group: a majority acknowledgement plus a WAL fsync on each replica. Adding
replicas therefore adds network round trips and disk syncs *per proposal* — it buys durability,
never write throughput. Mutations that span groups add distributed-transaction coordination on
top of that. This is the real cost of strong consistenc. See ([dgraph-io#9685](https://github.com/orgs/dgraph-io/discussions/9685)).

The reference design that follows:

- **Fewer, fatter nodes.** 3 Alphas with 8 cores beats 6 Alphas with 4. `demo` requests 4 cores
  and limits at 8 per Alpha for exactly this reason.
- **Replication 3, and odd.** Tolerates one loss. 5 tolerates two and costs a further round
  trip per write; 2 tolerates *none*, because a majority of two is two.
- **Grow in whole groups of 3.** A 4th Alpha adds no capacity — group size is fixed by
  `shardReplicaCount`. Capacity arrives with the 6th, as a second group. Do that only when the
  dataset demands it, because cross-group transactions are the expensive kind.
- **Reach for tuning before nodes.** In the thread above, a 12-node/4-group cluster degrading
  from ~20k to ~5k objects/sec was answered with posting-list cache and compactor settings, not
  more nodes. Raise `--cache_percentage` (posting list) and `--badger.numCompactors` (4 → 8 for
  sustained writes) before scaling out.

Sizing from the [deployment patterns
guide](https://docs.dgraph.io/installation/deployment-patterns): dev 2 cores/4GB/50GB, small
production 8 cores/16GB/250GB SSD, large production 16 cores/32GB/1TB NVMe. Keep inter-node
latency under 5ms — it lands directly in the Raft path.

## TLS

Server TLS on both. Internal ports (5080, 7080) negotiate **mTLS** between Zero and Alpha and
enforce `REQUIREANDVERIFY` automatically; external ports (9080, 8080, 6080) default to
`VERIFYIFGIVEN`. Dgraph reads exactly `ca.crt`, `node.crt` and `node.key`.

**The client is the constraint, and it dictates the certificate choice.**
[`dgraph-client`](https://github.com/marvin-hansen/dgraph-rs) supports three modes — `disable`, `require`
(encrypted, unverified) and `verify-ca` — and `verify-ca` builds
`ClientTlsConfig::new().with_native_roots()`. There is **no way to pin a private CA**, and **no
client-certificate path at all**. Two consequences:

- `client-auth-type=REQUIREANDVERIFY` on the external port would lock this client out
  permanently. Left at the default.
- A privately-issued server certificate cannot be verified, however correct it is.

So `demo` takes its certificate from `carverauto-issuer`, the cluster's ACME/Let's Encrypt
ClusterIssuer (Cloudflare DNS-01). The chain ends at a public root that is already in every
container's trust store, so `sslmode=verify-ca` authenticates the server with no CA plumbing:

```
dgraph://dgraph.serviceradar.cloud:443?sslmode=verify-ca
```

Verification is against **the name dialed**, so that host must match the SAN in
`demo/certificate.yaml` and the ingress host in `demo/values.yaml`. All three move together.

### How the certificate reaches Dgraph

The chart mounts `dgraph-dgraph-alpha-tls-secret` into `/dgraph/tls` **unconditionally**, but
only *creates* that secret when `alpha.tls.files` is non-empty
(`templates/alpha/secret-tls.yaml`). Both environments leave it `{}`, so cert-manager owns the
secret and writes it under exactly that name — renewal lands in the running pod with no copy
job and no replicator operator, neither of which is installed here.

Dgraph wants `ca.crt`/`node.crt`/`node.key`; cert-manager writes `ca.crt`/`tls.crt`/`tls.key`
and its key names are not configurable. Rather than rename them on a schedule, both values
files point Dgraph at the paths it actually has:

```
--tls "ca-cert=/dgraph/tls/ca.crt; server-cert=/dgraph/tls/tls.crt;
       server-key=/dgraph/tls/tls.key; internal-port=true"
```

`internal-port=true` is what turns on mTLS between Zero and Alpha on 5080/7080. Filling in
`alpha.tls.files` instead would put the private key in a values file and freeze it at whatever
was pasted.

`ci` cannot have that: Let's Encrypt will not issue for `*.svc.cluster.local`. It runs TLS with
callers on `sslmode=require` — encrypted, unauthenticated, which is what a private namespace
already is:

```
dgraph://dgraph-dgraph-alpha.dgraph-ci.svc.cluster.local:9080?sslmode=require
```

### Trusting the CI CA

`ci/certificate.yaml` builds a self-signed CA (`dgraph-ci-ca`) and issues the Alpha
certificate from it, so there *is* a root to trust — a bare self-signed leaf could only be
pinned. CI callers fetch that CA live:

```
https://dgraph-ci-ca.carverauto.dev/ca.crt
```

Envoy on `lan-shared-gateway` terminates TLS with the Let's Encrypt wildcard already in
scratch images. The custom CA is the document being served. `config/environments/ci.textproto`
names that URL as `dgraph.ca_bundle_url`; `dgraph-client` verifies Alpha against the fetched
PEM (`sslmode=verify-ca`), not against the system roots.

Workstation copy if you are not going through ConfigManager:

```bash
curl -fsS https://dgraph-ci-ca.carverauto.dev/ca.crt > dgraph-ci.crt
# or:
kubectl get secret dgraph-ci-ca -n dgraph-ci -o jsonpath='{.data.ca\.crt}' | base64 -d \
  > dgraph-ci.crt
```

## ACL and namespaces

ACL is ENABLED on both environments, and the reason is isolation rather than authentication.

Dgraph namespaces are how concurrent test runs stay out of each other's way, and **without ACL
they do not isolate anything**. Verified against `dgraph-ci` before ACL was turned on:
`create_namespace` returned a fresh id, a connection carrying `?namespace=<id>` was accepted,
a write inside it succeeded -- and the same value was then readable from namespace 0. The
parameter is accepted and ignored. Nothing errors, so a suite relying on it for isolation would
have been silently sharing one graph.

`--acl "secret-file=..."` is what turns that on. `docs.dgraph.io` still states that ACL
"requires a Dgraph Enterprise license"; that text predates the Hypermode acquisition and is
wrong for v25. The alpha says so itself at startup:

```
ACL secret key loaded successfully.
Licensed under the Apache Public License 2.0.
... AclEnabled:true AclJwtAlg:HS256 ...
```

### The HMAC secret

Dgraph signs ACL tokens with an HMAC key read from a file, and the chart mounts
`<release>-dgraph-alpha-acl-secret` at `/dgraph/acl` whenever `alpha.acl.enabled` is true.

`deploy-dgraph.sh` creates that secret if it is missing and otherwise leaves it alone, because
rotating it invalidates every issued token and would log every client out mid-run. To create it
by hand:

```bash
kubectl create secret generic dgraph-dgraph-alpha-acl-secret -n dgraph-ci \
  --from-literal=hmac_secret_file="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48)"
```

`alpha.acl.file` stays `{}` in both values files for the same reason `alpha.tls.files` does:
the chart templates the secret only when that field is non-empty while mounting it either way,
so leaving it empty keeps the key out of the repository. **Do not paste an HMAC key into a
values file.** At least 256 bits; 48 alphanumerics is comfortably past that.

### Consequence for clients

ACL means clients authenticate. A newly created namespace gets its own `groot` user, and access
is scoped to the namespace that user belongs to. Credentials resolve through SecretManager like
every other credential here -- they are not in these manifests.

## Chart 24.1.4, image v25.4.0

The newest **stable** chart is 24.1.4; the only v25 chart is `25.0.0-preview6`, a preview whose
appVersion is a preview build. The Dgraph version is set by the **image**, not the chart, so
both environments run the stable chart with the v25.4.0 image pinned, and `deploy-dgraph.sh`
pins `--version 24.1.4` so a new chart publication cannot turn a values-only change into a
chart upgrade.

That pairing is checked, not assumed. Chart 24.1.4 gates exactly four decisions on the image
version, and all four resolve correctly for v25.4.0 — notably `>= 21.03.0`, which selects the
superflag form `--raft idx=` over the legacy `--idx`. The chart's `preUpgradeHook` exists only
on the chart's main branch, not in 24.1.4, so there is nothing to configure and no kubectl
image to mirror. Revisit when a stable v25 chart ships.

## Image mirror

Both environments pull `registry.carverauto.dev/mirror/dgraph/dgraph:v25.4.0`. Mirroring keeps
the Docker Hub rate limit off the critical path and keeps pulls working when egress does not.
`./deploy-dgraph.sh mirror` copies the index plus both per-arch tags:

```
registry.carverauto.dev/mirror/dgraph/dgraph:v25.4.0
registry.carverauto.dev/mirror/dgraph/dgraph:v25.4.0-amd64
registry.carverauto.dev/mirror/dgraph/dgraph:v25.4.0-arm64
```

Bumping the version means changing `DGRAPH_TAG` in `deploy-dgraph.sh` **and** `image.tag` in
both values files, then re-running `mirror`. Nothing enforces that they agree.

## Verifying

```bash
kubectl get pods -n dgraph -l app.kubernetes.io/name=dgraph
kubectl exec -n dgraph dgraph-dgraph-alpha-0 -- dgraph version

# Raft membership and group assignment -- the authoritative view of replication.
kubectl exec -n dgraph dgraph-dgraph-zero-0 -- curl -s localhost:6080/state | jq '.groups'

# Certificate actually in use (demo).
kubectl get certificate -n dgraph dgraph-alpha-tls
openssl s_client -connect dgraph.serviceradar.cloud:443 -servername dgraph.serviceradar.cloud </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer -dates
```

Health is `/state` on Zero, not pod readiness: a group short of quorum has Running pods and
serves nothing.

## Not covered here

Backups (`backups.*` in both files, off), ACLs and encryption-at-rest (enterprise), and Ratel.
Turning on ACLs changes the client's connection string — it would need credentials, which
`dgraph://user:pass@host` already carries.

Sources: [architecture](https://docs.dgraph.io/installation/dgraph-architecture) ·
[deployment patterns](https://docs.dgraph.io/installation/deployment-patterns) ·
[TLS configuration](https://docs.dgraph.io/admin/security/tls-configuration/) ·
[write scaling](https://github.com/orgs/dgraph-io/discussions/9685)
