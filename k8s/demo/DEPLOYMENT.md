# ServiceRadar Kubernetes Deployment Guide

This guide provides complete instructions for deploying ServiceRadar to Kubernetes in a production-ready configuration.

## Overview

The ServiceRadar Kubernetes deployment includes:
- **Core**: Main API server and business logic
- **Proton**: ClickHouse-based analytics database
- **Web**: Next.js frontend application
- **NATS**: Message broker for inter-service communication
- **Agent**: Network scanning and monitoring agent
- **Poller**: Orchestrates monitoring tasks
- **SNMP Checker**: SNMP monitoring capabilities

## Prerequisites

1. **Kubernetes cluster** (tested with K3s, compatible with standard Kubernetes)
2. **kubectl** configured with cluster access
3. **cert-manager** installed for automatic TLS certificate provisioning
4. **Ingress controller** (nginx recommended)
5. **GitHub Container Registry access** for pulling images

### Required Tools
- `openssl` - For generating secrets
- `htpasswd` OR `python3` with bcrypt - For password hashing
- `base64` - For encoding secrets
- `jq` - For JSON processing (optional but recommended)

## Quick Start

### 1. Clone and Setup
```bash
git clone <repository-url>
cd serviceradar/k8s/demo
```

### 2. Create GitHub Container Registry Secret
```bash
kubectl create secret docker-registry ghcr-io-cred \
  --docker-server=ghcr.io \
  --docker-username=YOUR_GITHUB_USERNAME \
  --docker-password=YOUR_GITHUB_TOKEN \
  --namespace=serviceradar-staging
```

### 3. Deploy ServiceRadar
```bash
chmod +x deploy.sh
./deploy.sh
```

The deployment script will:
- Create the `serviceradar-staging` namespace
- Generate secure random passwords and API keys
- Create Kubernetes secrets with proper bcrypt hashing
- Generate a complete configuration with all required components
- Deploy all services with proper dependencies
- Wait for all deployments to be ready
- Display access information and credentials

## Configuration

### Namespace and Environment
The deployment defaults to:
- **Namespace**: `serviceradar-staging`
- **Environment**: `staging`

To customize, edit the variables at the top of `deploy.sh`:
```bash
NAMESPACE="your-namespace"
ENVIRONMENT="your-environment"
```

### Ingress Configuration
Update `staging/ingress.yaml` with your domain:
```yaml
spec:
  tls:
  - secretName: serviceradar-staging-tls
    hosts:
    - your-domain.com
  rules:
  - host: your-domain.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: serviceradar-web
            port:
              name: http
```

## Security

### Automatic Secret Generation
The deployment automatically generates:
- **JWT Secret**: 256-bit random key for authentication tokens
- **API Key**: 256-bit random key for service authentication
- **Admin Password**: 128-bit random password with bcrypt hashing
- **Proton Password**: 128-bit random database password

### TLS/mTLS Configuration
- All internal service communication uses mutual TLS (mTLS)
- Certificates are automatically generated via init jobs
- Web traffic uses TLS certificates from cert-manager

### Password Retrieval
After deployment, retrieve the admin password:
```bash
kubectl get secret serviceradar-secrets -n serviceradar-staging \
  -o jsonpath='{.data.admin-password}' | base64 -d
```

## Validation

### Check Deployment Status
```bash
kubectl get deployments -n serviceradar-staging
kubectl get pods -n serviceradar-staging
kubectl get services -n serviceradar-staging
kubectl get ingress -n serviceradar-staging
```

### Test API Connectivity
```bash
# Via ingress (replace with your domain)
curl -k https://your-domain.com/api/auth/status

# Via port-forward
kubectl port-forward -n serviceradar-staging svc/serviceradar-web 3000:3000
curl http://localhost:3000/api/auth/status
```

Expected response: `{"authEnabled":true}`

### Test Authentication
```bash
# Get admin password
ADMIN_PASSWORD=$(kubectl get secret serviceradar-secrets -n serviceradar-staging \
  -o jsonpath='{.data.admin-password}' | base64 -d)

# Login
curl -X POST https://your-domain.com/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"'$ADMIN_PASSWORD'"}'
```

## Architecture

### Service Dependencies
```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│    Web      │───▶│    Core     │───▶│   Proton    │
└─────────────┘    └─────────────┘    └─────────────┘
                           │
                    ┌─────────────┐
                    │    NATS     │
                    └─────────────┘
                           │
                    ┌─────────────┐    ┌─────────────┐
                    │   Poller    │───▶│   Agent     │
                    └─────────────┘    └─────────────┘
                           │
                    ┌─────────────┐
                    │ SNMP Checker│
                    └─────────────┘
```

### Data Flow
1. **Web** → **Core**: User requests via REST API
2. **Core** → **Proton**: Database queries and analytics
3. **Core** → **NATS**: Event publishing and subscriptions
4. **Poller** → **Agent**: Orchestrates monitoring tasks
5. **Agent** → **Core**: Reports monitoring results
6. **SNMP Checker** → **Core**: SNMP monitoring data

