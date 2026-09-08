# Tasks: Improve Edge Onboarding UX

## 1. Wire Up Automatic Certificate Generation

- [x] 1.1 Add `create_with_tenant_cert/2` wrapper to `ServiceRadarWebNG.Edge.OnboardingPackages`
- [x] 1.2 Update LiveView `create_package` handler to call `create_with_tenant_cert/2`
- [x] 1.3 Pass tenant_id from `current_scope.user.tenant_id` to the create function
- [x] 1.4 Handle CA generation errors gracefully with user-friendly messages
- [x] 1.5 Add loading state while CA generation is in progress

## 2. Simplify Package Creation Form

- [x] 2.1 Remove certificate-related fields from the creation form
- [x] 2.2 Auto-generate component_id based on label and component_type
- [x] 2.3 Add clear help text explaining what happens on creation
- [x] 2.4 Show success state with certificate fingerprint after creation

## 3. Improve Package Delivery UX

- [x] 3.1 Add "Download Bundle" button that creates a .tar.gz with all files
- [x] 3.2 Include platform-specific install script in bundle (install.sh)
- [x] 3.3 Add copy-to-clipboard for one-liner install commands
- [x] 3.4 Show token expiration countdown on package details
- [x] 3.5 Add bundle file listing in success modal (what's included)

## 4. Package Bundle Content

- [x] 4.1 Create bundle generator module for packaging certs + config
- [x] 4.2 Include component.pem (certificate)
- [x] 4.3 Include component-key.pem (private key)
- [x] 4.4 Include ca-chain.pem (trust chain)
- [x] 4.5 Include config.yaml with component settings
- [x] 4.6 Include install.sh with platform detection

## 5. Install Script Templates

- [x] 5.1 Create Docker-based install script template
- [x] 5.2 Create systemd-based install script template
- [x] 5.3 Create Kubernetes manifest template
- [x] 5.4 Add environment variable substitution in templates

## 6. Testing

- [x] 6.1 Unit tests for wrapper module delegation
- [x] 6.2 LiveView tests for create flow with certificates
- [x] 6.3 Integration test for full onboarding flow
- [x] 6.4 Test CA auto-generation on first package creation

## 7. Documentation

- [x] 7.1 Update edge onboarding docs with new UI flow
- [ ] 7.2 Add screenshots of new package creation flow (requires manual UI screenshots)
- [x] 7.3 Document the zero-touch provisioning process
