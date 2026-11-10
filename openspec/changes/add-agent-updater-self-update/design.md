## Context

### What exists today (read from code)

| Fact | Source |
| --- | --- |
| The updater path is a fixed constant, `/usr/local/bin/serviceradar-agent-updater`. | `go/pkg/agent/release_runtime.go:38` |
| The package installs it `root:serviceradar`, mode `4750`: only the service account's group can execute it. | `build/packaging/packages.bzl:46`, `build/packaging/specs/serviceradar-agent.spec:36`, `build/packaging/agent/scripts/postinstall.sh:107` |
| Before executing it the agent requires a regular, root-owned file that is not group or world writable, and for privileged operations the setuid bit. | `go/pkg/agent/release_runtime.go:425`, `go/pkg/agent/release_runtime.go:448` |
| Capability is discovered by running `--help` and parsing flag names out of the usage text. | `go/pkg/agent/release_runtime.go:468`, `go/pkg/agent/release_runtime.go:498` |
| The updater cannot report its own version: `--version` is the staged release to activate. | `go/pkg/agent/updaterflags/flags.go:35`, `go/cmd/agent-updater/main.go:79` |
| The updater's operations: managed certificates, add-on systemd install, add-on systemd uninstall, release activation. | `go/cmd/agent-updater/main.go:50` |
| Release activation verifies nothing as root. It checks the version directory exists and switches a link in a tree the service account owns. Signature and digest checks happen earlier, in the unprivileged agent. | `go/pkg/agent/release_runtime.go:111`, `go/pkg/agent/release_update.go:253`, `build/packaging/specs/serviceradar-agent.spec:44` |
| Add-on install does verify as root: SHA-256 of the artifact, then an Ed25519 signature over the raw artifact bytes, with the embedded release key. | `go/pkg/agent/addon_systemd.go:344`, `go/pkg/agent/addon_activation.go:856` |
| The agent release manifest is signed with the same key, over canonical JSON. | `go/pkg/agent/release_update.go:746`, `build/release/publish_packages.go:474` |
| The same private key signs add-on artifacts and agent manifests in CI. | `.github/workflows/native-addons.yml:60`, `.github/workflows/release.yml:614` |
| Key resolution falls back to the `SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY` environment variable when the caller passes an empty key. Add-on install substitutes the embedded key first. | `go/pkg/agent/release_update.go:763`, `go/pkg/agent/addon_systemd.go:294` |
| The updater runs helper tools by absolute path because it is setuid and must not trust the caller's `PATH`. | `go/pkg/agent/addon_systemd.go:56` |
| The updater already installs one systemd drop-in for the agent unit and reloads systemd. | `go/pkg/agent/release_runtime.go:171` |
| The capability bounding set the updater inherits is declared in the packaged unit. | `build/packaging/agent/systemd/serviceradar-agent.service:40` |
| The package already ships a root-owned agent "seed" under `/usr/local/lib/serviceradar/agent/` that the launcher copies into the writable runtime. | `build/packaging/packages.bzl:41`, `go/pkg/agent/release_runtime.go:39` |
| Core gates systemd add-ons on the capability string `addon.systemd.updater.unavailable`. | `elixir/serviceradar_core/lib/serviceradar/plugins/addon_rollout_artifact.ex:39`, `:185`, `:644` |
| Release rollouts are cohort-based with per-agent targets that carry a status, a last error and free-form metadata. | `openspec/specs/agent-release-management/spec.md:114`, `elixir/serviceradar_core/lib/serviceradar/edge/agent_release_target.ex:93` |

Two details in that table shape the design. First, the root helper has never had to trust
an agent release: agent activation is not a privilege boundary, because the service
account owns the tree it activates in. A replacement updater is the first payload from the
agent release pipeline that root must authenticate. Second, one private key currently
signs two different message shapes (raw bytes and canonical JSON), so a third use must not
be confusable with either.

### Constraints

- An agent compromise must not become a root compromise through this mechanism.
- Hosted tenants have their Helm values rendered by a control plane, so behaviour is a
  runtime setting with a code default, never a Helm-only value.
