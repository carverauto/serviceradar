# Palisade

> Trust-boundary defense primitives for Elixir web apps.

[![Hex.pm](https://img.shields.io/hexpm/v/palisade.svg)](https://hex.pm/packages/palisade)

Apache-2.0 licensed. Originally extracted from CarverAutomation's CRM and
ServiceRadar codebases, which kept drifting copies of the same SSRF and
web-edge hardening modules. Palisade is the canonical home.

Every module takes its configuration as explicit options. Nothing reads
application environment at request time.

## Scope

Outbound requests:

- **`Palisade.NetworkAddressPolicy`** - rejects loopback, link-local and
  private network addresses (IPv4 and IPv6), and is DNS-resolution aware
  (defeats DNS rebinding). `ip_in_any_cidr?/2` and `cidr_contains?/2` match
  an address against caller-supplied CIDRs, including IPv4-mapped IPv6
  addresses.
- **`Palisade.OutboundURLPolicy`** - HTTPS-only, public-host URL validator,
  for code that follows an admin-supplied URL (OIDC discovery, webhook
  callbacks).
- **`Palisade.OutboundFetch`** - HTTP fetch bound to the resolved IP that
  `OutboundURLPolicy` approved. TLS hostname verification and the `Host:`
  header stay tied to the original hostname.

Web edge (Plug):

- **`Palisade.Plug.SecurityHeaders`** - content security policy (enforce or
  report-only, with a report URI), HSTS, `Permissions-Policy`,
  `Referrer-Policy`, `X-Content-Type-Options` and `X-Frame-Options`, with a
  strict same-origin default policy.
- **`Palisade.ClientIP`** and **`Palisade.Plug.RemoteIP`** - client address
  resolution that reads `X-Forwarded-For` only from trusted proxy CIDRs, with
  bounded parsing. `ClientIP.from_connect_info/2` gives LiveView sockets the
  same answer.
- **`Palisade.RateLimit`** - rate-limit backend behaviour, with
  **`Palisade.RateLimit.ETS`** (single node, bounded, denies new keys when
  full) and **`Palisade.Plug.RateLimit`** (named buckets, `x-ratelimit-*` and
  `retry-after` headers, JSON or HTML 429).
- **`Palisade.ConnectionLimiter`** - admits long-lived connections such as
  LiveView mounts against global and per-key caps on active connections and
  admission rate. A slot is released when its owner process exits.
- **`Palisade.Plug.RequestGuard`** - rejects GET and HEAD requests with a
  body or `transfer-encoding`, over-long query strings, too many headers, and
  query parameters outside an optional allow-list.

Planned:

- `Palisade.OIDC.Client` - OIDC discovery, JWKS and ID-token verification
  with nonce, iss, aud and exp validation.
- `Palisade.OIDC.ConfigCache` - ETS-backed cache for OIDC discovery and JWKS
  payloads.

## Installation

Add `palisade` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:palisade, "~> 0.2"}
  ]
end
```

## Web-edge setup

Palisade has no application callback. The two modules that own a process
are started from your own supervision tree:

```elixir
# lib/my_app/application.ex
children = [
  {Palisade.RateLimit.ETS, max_entries: 100_000},
  {Palisade.ConnectionLimiter, name: MyAppWeb.LiveLimiter, max_active_per_key: 20},
  MyAppWeb.Endpoint
]
```

Then add the plugs to the endpoint or a router pipeline:

```elixir
# lib/my_app_web/endpoint.ex
@client_ip [trusted_proxies: ["10.0.0.0/8"]]

plug Palisade.Plug.RemoteIP, @client_ip
plug Palisade.Plug.RequestGuard, max_query_length: 4096
plug Palisade.Plug.SecurityHeaders, csp_report_uri: "/csp-report"

# lib/my_app_web/router.ex
pipeline :login do
  plug Palisade.Plug.RateLimit, bucket: :login, limit: 5, window_ms: 60_000
end
```

`Palisade.Plug.RateLimit` uses the default `Palisade.RateLimit.ETS` table
unless given `backend: {Module, opts}`. A cluster-wide backend implements the
`Palisade.RateLimit` behaviour.

Each module's documentation lists its options and defaults.

## Where the source lives

Palisade's source lives inside ServiceRadar's monorepo at `elixir/palisade/`.
ServiceRadar's other Elixir apps consume it with a sibling path dependency:

```elixir
# in e.g. elixir/serviceradar_core/mix.exs
{:palisade, path: "../palisade"}
```

Bazel builds and tests palisade on every pull request (see
[Bazel and Mix](#bazel-and-mix)). External consumers pull from hex.pm, and
Hex publication remains tag-triggered.

## Versioning and publishing

Tag-based. From the ServiceRadar repo root:

```bash
git tag palisade-v0.x.y
git push origin palisade-v0.x.y
```

ServiceRadar CI watches for `palisade-v*` tags and runs
`mix hex.publish package --yes` from `elixir/palisade/`. The publish step
needs `HEX_API_KEY` set as a CI secret with publish scope on hex.pm. See
[CHANGELOG.md](CHANGELOG.md) for release notes.

## Bazel and Mix

Inside this repository Bazel builds palisade with warnings as errors
(`//elixir/palisade:erlang_app`), runs its tests
(`//elixir/palisade:unit_tests`) and runs its format/Credo check
(`//elixir/palisade:quality_check`) on every pull request. The
tag-triggered Hex publish workflow still uses plain Mix, because external
consumers build palisade with Mix when they pull it in as a Hex dependency.

## Development

```bash
cd elixir/palisade
mix deps.get
mix test
mix credo --strict
mix format --check-formatted
```
