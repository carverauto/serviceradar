## 1. Make ICMP ping advisory instead of a hard gate

- [x] 1.1 In `discovery.go` `startWorkers`, change the ping pre-check from `continue` (skip target) to an info log, then proceed to SNMP scan regardless of ping result
- [x] 1.2 ~~Add a per-target log at Info level when SNMP connect succeeds after ping failure~~ Covered by existing SNMP scan logging — the Info-level "ICMP ping failed, proceeding to SNMP" log provides the necessary visibility
- [x] 1.3 ~~Keep the ping result available for metadata~~ Deferred — not needed for this fix; SNMP connect failure naturally skips unreachable targets

## 2. Verify discovery results flow for UniFi-discovered devices

- [ ] 2.1 After deploying the fix, run a discovery job and confirm SNMP walks complete for UniFi-discovered devices (interfaces, sysDescr, vendor populated)
- [ ] 2.2 Verify interfaces appear in the `discovered_interfaces` table for previously-missing devices
