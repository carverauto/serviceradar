## 1. Privileged artifact materialization
- [x] 1.1 Retain the verified downloaded artifact as a bounded staging input.
- [x] 1.2 Add updater arguments for identity, version, binary, digest, and signature.
- [x] 1.3 Verify and extract the artifact into a root-owned version directory.
- [x] 1.4 Atomically manage the privileged `current` link and rollback target.

## 2. Runtime and unit migration
- [x] 2.1 Resolve unit files and capability targets only from the privileged tree.
- [x] 2.2 Move assignment-derived configuration to the writable state tree.
- [x] 2.3 Update bundled units to use privileged executable paths and writable config paths.
- [x] 2.4 Remove writable executable-path and agent-side relabel allowances.

## 3. Verification
- [x] 3.1 Add failure vectors for missing/invalid signatures, digest mismatch, and staged-file replacement.
- [x] 3.2 Cover successful activation, reconfiguration, rollback, timer start, and stale-unit cleanup.
- [x] 3.3 Run focused Go and packaging tests through BazelCI/BuildBuddy RBE.
- [x] 3.4 Confirm installed units contain no executable path below the agent-writable tree.