- Linux package installs only. Containers have no setuid helper; Windows and macOS have
  their own installers.

## Goals / Non-Goals

Goals:

- A host whose updater supports self-replacement never needs a package upgrade again to
  gain a privileged capability.
- The trust boundary is stated precisely and enforced by the root side alone.
- A bad updater release is caught before it is committed, and its blast radius is one
  rollout cohort.
- Operators can see, per agent, which updater is installed, whether it can replace itself,
  and what to do when it cannot.

Non-Goals:

- Making existing field updaters replace themselves. They cannot; see "Bootstrap".
- Privileged self-update on Windows, macOS, containers or read-only `/usr` hosts.
- Downgrading an updater through the agent.
- Changing how the unprivileged agent release is staged or activated.
- Replacing the setuid model with a different privilege mechanism (evaluated and rejected
  below).

## Decisions

### Decision 1: the installed root updater replaces itself (recommended)

New operation: `--updater-install`, with `--updater-descriptor <path>`,
`--updater-signature <value>` and `--updater-binary <path>`.

Who does what:

1. **Release pipeline (CI).** Builds the updater per OS and architecture, writes a
   descriptor, signs it with the updater signing private key, and publishes binary,
   descriptor and signature as release assets. The agent release manifest references them
   in a new top-level `updater` list.
2. **Core.** Sends the descriptor, signature and artifact location to the agent, as part of
   `agent.update_release` and as a standalone `agent.update_updater` command. Core is a
   courier. Nothing core sends is trusted by the root side.
3. **Agent (unprivileged, `serviceradar`).** Downloads the binary over the existing
   release artifact transport, checks the digest as a courtesy, stages the three inputs in
   its own writable tree, and executes the installed updater. Its checks protect nothing;
   they only avoid pointless root invocations.
4. **Installed updater (euid 0, real uid `serviceradar`).** Treats every input as hostile
   and is the only verifier that matters:
   - opens the candidate and descriptor with `O_NOFOLLOW`, refuses non-regular files, and
     reads each once into memory under a fixed size bound; everything after operates on
     those bytes, so the caller cannot swap a file between check and use;
   - verifies the descriptor signature over the domain-separated message of Decision 2
     (context string, newline, exact descriptor bytes), before parsing the descriptor,
     with the trusted public keys **compiled into the running updater**. No
     environment variable, file or flag can supply or override a key;
   - parses the descriptor against its fixed schema, rejecting an undefined field or a
     missing required one, including the operation set;
   - requires `kind` to be exactly the updater kind, `os` and `arch` to equal the running
     updater's, and the SHA-256 of the candidate bytes to equal the descriptor's;
   - applies rollback protection (Decision 3);
   - writes the bytes to a fixed destination with fixed owner and mode (Decision 4).

Why an unprivileged agent, or anything that compromises it, cannot install an arbitrary
root binary: it cannot produce a signature; it cannot influence which key is used; it
cannot choose the destination, owner, mode or label; it cannot present a different
component's signed bytes because the signed message names the component; it cannot replay
an older genuine updater because of the floor. What it can do is install a newer genuine
updater early, or refuse to install one. The first is harmless and the second is no worse
than an agent that refuses to update itself.

Honest weaknesses of this option, and what covers them:

| Weakness | Cover |
| --- | --- |
| A broken updater release can leave a host with no working privileged helper, and only root can fix that. | Candidate self-test before commit (Decision 5), a release gate proving each updater can install its successor (Decision 6), cohort canary and pause rule (Decision 9). Residual remedy is the bootstrap remedy, which must exist anyway. |
| The root helper parses a signed document supplied by an untrusted caller. | The descriptor is a small fixed-schema JSON object; unknown fields are rejected; size is bounded; the signature is verified over the domain-separated message (Decision 2) before parsing. |
| Field updaters predate the operation. | Unavoidable for any option; see "Bootstrap". |

### Decision 2: a typed descriptor, a dedicated key, a domain-separated signature (recommended)

Descriptor (illustrative values):

