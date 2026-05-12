# Palisade

> Trust-boundary defense primitives for Elixir web apps.

Apache-2.0 licensed. Originally extracted from
CarverAutomation's CRM + ServiceRadar codebases, which kept
drifting verbatim copies of the same SSRF / OIDC / SAML
hardening modules. Palisade is the canonical home; both
projects (and anyone else who wants them) consume the package
from the public CarverAutomation hex registry.

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

Planned for next versions (porting from ServiceRadar):

- `Palisade.OIDC.Client` — OIDC discovery + JWKS + ID-token
  verify with proper nonce / iss / aud / exp validation.
- `Palisade.OIDC.ConfigCache` — ETS-backed cache for OIDC
  discovery + JWKS payloads.
- `Palisade.SAML.CertTrust` / `Palisade.SAML.AssertionValidator`
  / `Palisade.SAML.XML` — SAML primitives.

## Location + ownership

Palisade lives inside ServiceRadar's monorepo at
`elixir/palisade/`. ServiceRadar's Elixir apps consume it via
the standard sibling-path dep:

```elixir
# in e.g. elixir/serviceradar_core/mix.exs
{:palisade, path: "../palisade"}
```

CRM (and any other CarverAutomation Elixir project outside this
monorepo) consumes it via the CarverAutomation private hex
registry — see "Installation" below.

## Installation (external consumers)

The CarverAutomation private hex registry is hosted at
`https://hex.carverauto.dev` and is publicly readable (no auth
key needed to fetch). Add the registry once per dev machine /
CI runner:

```bash
mix hex.repo add carverauto https://hex.carverauto.dev
```

Then declare the dep in your project's `mix.exs`:

```elixir
def deps do
  [
    {:palisade, "~> 0.1", repo: "carverauto"}
  ]
end
```

`mix deps.get` will pull the latest 0.1.x release from the
registry.

## Versioning + publishing

Tag-based. From the ServiceRadar repo root:

```bash
git tag palisade-v0.x.y
git push --tags
```

ServiceRadar CI watches for `palisade-v*` tags and runs
`mix hex.publish package --repo carverauto --yes` from
`elixir/palisade/`. The publish step needs `HEX_API_KEY` set as
a CI secret (writes only; consumers don't need it).

Bump consumers' `~> 0.x` to pick up the new release.

## Why a self-hosted hex registry and not hex.pm?

The CarverAutomation hex registry at `hex.carverauto.dev`
operates independently of hex.pm. Publishing here keeps
release control inside CarverAutomation while still giving any
downstream Elixir project (in or out of the org) a normal hex
dep UX. The package is Apache-2.0 — anyone is welcome to use
it; the registry is just the distribution channel.

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
