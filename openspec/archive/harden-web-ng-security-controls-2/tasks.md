## 1. Implementation

- [x] 1.1 Replace `!=` with `Plug.Crypto.secure_compare/2` for SAML CSRF token comparison in `saml_controller.ex`
- [x] 1.2 Replace `!=` with `Plug.Crypto.secure_compare/2` for OIDC state comparison in `oidc_controller.ex`
- [x] 1.3 Replace `String.to_atom/1` with `String.to_existing_atom/1` (with rescue) in `node_live/show.ex`
- [x] 1.4 Add `sanitize_return_path/1` to `user_auth.ex` to validate post-login redirect targets
- [x] 1.5 Pass session `connect_info` to UserSocket in `endpoint.ex`
- [x] 1.6 Require JWT authentication in `user_socket.ex` `connect/3` callback
- [x] 1.7 Add user presence check to `topology_channel.ex` `join/3`
- [x] 1.8 Remove `inspect(reason)` from client-facing error responses in topology channel and snapshot controller
- [x] 1.9 Export `escapeHtml` from `netflow_charts/util.js`
- [x] 1.10 Add `escapeHtml()` to tooltip innerHTML in `TimeseriesCombinedChart.js`
- [x] 1.11 Add `escapeHtml()` to tooltip innerHTML in `NetflowSankeyChart.js`
- [x] 1.12 Add `escapeHtml()` to tooltip innerHTML in `NetflowTalkersIcicle.js`

## 2. Verification
- [ ] 2.1 Verify SAML login flow still works with secure_compare
- [ ] 2.2 Verify OIDC login flow still works with secure_compare
- [ ] 2.3 Verify node_live/show gracefully handles unknown node names
- [ ] 2.4 Verify post-login redirect works for valid paths and rejects external URLs
- [ ] 2.5 Verify WebSocket connection requires authenticated session
- [ ] 2.6 Verify topology channel rejects unauthenticated join attempts
- [ ] 2.7 Verify chart tooltips render correctly with escaped HTML
