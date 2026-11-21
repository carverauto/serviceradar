# Change: Deploy an edge NATS leaf with one token, on one path

## Why

The product has two ways to deploy an edge NATS leaf, and the one the UI
offers cannot work against a chart-installed hub.

- **The bundle path (UI, and `edge site bundle`).** Creating an edge site
  issues leaf certificates with server-generated private keys
  (`edge/nats_leaf_certificate_issuer.ex`), and the site page's primary action
  downloads a tarball with those keys and a `setup.sh`. The download is not
  single-use, does not expire and is not audited. The hub's leaf listener
  exists only with certificate authorization on, and that admits only
  certificates recorded as managed components, which these never are. So a
  bundle leaf is refused by the hub.
- **The managed path (`edge install leaf`, CLI only).** The leaf is registered
  as a managed component, the host's enrolled agent generates the keys and
  sends signing requests, and the hub admits the recorded certificate. This is
  the path that can work. The UI does not mention it, and it needs an operator
  login on the edge host.

Around them, several things were never finished (file references in
design.md):

- Nothing marks a leaf connected or a site active. The status badge can never
  show "Connected", and a site never appears in the collector form's site
  list, which only lists active or installed sites.
- A new site's hub address silently defaults to a hosted product hostname
  when the install has not configured one.
- Provisioning waits forever with a spinner when no gateway is reachable.
- The site page's actions have no tests.
- A leaf's grant on the hub is publish and subscribe on every subject.

The owner asked for one-touch provisioning that is secure, issued from the UI
as a token the CLI consumes, the way agent onboarding works.

## What Changes

- **The managed path becomes the only path.** The bundle download (UI button,
  API route, `edge site bundle`), the `setup.sh` generator, server-side leaf
  key issuance on site creation and the leaf credential-file minting are
  removed. **BREAKING** for anyone using the bundle; it cannot connect to a
  chart hub today.
- **"Deploy leaf" issues a token.** The edge site page issues a signed,
  single-use, expiring leaf onboarding token and shows one command:
  `serviceradar-cli edge install leaf --token <token>`. The CLI needs no login
  for it. The token reuses the agent onboarding token's envelope, signing key,
  hashed single-use secret, expiry, revoke and audit events.
- **The token carries no key and yields none.** It authorizes registering the
  leaf for one site on one enrolled host and starting certificate issuance.
  Keys are generated on the host by its agent, as on the managed path today.
- **Status is real.** Core's hub authorizer already lists live hub
  connections by certificate fingerprint; it marks the leaf connected or
  disconnected and the site active or offline.
- **No silent hub address.** A site cannot be created, and a token cannot be
  issued, while the install has no configured leaf address; the page says what
  is missing. Hub readiness comes from `add-zero-touch-hub-certificate-authorization`.
- **The leaf gets a narrow grant on the hub**: the subjects an edge site
  publishes and the hub data it reads, not `>`.
- **Wording.** "SaaS" is removed from pages that also serve self-hosted
  installs.

## Impact

- Affected specs: new capability `edge-leaf-onboarding`.
- Depends on: `add-zero-touch-hub-certificate-authorization` (the hub must be
  able to accept a leaf, and reports whether it can).
- Closes open tasks in older changes: `add-hosted-edge-leaf-connectivity` 4.3
  (leaf subject permissions) and the status, deployment and test tasks left
  unchecked in the archived `add-edge-nats-leaf-deployment`.
- Affected code: `elixir/serviceradar_core` edge site, leaf server, onboarding
  package and hub authorizer modules; web-ng edge site pages, controllers and
  the token modules; `js/cli` edge commands; docs.
- Not in scope: the collector package page, which has the same two-path
  problem (its packages need an account seed nothing configures, and its
  token is never displayed). It is a separate change after the leaf works.
