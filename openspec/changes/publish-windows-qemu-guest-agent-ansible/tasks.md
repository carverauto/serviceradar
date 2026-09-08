## 1. Public role and wrappers

- [x] 1.1 Add `roles/windows_qemu_guest_agent`, a root install wrapper, typed
  defaults/argument specs, documentation, and a non-secret inventory example.
- [x] 1.2 Add a read-only mounted-media preflight that reports only MSI path,
  SHA-256, and Authenticode status.
- [x] 1.3 Require 64-bit Windows, a healthy VirtIO serial device, exact service
  identity, automatic/running state, binary existence, and non-empty version.

## 2. Artifact and reboot safety

- [x] 2.1 Enforce exact SHA-256 for HTTPS and mounted ISO sources, strict HTTPS
  URL/TLS rules, CD-ROM drive verification, and transient download cleanup.
- [x] 2.2 Enforce `Valid` Authenticode by default and the explicit
  mounted-ISO-only `Valid`/`NotSigned` exception; reject every other state.
- [x] 2.3 Default reboot policy to `never`, surface return-code 3010, and allow
  only explicit `if_required`/`on_change` behavior.

## 3. Controller compatibility and quality

- [x] 3.1 Pin the linux/amd64 AWX EE 24.6.1 digest and its supported
  `ansible.windows 2.4.0` collection; refuse unsupported 3.x/Core 2.15 pairing.
- [x] 3.2 Add dependency-free repository contracts, production ansible-lint,
  every-wrapper syntax checks, Windows path runtime regression, and static
  Molecule syntax coverage.
- [x] 3.3 Build the collection artifact and record immutable source-content and
  collection archive SHA-256 values without publishing private lab data.

## 4. Canary and ServiceRadar dogfood

- [x] 4.1 Configure one isolated Windows AWX inventory host with encrypted
  machine credential and PSRP/NTLM transport; prove `win_ping` and read-only MSI
  preflight.
- [x] 4.2 Install QGA with reboot disabled; verify MSI return code 0, no reboot
  requirement, automatic/running `QEMU-GA`, versioned binary, and independent
  PVE `qm agent <vmid> ping` success.
- [ ] 4.3 Import the final immutable public revision/content digest through a
  reviewed ServiceRadar/AWX template binding and rerun the role from the
  ServiceRadar launch UI to prove idempotence.
- [ ] 4.4 Keep fleet execution disabled until the ServiceRadar launch/result
  path is deployed, exact Farm/Tonka identities are collision-safe, and the
  canary idempotence proof is green.

## 5. Publishing

- [x] 5.1 Commit to `feat/serviceradar-remote-access-enrollment`, push with an
  explicit refspec, and update the existing public draft pull request.
- [ ] 5.2 Complete public review, merge the public pull request, and replace the
  feature-branch AWX project with the approved immutable main/tag revision.
