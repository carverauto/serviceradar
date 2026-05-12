# Palisade

> Trust-boundary defense primitives for Elixir web apps.

[![Hex.pm](https://img.shields.io/hexpm/v/palisade.svg)](https://hex.pm/packages/palisade)

Apache-2.0 licensed. Originally extracted from
CarverAutomation's CRM + ServiceRadar codebases, which kept
drifting verbatim copies of the same SSRF / OIDC / SAML
hardening modules. Palisade is the canonical home.

## Scope

Palisade currently provides:

- **`Palisade.NetworkAddressPolicy`** — rejects loopback,
  link-local, and private-CIDR network addresses (IPv4 + IPv6).
  DNS-resolution aware (defeats DNS rebinding).
- **`Palisade.OutboundURLPolicy`** — HTTPS-only, public-host URL
  validator. Used wherever app code follows an admin-supplied
  URL (SAML IdP metadata, OIDC discovery, webhook callbacks).
- **`Palisade.OutboundFetch`** — HTTP fetch helper that binds
  requests to the resolved IP `OutboundURLPolicy` approved. TLS
  hostname verification + the `Host:` header stay tied to the
  original hostname.

Planned for next versions:

- `Palisade.OIDC.Client` — OIDC discovery + JWKS + ID-token
  verify with proper nonce / iss / aud / exp validation.
- `Palisade.OIDC.ConfigCache` — ETS-backed cache for OIDC
  discovery + JWKS payloads.
- `Palisade.SAML.CertTrust` / `Palisade.SAML.AssertionValidator`
  / `Palisade.SAML.XML` — SAML primitives.

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

External consumers pull from hex.pm.

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

## Why not Bazel?

Palisade is a small single-language Elixir library. Consumers
call `mix compile` on it directly when they pull it in as a
hex dep — Bazel never enters the picture. CI runs `mix format /
compile / test / credo` and is done.

## Development

```bash
cd elixir/palisade
mix deps.get
mix test
mix credo --strict
mix format --check-formatted
```
