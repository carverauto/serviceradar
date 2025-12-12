# GitOps Promoter Configuration

## Prerequisites

1. ArgoCD with Source Hydrator enabled (done)
2. GitOps Promoter installed (done)
3. GitHub App for SCM access (required)

## Step 1: Create GitHub App

Create a GitHub App at: https://github.com/settings/apps/new

**App Settings:**
- Name: `serviceradar-promoter`
- Homepage URL: `https://github.com/carverauto/serviceradar`
- Webhook: Disabled (uncheck "Active")

**Repository Permissions:**
- Checks: Read and write
- Contents: Read and write
- Pull requests: Read and write
- Commit statuses: Read and write

**Organization Permissions:**
- Members: Read-only (if using org)

After creation:
1. Note the App ID
2. Note the Installation ID (from the "Install" tab after installing to carverauto org)
3. Generate and download a Private Key

## Step 2: Create Kubernetes Secret

```bash
# Create the secret with the GitHub App credentials
kubectl create secret generic github-app-promoter \
  --namespace promoter-system \
  --from-literal=appID=<YOUR_APP_ID> \
  --from-literal=installationID=<YOUR_INSTALLATION_ID> \
  --from-file=privateKey=<PATH_TO_PRIVATE_KEY.pem>
```

## Step 3: Apply SCM Provider and GitRepository

After creating the secret, apply the configuration:

```bash
kubectl apply -f k8s/gitops-promoter/scm-provider.yaml
kubectl apply -f k8s/gitops-promoter/git-repository.yaml
```

## Step 4: Create Environment Branches

The promoter requires specific branches for each environment:

```bash
# Create the hydrated environment branches
git checkout main
git checkout -b environments/demo-staging-next
git push origin environments/demo-staging-next

git checkout main
git checkout -b environments/demo-staging
git push origin environments/demo-staging

git checkout main
git checkout -b environments/demo-next
git push origin environments/demo-next

git checkout main
git checkout -b environments/demo
git push origin environments/demo
```

## Step 5: Apply PromotionStrategy and ArgoCDCommitStatus

```bash
kubectl apply -f k8s/gitops-promoter/promotion-strategy.yaml
kubectl apply -f k8s/gitops-promoter/argocd-commit-status.yaml
```
