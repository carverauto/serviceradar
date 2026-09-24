## Context
ServiceRadar already provides signed Wasm packages, JSON Schema configuration, host-mediated HTTP, credential broker grants, package producer schedules, agent command dispatch, device discovery ingestion, DIRE, and canonical inventory. The first inventory plugin exposed an ownership mistake: provider details were added directly to core.

The revised design treats an approved package as a data-only integration extension. Core recognizes capabilities and bounded declarative contracts, never provider names or provider code.

## Goals / Non-Goals

### Goals
- Add inventory providers without provider-specific core runtime source, static runtime catalogs, global provider documentation, or dedicated CI workflow definitions.
- Let each signed package publish everything needed to configure, schedule, display, and document its integration.
- Keep source credentials and derived tokens inside trusted host adapters while provider response normalization remains in the Wasm sandbox.
- Preserve generic, indexed source observations and conflict-safe DIRE convergence.
- Use one protected release path for all external Wasm repositories and the existing shared first-party path for plugins maintained in this repository.

### Non-Goals
- Loading package-supplied Elixir, JavaScript, HTML, or other executable UI/backend code.
- Allowing packages to define arbitrary credential behavior, SQL, schedules, commands, or unbounded metadata.
- Giving plugins direct access to CNPG, NATS, the host filesystem, or ServiceRadar internal APIs.
- Reclassifying a Wasm-backed provider as a built-in/native credential profile. Existing first-party Wasm providers move their credential declarations into package manifests as part of the shared plumbing.

## Decisions

### Signed package descriptor
`plugin.yaml` MAY contain a bounded `integrations` map:

```yaml
integrations:
  documentation:
    title: Example inventory configuration
    path: docs/configuration.md
  credential_profiles:
    - provider: example-inventory
      label: Example Inventory
      auth_methods:
        - id: username_password
          label: Username and password
          credential_kind: username_password
          fields:
            - id: username
              label: Username
              control: text
              required: true
              secret: false
            - id: password
              label: Password
              control: password
              required: true
              secret: true
      purposes: [device_inventory]
      scope_types: [agent]
      provisioning:
        mode: producer_schedule
        schedule_id: example-inventory.refresh
        credential_requirement: inventory_account
  inventory_sources:
    - source: example-inventory
      label: Example Inventory
      metadata_fields:
        - key: site
          label: Site
```

The importer validates identifiers, bounded credential primitives and controls, counts, lengths, secret/public flags, bundle paths, schedule references, and credential requirement references. Provider and auth IDs are package-defined identifiers, not a core allowlist. Unknown keys fail closed. Documentation and declarative JSON resources are packaged and retained; executable provider modules are forbidden.

### Runtime catalog
Core reads approved package records, selects the latest approved version of each plugin, reparses its manifest, and builds a runtime catalog. Duplicate provider/source claims fail rather than receive load-order precedence. Core does not reserve provider names; trust comes from package signature, approval, descriptor validation, and duplicate-claim rejection.

No provider is added to the SRQL static catalog. Canonical devices remain searchable by generic `discovery_sources`; provider-specific observation fields are rendered from the descriptor and read through the source-inventory API.

### Credential provisioning
A generic reconciler matches enabled credential rules to catalog profiles. It validates provider, auth method, purpose, scope, package config, and cadence, then creates one policy assignment for the selected agent and binds the exact package schedule/credential requirement declared by the descriptor.

Rule metadata contains only public `plugin_config`, schedule state, cadence, and a package-integration marker. The producer dispatcher resolves the stored secret reference into endpoint-scoped, short-lived grants immediately before command dispatch.

### Host-owned token exchange
A package may declare a bounded derived-token injection on a credential grant. The declaration identifies a schedule URL parameter for the HTTPS token endpoint, the exact token request method and form fields, the JSON response token field, and the injection scheme for one separately bound upstream endpoint.

The agent host resolves the long-lived credential, performs the token request with redirects disabled and strict response limits, parses only the declared token field, applies the derived token to the approved upstream request, and clears transient buffers. The Wasm guest does not call the token endpoint and receives neither its response nor the derived token. Token exchange and upstream ACLs are validated before credential resolution; errors are stable and redacted.

### Inventory record stream
An approved inventory producer opens a host-issued run and emits independently
bounded binary inventory pages through the agent-owned durable producer sink.
The agent binds every page to the exact output-contract bundle, package digest,
assignment, run, authenticated network scope, generic source, and stable source
instance. Each page carries a stable producer idempotency key, page ordinal and
content digest, provider cursor/checkpoint, one bounded source object ID per row,
a stable integration ID beginning with the source identifier, standard device
fields for identity/reconciliation, and optional provider data under a bounded
`source_metadata` map. `serviceradar.plugin_result.v1` carries only bounded
action/check status and never persistent inventory pages.