## Scaling

### Resource Requirements
Default resource allocations:
- **Core**: 500m CPU, 512Mi RAM (limits: 2 CPU, 2Gi RAM)
- **Proton**: 1 CPU, 4Gi RAM (limits: 4 CPU, 8Gi RAM)
- **Web**: 100m CPU, 128Mi RAM (limits: 500m CPU, 512Mi RAM)
- **Others**: 50m CPU, 64Mi RAM (limits: 200m CPU, 256Mi RAM)

### Horizontal Scaling
Most services support horizontal scaling:
```bash
kubectl scale deployment serviceradar-core --replicas=3 -n serviceradar-staging
kubectl scale deployment serviceradar-web --replicas=2 -n serviceradar-staging
```

**Note**: Proton should remain at 1 replica for data consistency.

## Persistence

### Persistent Volumes
- **Proton Data**: 1Ti for analytics storage (local-path); resize via `k8s/demo/resize-proton-pvc.sh`
- **Core Data**: 5Gi for application metadata
- **NATS Data**: 30Gi for message persistence
- **Certificates**: 1Gi shared TLS material

### Backup Considerations
- Regular backups of Proton database recommended
- Core application data contains configuration and state
- NATS data is transient and can be rebuilt

## Troubleshooting

### Common Issues

1. **Pod startup failures**
   ```bash
   kubectl logs -n serviceradar-staging <pod-name>
   kubectl describe pod -n serviceradar-staging <pod-name>
   ```

2. **Certificate issues**
   ```bash
   kubectl logs -n serviceradar-staging job/serviceradar-cert-generator
   kubectl get certificates -n serviceradar-staging
   ```

3. **Database connectivity**
   ```bash
   kubectl exec -it -n serviceradar-staging deployment/serviceradar-core -- \
     grpcurl -cacert /etc/serviceradar/certs/root.pem \
     -cert /etc/serviceradar/certs/core.pem \
     -key /etc/serviceradar/certs/core-key.pem \
     -servername proton.serviceradar \
     serviceradar-proton:9440 grpc.health.v1.Health/Check
   ```

### Health Checks
All services include comprehensive health checks:
- **Liveness probes**: Restart unhealthy containers
- **Readiness probes**: Remove unhealthy endpoints from load balancing

## Maintenance

### Updates
To update ServiceRadar:
1. Update image tags in deployment manifests
2. Run `kubectl apply -k base/ -n serviceradar-staging`
3. Monitor rollout: `kubectl rollout status deployment -n serviceradar-staging`

### Configuration Changes
To update configuration:
1. Modify settings in `deploy.sh` configmap section
2. Run `./deploy.sh` to apply changes
3. Restart affected deployments:
   ```bash
   kubectl rollout restart deployment/serviceradar-core -n serviceradar-staging
   ```

#### Toggling Feature Flags (ConfigMap)
Feature flags (including the device search planner) are sourced from the `serviceradar-config` ConfigMap:

1. Edit the ConfigMap to update `core.json` (for core flags) or other entries as needed:
   ```bash
   kubectl edit configmap serviceradar-config -n serviceradar-staging
   ```
2. Locate the `features` block and adjust values, for example:
   ```json
   "features": {
     "use_log_digest": true,
     "use_device_search_planner": true
   }
   ```
3. Restart the component that reads the config:
   ```bash
   kubectl rollout restart deployment/serviceradar-core -n serviceradar-staging
   ```
4. For web UI flags (e.g. `NEXT_PUBLIC_FEATURE_DEVICE_SEARCH_PLANNER`), update the environment variables on the deployment:
   ```bash
   kubectl set env deployment/serviceradar-web NEXT_PUBLIC_FEATURE_DEVICE_SEARCH_PLANNER=true FEATURE_DEVICE_SEARCH_PLANNER=true -n serviceradar-staging
   kubectl rollout restart deployment/serviceradar-web -n serviceradar-staging
   ```

Changes made via `deploy.sh` are persisted to the ConfigMap; remember to re-run the script if the base configuration is updated in source control.

## Production Considerations

### Security Hardening
- Use network policies to restrict inter-pod communication
- Enable pod security standards
- Regularly rotate secrets and certificates
- Use private image registries
- Enable audit logging

### Monitoring
- Deploy Prometheus/Grafana for metrics
- Configure log aggregation (ELK stack recommended)
- Set up alerting for critical service failures
- Monitor certificate expiration

### High Availability
- Deploy across multiple availability zones
- Use pod disruption budgets
- Configure anti-affinity rules
- Implement proper backup and disaster recovery

## Support

For issues and questions:
1. Check logs: `kubectl logs -n serviceradar-staging <service-name>`
2. Verify configuration: `kubectl get configmap serviceradar-config -o yaml`
3. Check secrets: `kubectl get secret serviceradar-secrets -o yaml`
4. Review ingress: `kubectl describe ingress serviceradar-staging`

This deployment has been tested and validated as production-ready with automatic secret generation, secure defaults, and comprehensive health monitoring.
