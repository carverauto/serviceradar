# dgraph-test

Obtain a running Dgraph for a test, wherever the test happens to run.

```rust
let dgraph = DgraphInstance::acquire()?;
let client = DgraphClient::connect(dgraph.connection_string()).await?;
```

## One input decides everything

`SERVICERADAR_ENV` names an environment. The committed instance for that environment supplies the
endpoint; the environment's *kind* supplies the strategy for making it usable.

| kind | strategy | exclusivity |
| --- | --- | --- |
| `localhost` | provision a `dgraph/standalone` container | `Exclusive` |
| `ci` | verify the Dgraph the cluster already runs | `Shared` |
| `saas`, `demo`, `onprem:*` | refused | — |

Both the endpoint and the strategy come from one `Identity`, so the address a caller dials and the
way it was obtained cannot disagree.

Readiness is decided over Dgraph's HTTP `/health?all`

`saas` and `demo` are refused rather than health-checked because they resolve to
`dgraph-dgraph-alpha.dgraph.svc.cluster.local` — production. A fixture that hands back a live
production endpoint is one careless call away from an incident. Adding an arm should be a
deliberate act with a name on it.

## Ownership is part of the answer

`DgraphInstance::exclusivity()` reports whether this process created the instance. A container it
started may be wiped; the CI cluster is shared with every concurrent pull request and must not be.
Nothing about an endpoint reveals the difference, so callers that destroy data must branch on it.

## Notes

- `acquire()` is blocking, not async. `docker_utils` and the health check are both synchronous, so
  it is callable from a plain `#[test]` and from `#[tokio::test]` alike.
- The container is left running for reuse. Stopping it destroys it — `docker_utils` uses `--rm` —
  and a reused container skips the pull and the boot entirely. The fixed name bounds the leftovers
  at one.
- The readiness gate is non-destructive by construction. It used to be `drop_all`, which was
  defensible only while the resolved host could not be anything but a container this code had just
  created. It can now name a shared cluster, and a probe cannot tell the difference.