```json
{
  "kind": "serviceradar.agent-updater.v1",
  "version": "1.6.0",
  "os": "linux",
  "arch": "amd64",
  "sha256": "<hex digest of the updater binary>",
  "size": 12345678,
  "operations": ["release.activate", "addon.systemd.install", "updater.install"]
}
```

The signed message is the ASCII context string `serviceradar-agent-updater-descriptor-v1`,
one newline, then the descriptor file's exact bytes. The signature is Ed25519.

Why not "an Ed25519 signature over the binary", which is what add-ons use
(`go/pkg/agent/addon_activation.go:867`)? Because that message shape carries no meaning.
With the shared release key, any signed add-on artifact would verify as an updater and be
installed setuid-root. Binding kind, version and platform inside the signed message is
what turns "the pipeline signed these bytes" into "the pipeline says these bytes are
updater 1.6.0 for linux/amd64".

Why a dedicated key rather than the release key with a context prefix? The release key
already signs raw, caller-shaped byte strings (add-on artifacts). A context prefix defends
against confusion only if no other use of the key will ever sign a byte string that begins
with that prefix. Today that holds because CI builds every artifact it signs; it is a
property of the pipeline, not of the cryptography. A dedicated key makes the root trust
anchor independent of every other signing use, and limits what the more widely used key
can do if it leaks. Cost: one more CI secret, one more committed public key file with the
same release-time assertion the existing key has (`scripts/verify-agent-release-key-stamp.sh`,
referenced from `go/pkg/agent/release_signing_key.txt`).

Key rotation needs no package: an updater binary carries a list of trusted updater public
keys. To rotate, ship updater N+1, signed by the old key, embedding old and new keys; later
ship N+2, signed by the new key, embedding only the new one. Hosts must pass through N+1.
The descriptor's `min_installed_version` field (optional) lets a release declare that
stepping stone, and core sequences it.

The existing release key, its embedded file and the requirement "Package-managed agent
trust anchors are package-owned" are untouched. That requirement governs the agent's
verification of agent releases. This change adds a second, separate anchor for one new
root-side decision.

### Decision 3: rollback protection is a strict version order plus a root-owned floor

- The candidate version must be strictly greater, by semantic-version precedence, than the
  running updater's compiled-in version.
- A root-owned floor file records the highest updater version ever installed on the host.
  The candidate must not be below it. Every privileged invocation raises the floor to at
  least the running version, so the floor heals after a crash.
- The floor lives in a root-owned directory next to the package seed (proposed:
  `/usr/local/lib/serviceradar/agent/updater/floor`), outside anything the service account
  can write.

The floor matters in one case the version check alone misses: a root operator installs an
older package, so the running updater is old but still capable of self-replacement. Without
the floor, a compromised agent could then walk the host forward to a chosen, known-bad
intermediate version. With it, the only accepted candidates are at or above the highest
version the host has run.

Downgrade is a package-manager action by a root operator. A package install, including a
forced one, may replace the active binary and leaves the floor unchanged; nothing in this
design lowers the floor. An updater running below the floor still works and reports
`below_floor`; core classifies it `outdated` and schedules the normal forward replacement
to a published updater at or above the floor, so a
forced package downgrade does not pin a host.

Lowering the floor is a high-water downgrade: it re-enables every validly signed updater
between the new floor and the old one, which is exactly the walk to a known-bad
intermediate version the floor exists to stop. Deleting the floor file has the same effect
and is not a supported procedure. Whether any floor-lowering mechanism should exist is
Open Decision 9.

### Decision 4: replacement is one rename in the destination directory

Order of operations, all as euid 0:

1. Take an exclusive lock on a root-owned lock file. Remove any stale temporary file left
   by an earlier interrupted attempt.
2. Create a temporary file in `/usr/local/bin` with `O_CREAT|O_EXCL|O_NOFOLLOW`, owner
   `root:root`, mode `0700`. Same directory means same filesystem, so the final rename is
   atomic, and the file inherits the directory's default security label.
3. Write the verified bytes, `fsync` the file.
4. Run the candidate self-test from that path (Decision 5). The file is not yet setuid and
   not executable by the service account.