EventWriter stages each PubAcked page incrementally. A bounded terminal manifest
binds the exact source instance, assignment-authorized coverage scope, page and
object counts, ordered Merkle/checkpoint root, and provider snapshot token,
revision, or contract-specific consistency proof. Only a terminal whose declared
pages, digests, object uniqueness, coverage, and provider proof all validate may
atomically replace the current source-snapshot pointer and make omission
authoritative. Missing, partial, aborted, stale, or conflicting runs preserve the
prior current snapshot. A provider without trustworthy snapshot consistency is
upsert-only and cannot infer absence or deletion. Ordinary discovery envelopes
continue through canonical discovery without source-snapshot activation, and
source omission never deletes the canonical device.

### DIRE behavior
The source integration ID remains stable across endpoint, credential, IP, and hostname changes. Existing manufacturer-scoped serial and globally unique MAC evidence may converge observations with another source under normal conflict/cooldown rules. IP and hostname cannot override conflicting strong identities.

Activated plugin inventory snapshots do not replace another source's canonical
integration identity. Source observations retain provider metadata and follow
the winning canonical UID during merges.

### External release workflow
One manually dispatched core workflow accepts an allowlisted `carverauto/serviceradar-plugin-*` repository and exact release tag. The unprivileged build checks tag ancestry, uses pinned Go/TinyGo, assembles the bundle with core-owned tooling, and includes conventional `docs/`, `display/`, and `schemas/` resources.

The protected signing job receives only build artifacts, validates package identity and bounds, signs/publishes OCI content, and writes the import index/release assets. It never executes scripts from the external repository and the build job never receives signing or publish credentials.

### First-party plugin placement
The package boundary does not require a separate source repository. Provider integrations maintained by ServiceRadar live under `go/cmd/wasm-plugins/<plugin>` with their manifest, configuration schema, provider documentation, fixtures, and tests. They use the shared Bazel Wasm inventory and `wasm-plugins.yml` publication workflow.

The first-party build inventory names an artifact so Bazel can construct and publish it; it is not a runtime provider catalog. Core still discovers credentials, schedules, source metadata, and documentation exclusively from the imported signed manifest. No provider identifier is added to core logic, SRQL fields, or generic UI code.

### Source-native local development host
The Go and Rust SDKs expose equivalent non-Wasm local-host APIs. A local run loads public plugin configuration plus an optional action invocation from separate JSON documents, overlays process environment values on an optional `.env` file, and exposes only explicitly prefixed credential fields to the trusted local host adapter. The merged host configuration has the same `action_invocation` shape delivered by the production agent.

The local host captures submitted results, telemetry, and logs and mediates HTTP through a caller-supplied handler. Provider packages may use that handler to reproduce their production credential grant, derived-token exchange, endpoint matching, and response bounds while leaving credentials out of plugin configuration and action inputs. The OpenText package supplies the first executable example and uses the same collector and result builder in native and TinyGo runs.

This harness is development-only. It does not verify package signatures, emulate assignment admission, or authorize production execution, and it never changes the signed-package release or agent enforcement paths.

### First implementation
The first-party OpenText NOM plugin owns its fixed Network Automation `list device` protocol, bounded filters/pagination, source field mapping, product documentation, and fixtures. Its package declares the OAuth exchange contract, while the trusted agent host performs that exchange and bearer injection. Its stable integration ID is:

```text
opentext-nom:v1:<instance_id>:device:<device_id>
```

Its package declares the `opentext-nom` provider/source and daily schedule. None of those identifiers appear in core logic or static catalogs.

## Risks / Trade-offs
- A malformed descriptor could affect operator configuration. Strict parsing, package approval, duplicate detection, and no dynamic code loading constrain this risk.
- Runtime catalog reads add database work. The initial implementation favors correctness; a package-status/version-keyed cache can be added after measurement.
- Nested JSON configuration is less ergonomic than custom UI. Schema-driven controls keep the trust boundary simple and can be improved generically.
- Inventory snapshots can be large. Page, record, metadata, run, outstanding-byte,
  provider-consistency, and terminal-manifest limits remain enforced before
  activation; neither the guest, agent, gateway, nor EventWriter materializes the
  whole snapshot in memory.

## Migration Plan
1. Land the generic contract with no active provider package.
2. Remove the unmerged provider-specific core modules, docs, fields, workflow, and tests.
3. Build and publish the first-party OpenText package through the shared Wasm release path.
4. Import and approve the first package and verify its descriptor-generated settings.
5. Create the credential rule and disabled schedule, then run a manual collection
   through the durable inventory-page ABI.
6. Verify page replay, crash/resume, terminal completeness, partial-run
   non-deletion, counts, source observations, DIRE convergence, and redaction
   before enabling daily cadence.

Rollback revokes the package or disables its schedule/assignment. Existing canonical devices and source observations remain auditable.
