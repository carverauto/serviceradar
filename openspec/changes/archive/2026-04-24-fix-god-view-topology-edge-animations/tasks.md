## 1. Implementation
- [x] 1.1 Audit current God-View deck.gl edge and particle layer configuration to identify why particles are not visible.
- [x] 1.2 Update the God-View rendering pipeline so animated particles render above base edge lines.
- [x] 1.3 Enforce color/opacity contrast between particle animations and static edges in the default theme.
- [x] 1.4 Preserve reduced-motion accessibility behavior by disabling motion while keeping non-animated edge visibility intact.
- [x] 1.5 Add/adjust UI tests (or visual regression coverage) for animated edge visibility in God-View topology.

## 2. Verification
- [ ] 2.1 Validate in desktop browsers used by ServiceRadar operators (Chrome and Safari/WebKit where available).
- [ ] 2.2 Confirm particles remain visible during zoom/pan and with dense edge sets.
- [ ] 2.3 Confirm no regressions to topology frame rate targets under representative graph sizes.
