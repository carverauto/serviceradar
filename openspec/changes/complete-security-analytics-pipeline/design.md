# Advisory Producer Execution Model

## Decision

Ship the vulnerability advisory feed producers as one first-party native Go
add-on named `advisory-producer`.

The add-on declares:

- `advisory-feed:v1`
- `producer-schedule:v1`
- `artifact-staging:v1`

It exposes one command surface, `addon.run_command`, with three schedule action
ids:

- `cisa_kev.refresh`
- `nvd_cve.refresh`
- `vulncheck.refresh`

## Rationale

NVD and VulnCheck feeds can be large, credentialed, and provider-specific. A
native add-on can reuse the existing `go/pkg/addon` contract types, normal Go
HTTP and JSON tooling, and the native add-on manager's credential injection
path. CISA KEV is small enough for either Wasm or native execution, but keeping
all three providers in one add-on reduces package review, schedule seeding, and
deployment surface.

The control plane remains provider-agnostic. It owns schedule metadata,
credential grants, and advisory ingestion through the existing
`serviceradar.advisory_feed.contract.v1` batch handler. Provider download,
validation, and normalization stay inside the add-on.

## Consequences

- `ProducerScheduleCatalog.sync_package/2` materializes three schedules from
  the add-on package contract.
- Operators configure cadence and credential refs in the Vulnerability Feeds
  settings UI.
- The add-on reads credential material from the reserved `_serviceradar`
  credentials block injected by the native add-on manager.
- Signed artifact publication remains a release-packaging step; the seeder only
  creates an approved package when configured signed artifact refs exist.
