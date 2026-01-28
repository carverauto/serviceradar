## 1. Implementation
- [ ] 1.1 Decide migration runner approach (one-shot container vs core-elx flag) and document in design.md
- [ ] 1.2 Add privileged migration configuration to Docker Compose (credentials + runner)
- [ ] 1.3 Remove ServiceRadar-specific SQL from compose CNPG init scripts
- [ ] 1.4 Update docker-compose.yml and any overlays that include CNPG services
- [ ] 1.5 Add privileged migration configuration to Helm/Kubernetes (secret + Job/init container)
- [ ] 1.6 Update Helm values/manifests to gate core/web-ng on migration completion
- [ ] 1.7 Ensure core/web-ng/datasvc use least-privilege app role in compose and k8s
- [ ] 1.8 Update docs/runbooks for compose + k8s boot expectations
- [ ] 1.9 Add/adjust tests or smoke checks for clean compose boot
