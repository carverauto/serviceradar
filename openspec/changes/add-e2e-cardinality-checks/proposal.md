# Change: Add E2E Cardinality Health Checks for CI/CD Pipeline

## Why

After the DIRE (Device Identity and Reconciliation Engine) refactor, we need automated verification that device cardinality remains stable at ~50k devices. Currently, there's no automated way to verify post-deployment that:
1. The device count matches expected baseline
2. No duplicate devices exist (by strong identifier)
3. The system is healthy enough to proceed in a release pipeline

Manual verification after each deployment is error-prone and doesn't scale with CI/CD automation.

## What Changes

### 1. Health Check Endpoint
Add a `/health/cardinality` endpoint to the core service that returns:
- Current device count from CNPG
- Current device count from in-memory registry
- Drift between the two
- Duplicate check results (distinct armis_device_id vs total count)
- Pass/fail status based on configurable thresholds

### 2. Integration Test Job
Create a Kubernetes Job that can be run post-deployment to validate cardinality:
- Queries the health endpoint
- Validates counts against expected baseline (configurable)
- Returns exit code 0 on pass, non-zero on failure
- Outputs structured JSON for CI parsing

### 3. GitHub Actions Integration
Add workflow that:
- Triggers on release/tag
- Builds with Bazel, gets git SHA from BuildBuddy
- Deploys to demo namespace via ArgoCD with correct image tags
- Waits for ArgoCD sync to complete
- Runs the cardinality check job
- Fails the pipeline if cardinality check fails

### 4. ArgoCD Application Configuration
Configure ArgoCD to:
- Use Helm chart from repo
- Accept image tag overrides from CI
- Sync to demo namespace
- Report sync status for CI polling

## Impact

- **Affected specs**: NEW `e2e-health-checks` capability
- **Affected code**:
  - `pkg/core/api/` - new health endpoint
  - `helm/serviceradar/` - cardinality check job template
  - `.github/workflows/` - release pipeline with E2E checks
  - `argocd/` - ArgoCD application manifests
- **Risk**: Low - additive changes, doesn't modify core device processing
- **Dependencies**: ArgoCD installed in cluster, GitHub Actions runners with kubectl access

## Trade-offs Considered

### Option A: Health Endpoint vs Direct DB Query
- **Chosen**: Health endpoint
- **Rationale**: Endpoint can be reused by monitoring/alerting, not just CI. Also tests the full stack (API layer working).

### Option B: Kubernetes Job vs GitHub Action Script
- **Chosen**: Kubernetes Job triggered by GitHub Actions
- **Rationale**: Job runs inside cluster with proper RBAC, no need to expose endpoints externally. GH Action just triggers and waits.

### Option C: ArgoCD vs Direct Helm Deploy from CI
- **Chosen**: ArgoCD
- **Rationale**: GitOps pattern, ArgoCD handles rollback, sync status, and audit trail. CI just updates image tags and triggers sync.
