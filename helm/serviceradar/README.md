# ServiceRadar Helm Chart (Preview)

This chart packages the ServiceRadar demo stack for Helm-based installs.

Status: scaffolded. It includes:
- Ingress template driven by values.yaml
- DB Event Writer ConfigMap

Planned next: port all base resources from k8s/demo/base into templates/.

Usage:

1) Create required secrets (client-side generation recommended):

GHCR image pull secret:
  kubectl -n serviceradar-staging create secret docker-registry ghcr-io-cred \
    --docker-server=ghcr.io --docker-username=<user> --docker-password=<token> --docker-email=<email>

App secrets (admin password printed once):
  ADMIN_PASSWORD_RAW=$(openssl rand -base64 18 | tr -d '=+/' | cut -c1-12)
  JWT_SECRET_RAW=$(openssl rand -hex 32)
  API_KEY_RAW=$(openssl rand -hex 32)
  PROTON_PASSWORD_RAW=$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-20)
  ADMIN_BCRYPT_HASH=$(htpasswd -nbB admin "$ADMIN_PASSWORD_RAW" | cut -d: -f2)
  kubectl -n serviceradar-staging apply -f - <<EOF
  apiVersion: v1
  kind: Secret
  metadata:
    name: serviceradar-secrets
    labels:
      app.kubernetes.io/part-of: serviceradar
      app.kubernetes.io/component: secrets
  type: Opaque
  data:
    jwt-secret: $(echo -n "$JWT_SECRET_RAW" | base64 -w0)
    api-key: $(echo -n "$API_KEY_RAW" | base64 -w0)
    proton-password: $(echo -n "$PROTON_PASSWORD_RAW" | base64 -w0)
    admin-password: $(echo -n "$ADMIN_PASSWORD_RAW" | base64 -w0)
    admin-bcrypt-hash: $(echo -n "$ADMIN_BCRYPT_HASH" | base64 -w0)
  EOF
  echo "Admin password: $ADMIN_PASSWORD_RAW"

2) Install chart:
  helm install serviceradar ./helm/serviceradar \
    -n serviceradar-staging --create-namespace \
    --set ingress.host=staging.serviceradar.cloud

Notes:
- This chart deliberately does not generate secrets in-cluster.
- As we port resources, image tags and other settings will be configurable via values.
