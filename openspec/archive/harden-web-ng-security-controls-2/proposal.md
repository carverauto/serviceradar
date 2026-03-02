# Change: Harden Web-NG Security Controls (Round 2)

## Why
A second deep-dive security audit of `elixir/web-ng` uncovered additional exploitable gaps spanning authentication bypass, timing attacks, open redirects, denial-of-service vectors, stored XSS, and information disclosure. These findings are distinct from the first round addressed in `harden-web-ng-security-controls`.

## What Changes
- Replace timing-vulnerable `!=` comparisons on SAML CSRF and OIDC state tokens with `Plug.Crypto.secure_compare/2`.
- Prevent atom table exhaustion DoS by replacing `String.to_atom/1` on user-controlled URL parameters with `String.to_existing_atom/1`.
- Add open-redirect protection to the post-login `return_to` redirect path, covering both direct params and SAML RelayState flows.
- Require JWT authentication on the UserSocket WebSocket connection and verify user presence on TopologyChannel join.
- Sanitize error responses to avoid leaking internal Elixir structures to clients.
- Add `escapeHtml()` to all chart tooltip `innerHTML` assignments that interpolate data-derived values without encoding.

## Security Findings This Proposal Addresses
- **Timing attack on SAML CSRF token comparison**
  - `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/saml_controller.ex:132`
  - Standard `!=` operator enables byte-by-byte token recovery via timing side-channel.
- **Timing attack on OIDC state comparison**
  - `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/oidc_controller.ex:113`
  - Same timing vulnerability on the OAuth state parameter (CSRF protection for OIDC flow).
- **Atom table exhaustion DoS via URL parameter**
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/node_live/show.ex:30`
  - `String.to_atom/1` on user-controlled `node_name` param; BEAM atom table is finite and never GC'd.
- **Open redirect in post-login flow**
  - `elixir/web-ng/lib/serviceradar_web_ng_web/user_auth.ex:34`
  - `params["return_to"]` used as redirect target without validation; also reachable via SAML RelayState.
- **Unauthenticated WebSocket and topology channel**
  - `elixir/web-ng/lib/serviceradar_web_ng_web/user_socket.ex:7`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/channels/topology_channel.ex:12`
  - Any anonymous client could connect and receive real-time infrastructure topology data.
- **Information disclosure in error responses**
  - `elixir/web-ng/lib/serviceradar_web_ng_web/channels/topology_channel.ex:32`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/topology_snapshot_controller.ex:108`
  - `inspect(reason)` exposes internal Elixir structures to clients.
- **Stored XSS via unescaped chart tooltip innerHTML**
  - `elixir/web-ng/assets/js/hooks/charts/TimeseriesCombinedChart.js:81-86`
  - `elixir/web-ng/assets/js/hooks/charts/NetflowSankeyChart.js:275-344`
  - `elixir/web-ng/assets/js/hooks/charts/NetflowTalkersIcicle.js:187-189`
  - Data-derived values (labels, IPs, names) interpolated into innerHTML without HTML encoding.

## Impact
- Affected specs: `web-ng-security-controls` (modified)
- Affected code:
  - `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/saml_controller.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/oidc_controller.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/node_live/show.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/user_auth.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/user_socket.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/channels/topology_channel.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/topology_snapshot_controller.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/endpoint.ex`
  - `elixir/web-ng/assets/js/hooks/charts/TimeseriesCombinedChart.js`
  - `elixir/web-ng/assets/js/hooks/charts/NetflowSankeyChart.js`
  - `elixir/web-ng/assets/js/hooks/charts/NetflowTalkersIcicle.js`
  - `elixir/web-ng/assets/js/netflow_charts/util.js`
