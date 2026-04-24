## 1. Discovery
- [x] 1.1 Locate current session/token TTL settings in core-elx and web-ng
- [x] 1.2 Identify how session refresh works today and where expiration is enforced
- [x] 1.3 Capture current default values and environment overrides

## 2. Implementation
- [x] 2.1 Add configurable idle timeout and absolute timeout in auth configuration
- [x] 2.2 Implement session refresh on authenticated requests within the idle window
- [x] 2.3 Align web-ng cookie/session storage max-age with server TTLs
- [x] 2.4 Add expiration reason logging or telemetry
- [x] 2.5 Add or update tests for idle and absolute expiration behavior

## 3. Verification
- [ ] 3.1 Manual login/session duration test in web-ng
- [ ] 3.2 Regression test for logout behavior
