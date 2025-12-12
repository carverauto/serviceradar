# ArgoCD Source Hydrator Setup

## Prerequisites
ArgoCD must be installed before enabling the Source Hydrator.

## Option 1: Upgrade ArgoCD with Hydrator Support (Recommended)

Apply the ArgoCD manifest that includes the commit-server:

```bash
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install-with-hydrator.yaml
```

This will:
- Add the argocd-commit-server deployment
- Enable hydrator support in the configuration

## Option 2: Manual Patch (if already using ArgoCD)

If you want to manually add hydrator support:

1. Apply the enable-hydrator ConfigMap patch:
   ```bash
   kubectl apply -f k8s/argocd/base/enable-hydrator.yaml
   ```

2. Apply the commit-server resources:
   ```bash
   kubectl apply -f k8s/argocd/base/commit-server.yaml
   ```

3. Restart ArgoCD components:
   ```bash
   kubectl rollout restart deployment -n argocd argocd-server argocd-application-controller
   ```

## Push Secrets Setup

The Source Hydrator requires push access to Git repositories. Create a secret with GitHub credentials:

```bash
kubectl create secret generic argocd-commit-creds \
  --namespace argocd \
  --from-literal=username=<github-username-or-app> \
  --from-literal=password=<github-token-or-app-private-key>
```

## Verification

Check that the commit-server is running:
```bash
kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-commit-server
```
