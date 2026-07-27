## ADDED Requirements

### Requirement: Brand logo assets for shell chrome

The web-ng static asset set SHALL include brand logos used by shell chrome:

- `images/logo.svg` (existing)
- `images/logo-animated.svg` (marketing/control path parity)

Bazel/release packaging MUST preserve these files the same way other `priv/static/images` assets are preserved today.

#### Scenario: Animated logo present in static tree

- **WHEN** the web-ng source tree is packaged for release
- **THEN** `priv/static/images/logo-animated.svg` is available to the Phoenix static pipeline
- **AND** shell templates may reference `~p"/images/logo-animated.svg"` successfully

#### Scenario: Existing logo still present

- **WHEN** the web-ng release is built
- **THEN** `priv/static/images/logo.svg` remains available
- **AND** older references to `logo.svg` continue to resolve
