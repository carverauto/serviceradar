## 1. Implementation

- [x] 1.1 Enable automated synchronization for `demo/prod-release`.
- [x] 1.2 Keep prune, self-heal, and empty-application synchronization disabled.
- [x] 1.3 Add a release contract test covering promotion ordering and the Argo policy.

## 2. Verification

- [x] 2.1 Validate the OpenSpec change strictly.
- [x] 2.2 Run the release publication contract test locally and through Bazel.
- [x] 2.3 Verify the live demo application remains healthy after the policy update.
