# Palisade

> Trust-boundary defense primitives for Elixir web apps.

[![Hex.pm](https://img.shields.io/hexpm/v/palisade.svg)](https://hex.pm/packages/palisade)

Apache-2.0 licensed. Originally extracted from
CarverAutomation's CRM + ServiceRadar codebases, which kept
drifting verbatim copies of the same SSRF / OIDC
hardening modules. Palisade is the canonical home.

## Scope

Palisade currently provides:

- **`Palisade.NetworkAddressPolicy`** — rejects loopback,
  link-local, and private-CIDR network addresses (IPv4 + IPv6).
  DNS-resolution aware (defeats DNS rebinding).
- **`Palisade.OutboundURLPolicy`** — HTTPS-only, public-host URL
  validator. Used wherever app code follows an admin-supplied
  URL (OIDC discovery, webhook callbacks).
- **`Palisade.OutboundFetch`** — HTTP fetch helper that binds
  requests to the resolved IP `OutboundURLPolicy` approved. TLS
  hostname verification + the `Host:` header stay tied to the
  original hostname.

Planned for next versions:

- `Palisade.OIDC.Client` — OIDC discovery + JWKS + ID-token
  verify with proper nonce / iss / aud / exp validation.
- `Palisade.OIDC.ConfigCache` — ETS-backed cache for OIDC
  discovery + JWKS payloads.

## Installation

Add `palisade` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:palisade, "~> 0.1"}
  ]
end
```

## Where the source lives

Palisade's source lives inside ServiceRadar's monorepo at
`elixir/palisade/`. ServiceRadar's other Elixir apps consume it
via the standard sibling-path dep:

```elixir
# in e.g. elixir/serviceradar_core/mix.exs
{:palisade, path: "../palisade"}
```

Bazel builds and tests palisade on every pull request (see
[Bazel and Mix](#bazel-and-mix)). External consumers pull from
hex.pm, and Hex publication remains tag-triggered.

## Versioning + publishing

Tag-based. From the ServiceRadar repo root:

```bash
git tag palisade-v0.x.y
git push --tags
```

ServiceRadar CI watches for `palisade-v*` tags and runs
`mix hex.publish package --yes` from `elixir/palisade/`. The
publish step needs `HEX_API_KEY` set as a CI secret with publish
scope on hex.pm.

## Bazel and Mix

Inside this repository Bazel builds palisade with warnings as
errors (`//elixir/palisade:erlang_app`), runs its tests
(`//elixir/palisade:unit_tests`) and runs its format/Credo check
(`//elixir/palisade:quality_check`) on every pull request. The
tag-triggered Hex publish workflow still uses plain Mix, because
external consumers build palisade with Mix when they pull it in
as a Hex dependency.

## Development

```bash
cd elixir/palisade
mix deps.get
mix test
mix credo --strict
mix format --check-formatted
```
