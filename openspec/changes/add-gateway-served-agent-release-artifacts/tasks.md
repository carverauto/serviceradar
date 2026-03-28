## 1. Control Plane Storage
- [x] 1.1 Add release-asset metadata and internal object-store references to the release catalog model.
- [x] 1.2 Mirror imported or manually published release artifacts into JetStream object storage during release publication.
- [x] 1.3 Update release publication/import validation to ensure internal artifact staging succeeds before a release becomes rollout-eligible.

## 2. Gateway Delivery
- [x] 2.1 Add an authenticated agent-gateway artifact download endpoint backed by JetStream object storage.
- [x] 2.2 Update rollout dispatch payloads so agents receive gateway-served artifact references instead of direct external artifact URLs.
- [x] 2.3 Enforce gateway-side authorization so agents can only fetch artifacts associated with their eligible rollout targets.

## 3. Agent Runtime
- [x] 3.1 Update the agent release downloader to fetch staged rollout artifacts from agent-gateway.
- [x] 3.2 Preserve Ed25519 manifest verification and SHA256 artifact validation after gateway delivery.
- [x] 3.3 Add tests for successful gateway-served download, unauthorized fetch rejection, and mirrored-artifact integrity failures.

## 4. Operator Experience
- [x] 4.1 Keep the manual publish path for developer/local testing while storing those artifacts internally for rollout delivery.
- [x] 4.2 Extend the releases page to show whether a release has been mirrored into internal storage and which source it came from.
- [x] 4.3 Document the repo-release import flow, manual developer flow, and gateway-served artifact delivery model.

## 5. Validation
- [x] 5.1 Add integration coverage for publish/import mirroring, gateway-served delivery, and rollout dispatch using internal artifact references.
- [x] 5.2 Run `openspec validate add-gateway-served-agent-release-artifacts --strict`.
