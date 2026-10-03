# Tasks

## 1. Auth

- [x] 1.1 Default device/PKCE scope to `dashboard.publish edge.manage`; keep `--scope` overrides and
      normalise commas to spaces.
- [x] 1.2 Report `invalid_scope` from the device endpoint with a remedy instead of a bare HTTP 400.
- [x] 1.3 `--web`: fail with "not supported by this server, use device flow" when the authorize or
      token endpoint 404s; stop falling back to manual paste for PKCE.
- [x] 1.4 Record the granted scope in the credential store and show it in `auth status`.

## 2. Commands

- [x] 2.1 Shared edge HTTP client: bearer resolution, 401/403/`insufficient_scope` hints.
- [x] 2.2 `agent list` (admin route, JSON:API fallback).
- [x] 2.3 `edge package create|list|show|revoke|download`.
- [x] 2.4 `edge site create|list|show|bundle [--wait]`.
- [x] 2.5 `collector create|list|show|revoke|download`; `nats account status`.
- [x] 2.6 `--json` everywhere; tables by default; `-o <file>` for downloads.

## 3. Install helpers

- [x] 3.1 `edge install agent`: release package download, dnf/apt install, `srctl enroll`, service restart.
- [x] 3.2 `edge install leaf`: serviceradar-nats, site bundle (waits for leaf), `setup.sh`.
- [x] 3.3 `edge install collector`: package for the collector type, bundle, `update.sh`.
- [x] 3.4 Root check, printed actions, `--dry-run`, required `--version`.

## 4. Packaging and docs

- [x] 4.1 Add the `srcloud` bin alias; bump to 0.2.0 (not published).
- [x] 4.2 README: bin collision, edge onboarding walkthrough; CHANGELOG.

## 5. Tests

- [x] 5.1 Black-box tests against a mock tenant server for every command, the auth scope changes,
      the `--web` failure, `--wait` polling, and install-helper dry-run plans.
