## 1. Implementation
- [x] 1.1 Add Core and Datasvc service accounts to the SPIRE server k8s_psat allow-list in Helm.
- [x] 1.2 Redeploy SPIRE (server/agents) and restart Core/Web so SPIRE admin mTLS works again.
- [ ] 1.3 Validate edge onboarding create-package (poller/agent/checker) succeeds without SPIRE admin TLS errors.

## 2. Validation
- [x] 2.1 `helm status serviceradar -n demo` shows deployed/healthy after rollout.
- [ ] 2.2 Edge checker package creation returns 201 and no 502 in UI; core logs show join token creation succeeds.