5. `fchown` to `root:serviceradar`, then `fchmod` to `4750`. Ownership first: changing
   ownership clears setuid bits.
6. Compare the temporary file's security label with the installed updater's and set it to
   match when they differ. Abort if it cannot be made to match.
7. `rename(2)` the temporary file over the fixed path, `fsync` the directory.
8. Raise the floor. Reconcile the managed drop-in (Decision 8). Print a JSON result.

Properties:

- **Atomic.** Any concurrent `execve` of the path gets the old inode or the new one, never
  a partial file. The running updater keeps executing its now-unlinked inode. The file is
  never opened for writing in place, so there is no "text file busy" and no window in
  which a setuid file has attacker-influenced content.
- **Interrupted replacement.** Before step 7 the old updater is untouched and a root-only
  temporary file is left for the next run to remove. After step 7 the new updater is
  installed; if the floor write was lost the next invocation heals it.
- **SELinux.** `/usr/local/bin` content is labelled `bin_t` by path in the targeted policy
  and a file created there inherits it; step 6 turns that assumption into a check, because
  a mislabelled setuid helper fails closed in a way that looks like a broken release. The
  unit already grants `CAP_MAC_ADMIN` for relabelling
  (`build/packaging/agent/systemd/serviceradar-agent.service:36`). Inference: the repo has
  no SELinux policy module of its own, only `semanage fcontext` rules for add-on trees
  (`build/packaging/agent/scripts/postinstall.sh:117`); this must be verified on an
  enforcing host, which is a task.
- **AppArmor.** Profiles attach by path. The path does not change, so any site profile
  keeps applying. The repo ships no AppArmor profile (no match under `build/packaging`).
- **Read-only or `nosuid` `/usr/local`.** Replacement fails with a specific reason and the
  host is reported as not self-replaceable. Out of scope to work around.

### Decision 5: the running updater self-tests the candidate before committing

The old, known-good updater executes the candidate with `--updater-self-test` from the
root-only temporary path and requires exit 0 within a short timeout. The self-test proves
the binary runs on this host (architecture, libc, kernel), that it reports the descriptor's
version and operations, that its signature verification accepts a built-in test vector and
rejects a corrupted one, and that it can perform the replacement sequence of Decision 4
against a scratch file in the root-owned state directory.

This is the cheap answer to "what if the new updater is broken": most ways a release can
be broken (wrong architecture, crash at start, broken crypto, broken file handling) are
found by the old binary, which then refuses to commit. What it cannot find is a defect in
some other operation (for example add-on install). That kind of defect is repaired by the
next updater release, because self-replacement itself was proven to work.

### Decision 6: a release cannot ship an updater that cannot install its successor

A release gate builds the candidate updater, installs it over the previous release's
updater through `--updater-install` in a container as a non-root caller, then has the
candidate install a synthetic higher version signed with a test key. Both directions must
pass. This is the property that keeps a fleet recoverable, so it is a gate and not a test
someone may skip.

### Decision 7: the package ships a payload, not the active file

Today the package owns the active path, so two things go wrong once hosts self-replace:
`rpm -V` and `dpkg --verify` report a modified file, and installing any package whose
updater is older than the self-updated one silently regresses the host.

- The package installs its updater at a package-owned path next to the agent seed
  (proposed: `/usr/local/lib/serviceradar/agent/serviceradar-agent-updater-seed`), mode
  `0755`, not setuid.
- The package install script, already running as root, executes that payload with
  `--updater-install-from-package`. It installs itself to the active path with the
  sequence of Decision 4 when the active updater is absent, older, or equal; it leaves a
  newer active updater alone and says so. No signature is involved: the package manager,
  run by root, is the authority, exactly as it is for the agent seed today.
