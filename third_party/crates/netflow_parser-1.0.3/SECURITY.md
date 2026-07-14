# Security Policy

## Supported Versions

We actively maintain and provide security updates for the following versions:

| Version | Supported          | Status |
|---------|--------------------| ------ |
| 0.8.x   | :white_check_mark: | Current stable release |
| 0.7.x   | :white_check_mark: | Security fixes only |
| < 0.7.0 | :x:                | No longer supported |

**Note:** We strongly recommend upgrading to the latest 0.8.x release to receive the latest security improvements and bug fixes.

## Reporting a Vulnerability

We take security vulnerabilities seriously. If you discover a security issue in netflow_parser, please follow responsible disclosure practices.

### Where to Report

**DO NOT** open a public GitHub issue for security vulnerabilities. Instead, please report security issues via one of the following methods:

1. **Email (Preferred):** Send details to [michael.mileusnich@gmail.com](mailto:michael.mileusnich@gmail.com)
   - Subject line: `[SECURITY] netflow_parser - <brief description>`
   - Include "SECURITY" in the subject to ensure priority handling

2. **GitHub Security Advisory:** Use the [GitHub Security Advisory](https://github.com/mikemiles-dev/netflow_parser/security/advisories/new) feature for private disclosure

### What to Include

Please provide as much information as possible to help us understand and reproduce the issue:

- **Description:** Clear description of the vulnerability
- **Impact:** What could an attacker achieve?
- **Affected Versions:** Which versions are affected?
- **Reproduction Steps:** Detailed steps to reproduce the issue
- **Proof of Concept:** Code or packet samples demonstrating the vulnerability (if applicable)
- **Suggested Fix:** If you have ideas for remediation (optional)
- **CVE Request:** Let us know if you plan to request a CVE identifier

### Security Scope

The following are considered within scope for security reports:

- **Memory Safety Issues:** Buffer overflows, use-after-free, out-of-bounds access
- **Denial of Service (DoS):** Malformed packets causing crashes, panics, or excessive resource consumption
- **Parser Vulnerabilities:** Issues in NetFlow V5/V7/V9/IPFIX parsing logic
- **Template Handling:** Template cache poisoning, collision attacks, or memory exhaustion
- **Data Validation:** Missing bounds checks, integer overflows, malicious field values

**Out of Scope:**
- Issues requiring physical access to the system
- Social engineering attacks
- Third-party dependency vulnerabilities (please report to the dependency maintainers)
- Issues in example code (unless they demonstrate a library vulnerability)

## Response Timeline

We are committed to addressing security issues promptly:

- **Initial Response:** Within 48 hours of report receipt
- **Status Update:** Within 5 business days with assessment and timeline
- **Patch Development:** Critical vulnerabilities prioritized for immediate patching
- **Public Disclosure:** Coordinated disclosure after patch is available (typically 30-90 days)

## Security Update Process

When a security vulnerability is confirmed:

1. **Assessment:** We evaluate severity using CVSS v3.1 scoring
2. **Patch Development:** Fix is developed and tested privately
3. **CVE Assignment:** We request a CVE identifier if warranted
4. **Release:** Security patch released as soon as possible
5. **Advisory Publication:** GitHub Security Advisory published with details
6. **Notification:** Security fix announced in release notes

### Severity Classification

- **Critical:** Remote code execution, authentication bypass
- **High:** DoS affecting availability, memory safety issues
- **Medium:** Information disclosure, limited DoS
- **Low:** Issues with minimal security impact

## CVE Reporting

### Requesting a CVE

If you believe the vulnerability warrants a CVE identifier:

1. **Mention in Report:** Indicate in your initial report that you'd like a CVE assigned
2. **We Handle Assignment:** We will request a CVE through GitHub's CNA or MITRE
3. **Coordination:** We'll work with you to ensure proper attribution

### Our CVE Process

As a project, we:

- Request CVE identifiers for confirmed security vulnerabilities
- Use GitHub's CVE Numbering Authority (CNA) when possible
- Publish CVE details in GitHub Security Advisories
- Reference CVEs in release notes and CHANGELOG

## Security Best Practices

When using netflow_parser:

### Input Validation

- **Untrusted Sources:** Always parse NetFlow data from untrusted sources with caution
- **Rate Limiting:** Implement rate limiting on incoming packets
- **Packet Size Limits:** Enforce maximum packet size limits before parsing

### Configuration Hardening

```rust
use netflow_parser::NetflowParser;
use std::time::Duration;

// Recommended security configuration
let parser = NetflowParser::builder()
    // Limit template cache to prevent memory exhaustion
    .with_cache_size(1000)

    // Limit fields per template (DoS protection)
    .with_max_field_count(5000)

    // Limit error sample size (prevents memory exhaustion)
    .with_max_error_sample_size(256)

    // Enable template TTL for long-running parsers
    .with_ttl(TtlConfig::new(Duration::from_secs(7200)))

    .build()
    .expect("Failed to build parser");
```

### Multi-Source Deployments

- **Use Scoped Parsing:** Use `AutoScopedParser` to prevent template cache poisoning
- **Isolate Sources:** Ensure proper isolation between different NetFlow sources
- **Monitor Cache Metrics:** Watch for unusual collision rates indicating attacks

### Resource Limits

- **Memory Bounds:** Monitor memory usage in production
- **Template Limits:** Configure appropriate cache sizes for your deployment
- **Error Handling:** Properly handle parse errors to prevent crashes

## Known Security Considerations

### Denial of Service Protection

The parser includes several DoS mitigations:

- **Template Field Count Limit:** Default 10,000 fields per template
- **Template Total Size Validation:** Maximum 65,535 bytes per template
- **Error Sample Size Limit:** Default 256 bytes to prevent memory exhaustion
- **LRU Template Cache:** Prevents unbounded cache growth
- **Duplicate Field Detection:** Rejects malformed templates

### Memory Safety

- **Memory-Safe Language:** Written in Rust with strong memory safety guarantees
- **Bounds Checking:** All buffer accesses are bounds-checked
- **No Unsafe Code:** Library avoids `unsafe` where possible

## Acknowledgments

We appreciate security researchers who responsibly disclose vulnerabilities. With your permission, we will acknowledge your contribution in:

- GitHub Security Advisory
- Release notes
- CHANGELOG.md
- This security policy (Hall of Fame section below)

### Hall of Fame

Security researchers who have responsibly disclosed vulnerabilities:

*None yet - be the first!*

## Questions?

If you have questions about this security policy or need clarification on the reporting process, please contact [michael.mileusnich@gmail.com](mailto:michael.mileusnich@gmail.com).

## References

- **GitHub Security Advisories:** https://github.com/mikemiles-dev/netflow_parser/security/advisories
- **CVE Database:** https://cve.mitre.org/
- **Rust Security Database:** https://rustsec.org/ 
