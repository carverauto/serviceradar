# GitOps Promoter Configuration

## Prerequisites

1. ArgoCD with Source Hydrator enabled (done)
2. GitOps Promoter installed (done)
3. GitHub Personal Access Token (required)

## Step 1: Create GitHub Personal Access Token

Go to: https://github.com/settings/tokens?type=beta (Fine-grained tokens)

**Token Settings:**
- Name: `serviceradar-promoter`
- Expiration: 90 days (or as needed)
- Repository access: `carverauto/serviceradar`

**Permissions:**
- Contents: Read and write
- Pull requests: Read and write
- Commit statuses: Read and write

## Step 2: Create Kubernetes Secret

```bash
kubectl create secret generic github-token \
  --namespace promoter-system \
  --from-literal=token=github_pat_xxxxxx
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