- The active path is no longer a packaged file (`%ghost` in the RPM, removed by the
  package's removal script on both families). Package verification stays clean and package
  operations cannot regress the updater.
- A root operator can force the package's version with a documented flag on the same
  command. That is the supported downgrade. It replaces the active binary and leaves the
  floor unchanged.

New installs get a self-replacing updater from the first package built after this change,
so they never enter the bootstrap state.

### Decision 8: the updater reconciles the service properties it needs

The capability bounding set the helper inherits is declared in the packaged unit
(`build/packaging/agent/systemd/serviceradar-agent.service:40`). A future privileged
operation that needs another capability would be stranded behind a package upgrade again,
which is the disease this change treats. The updater therefore owns one more managed
drop-in, alongside the one it already writes (`go/pkg/agent/release_runtime.go:48`),
declaring the properties its own operations require. Its content is a compiled-in constant
of the signed updater; the agent supplies nothing. A changed drop-in takes effect at the
agent's next restart, and the agent reports `restart_pending` until then.

Scope is deliberately narrow: properties the updater itself needs, nothing else. General
unit-file drift stays a package concern.

### Decision 9: core drives replacement, and settings can stop it

- The agent never starts a replacement on its own. Core sends the command; the signature,
  not the command, is what the root side trusts.
- In an agent release rollout, the new agent replaces the updater after its own activation
  is confirmed healthy. Release activation uses flags every field updater has
  (`docs/docs/native-addons.md:617`), so the agent can always move first.
- For agents already on the target release whose updater lags, the reconciler sends
  `agent.update_updater` on the same cohort schedule.
- Outcomes are recorded per rollout target. A failure whose reason indicates a defective
  candidate (`self_test_failed`, `descriptor_invalid`, `digest_mismatch`) pauses the
  rollout. A failure caused by the host (`read_only_filesystem`, `label_mismatch`,
  `bootstrap_required`) does not: the target is reported and the rollout continues.
- Runtime settings, global with code defaults, following the resolved-settings pattern of
  `ServiceRadar.Edge.PipelineSettings`
  (`elixir/serviceradar_core/lib/serviceradar/edge/pipeline_settings.ex:1`):
  `updater_replacement_enabled` (default `true`) is the kill switch and the only setting.
  Turning it off stops new dispatches immediately and leaves installed updaters as they
  are. The pause rule above is fixed in code; which rule it is is Open Decision 6.

### Decision 10: version skew rules

- The updater is backward compatible with agents. Flag names are already declared a
  compatibility interface (`go/pkg/agent/updaterflags/flags.go:21`); this change makes the
  rule explicit: an operation or flag is removed only after the oldest agent release
  inside the supported upgrade window no longer uses it.
- An updater newer than the agent is always acceptable. After an agent rollback the
  updater stays where it is.
- An agent newer than the updater is the normal state between activation and replacement.
  The agent names the operations a feature needs; when one is missing it reports the
  feature blocked and core schedules replacement, rather than the feature failing with a
  flag-parsing error.
- The agent discovers operations with `--describe`. A helper that does not answer
  `--describe` is, by definition, one that predates self-replacement.

### Decision 11: the updater states core and operators see

| State | Meaning | Can core fix it? |
| --- | --- | --- |
| `current` | Answers `--describe`; version is at least the agent's paired updater and not below the floor. | Nothing to do. |
| `outdated` | Answers `--describe`; older than the paired updater, or running below the floor. | Yes: replacement to an updater at or above both. |
| `bootstrap_required` | Present and valid, but predates self-replacement. | No: one package upgrade. |
| `unavailable` | Missing, not root-owned, writable by others, or not setuid. | No: reinstall the package. |
| `replacement_failed` | The last attempt failed; carries a reason code. | Depends on the reason. |
| `not_applicable` | Platform or install layout has no privileged helper. | Not a defect. |
| `unknown` | Recorded by core when the agent reports no updater status (an agent release older than this change). Never treated as healthy. | No: upgrade the agent; the legacy capability string still drives add-on eligibility. |

Reported alongside: updater version, platform, operations, floor, `below_floor`,
`restart_pending`, and the time of observation. The capability string
`addon.systemd.updater.unavailable` keeps being reported for older cores.

## Bootstrap: existing hosts need one package upgrade

Stated plainly: an updater built before this change has no `--updater-install` and cannot
be given one remotely by any legitimate means. Each such host needs its
`serviceradar-agent` package upgraded once, by root, to a version that contains this
change. After that it never needs a package upgrade for the updater again.

How the product surfaces it:

- Each affected agent is in state `bootstrap_required`, with the installed helper's
  observed capabilities and the reason.
- The agents list has a filter and a count; Edge Ops shows a banner while any agent is in
  that state; an add-on or release rollout that skips such a host names the host and the
  reason instead of the bare `agent_updater_outdated`.
- The remedy is exact and per host: the package-manager command for the host's package
  family and the target version, the onboarding reinstall command, and, when the Ansible
  integration is configured and the host is a launchable target, a link to the first-party
  "Install or upgrade the ServiceRadar agent package" automation
  (`add-awx-playbook-provisioning`).
- The state clears by itself when the upgraded helper answers `--describe`.

## Alternatives considered

**Ship the updater inside the release payload and re-point a root-owned link.** The
payload is extracted by the unprivileged agent into a tree it owns. A setuid helper cannot
live there, and a root-owned link can only be re-pointed by root after root has
authenticated the target. Once those two facts are respected this option needs a root
verifier and a root-owned store, which is Decision 1 with an extra indirection and more
than one setuid-capable file on disk. Rejected as strictly more moving parts for the same
trust model.

**A minimal immutable root helper that only verifies and swaps.** The package installs a
tiny setuid helper that never changes; real updater logic lives in versioned, signed
binaries the helper verifies and executes. Its real advantage is recovery: a broken
updater release cannot break the helper, which can always fall back. Its cost is that it
recreates the problem one level down. The helper is the one component that can never be
fixed in the field, and it is the component that holds the trust anchor: a verification
bug or a key rotation again requires touching every host's package. It also still needs
the same one-time package upgrade to arrive. Rejected because "immutable" is the property
that caused the incident; Decisions 5 and 6 buy most of the recovery benefit without it.

**Require package upgrades and automate them through the Ansible integration.** This is
the right remedy for the bootstrap and is offered there. As the standing mechanism it
fails: it requires AWX, SSH reachability, credentials and inventory membership for every
agent host; many deployments have none of these; and the agent already has an
authenticated, signed delivery path that reaches every host. It would also make each
privileged feature wait on a separate operational system. Rejected as the mechanism, kept
as a remedy.

**systemd-run or polkit delegation instead of a setuid binary.** A root unit activated by
the agent, or a polkit rule that lets the service account start specific units, removes
the setuid surface. But the unit files and polkit rules are package-owned, so they age
exactly as the helper does; polkit is absent on many minimal server installs; and the
question "how does root authenticate a new privileged payload" is unchanged. Rejected: it
moves the privilege boundary without solving the update problem, and replaces a mechanism
several approved add-on changes are built on.

**Use the add-on install path of old updaters to bootstrap them.** Older field helpers
install systemd units as root on the agent's request; a signed first-party "bootstrap"
add-on could carry a new helper. Rejected without reservation: it depends on the exact
behaviour of each historical helper version, does not reach helpers that predate add-on
support, and works precisely because older helpers verified less than current ones do. A
product must not rely on its own privilege-escalation surface as an update channel.
(Inference: the per-version verification behaviour of field helpers was not audited for
this proposal; the rejection does not depend on the result.)

**Keep the previous updater on disk for automatic rollback (A/B slots).** After a
replacement, retain the old binary setuid for a probation window; if the new one fails a
post-commit check, the agent invokes the old one to switch back. This closes the residual
gap in Decision 5: a candidate that passes its self-test but cannot replace itself in
practice. Concrete failure mode: a host stuck with a helper that works for nothing or
cannot take a successor. Likelihood: low, because the self-test and the successor gate
exercise exactly that path. Cost: a second setuid file, a probation state machine, a
confirm step, and a new way for a host to be left with an old privileged binary. Not
recommended for the first version; listed as an owner decision.

## Risks / Trade-offs

- A defective updater release reaches a cohort before it is caught. Mitigation: self-test,
  successor gate, cohort staging, pause rule, kill switch. Residual remedy: package
  reinstall on the affected cohort.
- The updater signing key becomes a root-of-fleet secret. Mitigation: dedicated key, used
  by one release job, with the same derived-public-key assertion as the existing key.
  Compromise is recoverable only by package upgrade, the same as today's package trust.
- The package layout change touches install scripts on both families. Mitigation: package
  tests already assert payload modes (`build/release/agent_linux_packages_test.go:372`)
  and are extended to cover the seed, the ghost entry and upgrade ordering.
- Hosts with unusual mounts cannot self-replace. They are reported, not hidden.

## Migration Plan

1. Ship the updater with `--describe`, `--updater-install`, `--updater-self-test` and the
   package payload layout. Ship the agent and core read model. Replacement dispatch is
   present but the code default for the kill switch is the owner's choice (Open Decisions).
2. Fleets upgrade packages on `bootstrap_required` hosts at their own pace; the product
   lists them. New installs are already capable.
3. First release after that carries a changed updater. Roll it through one canary cohort;
   verify by artefact (the reported updater version of the specific hosts, observed after
   the dispatch time), not by command success.
4. Remove the help-text flag probe once no supported agent release needs it.

Rollback of this change: turn the kill switch off. Installed updaters keep working; the
new operations are simply not invoked.

## Open Decisions for the owner

1. **Mechanism.** Self-replacing updater (recommended) or immutable minimal helper.
2. **Signing key.** Dedicated updater key (recommended) or the existing release key with a
   domain-separated message.
3. **Automatic post-commit rollback (A/B slots).** Not in the first version (recommended),
   or build it now.
4. **Package layout.** Package-owned seed payload plus unpackaged active path
   (recommended), or keep the active path packaged and relax package verification for it.
5. **Kill-switch default in the first release.** On, with replacement confined to operator
   started, cohort-staged rollouts (recommended), or off for one release.
6. **Effect of a replacement failure on a release rollout.** Pause only on
   candidate-defect reasons (recommended), pause on any failure, or never pause.
7. **Unit property drop-in (Decision 8).** In scope (recommended) or deferred.
8. **Supported upgrade window** that bounds flag and operation removal. Recommended:
   twelve months of agent releases; the owner sets the number.
9. **Lowering the floor.** No mechanism is proposed and none is recommended; the floor
   only rises. Risk of any mechanism: lowering it re-enables every validly signed updater
   between the new floor and the old one, so any caller able to execute the helper could
   then walk the host to a known-bad intermediate version. Options the owner may weigh: no
   mechanism (a host's highest installed version is permanent), a local root-only action,
   or a signed reset descriptor, which would be a remote downgrade primitive.
10. **Bootstrap enforcement.** Report and offer remedies (recommended), or additionally
    block agent release rollouts to `bootstrap_required` hosts until they are upgraded.

## Not established from the code

- Whether `ServiceRadar.Edge.ReleaseManifestValidator` rejects an unknown top-level
  manifest key. It appears to validate only the version and the artifact list
  (`elixir/serviceradar_core/lib/serviceradar/edge/release_manifest_validator.ex:68`,
  `:90`); a task confirms this with a test before the manifest gains `updater`.
- The ownership and mode of `/usr/local/lib/serviceradar/agent` as the Debian package
  creates it. The launcher requires the seed to be root-owned
  (`build/packaging/agent/bin/serviceradar-agent`), which implies a root-owned directory,
  but the directory itself is not declared in the RPM spec.
- Label behaviour on an SELinux enforcing host for a file created in and renamed within
  `/usr/local/bin` by the setuid helper under the packaged unit's bounding set.
- Which historical helper versions are present on real fleets, beyond "some predate the
  add-on flags". The design does not depend on it.
- The approved requirement "Activation is atomic and rollback is automatic" says the
  updater restores the previous payload; in code the agent does
  (`go/pkg/agent/push_loop_enroll.go:239`). Unrelated to this change, noted so nobody
  assumes the helper has a rollback loop to extend.
