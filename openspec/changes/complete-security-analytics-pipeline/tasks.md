## 1. Falco decomposition completeness
- [x] 1.1 Decouple promote_to_event? (always) from promote_to_alert? (gated) in falco_events.ex
- [x] 1.2 Falco rule → OCSF class map (default 2004) in falco_events.ex / ocsf.ex
- [x] 1.3 Stable finding identity / grouping contract; SRQL catalog + frames updated
- [x] 1.4 Extract shared FalcoDecomposition module (dedupe falco_events.ex vs log_promotion.ex)
- [x] 1.5 MITRE ATT&CK tactic/technique parsing from Falco tags into OCSF attacks[]
- [x] 1.6 Remove or wire the orphaned priv/zen/rules/falco_normalize.json
- [x] 1.7 Tests: low-severity promotion, class mapping, finding grouping

## 2. Security page vs dashboard division
- [x] 2.1 Reframe /security as triage shell; strip duplicated inline SRQL probes
- [x] 2.2 security-findings dashboard is the single data surface
- [x] 2.3 Document the division in spec + docs

## 3. Dashboard performance
- [x] 3.1 FrameRunner.run/3 → bounded Task.async_stream (order + error semantics preserved)
- [x] 3.2 security-findings manifest: collapse/defer the 8 limit:1 probe frames (required:false)
- [x] 3.3 dashboard_frame_channel: concurrent refresh + hash-skip unchanged frames
- [x] 3.4 Index review for in:security_findings/scan_activity/dns_activity (source/class_uid, time desc)

## 4. Advisory feed producers (NVD / CISA KEV / VulnCheck)
- [x] 4.1 Decide execution model (native Go add-on vs Wasm) — design.md
- [x] 4.2 CISA KEV producer first (smallest proof: single JSON, no key) end-to-end
- [x] 4.3 NVD producer (CVE 2.0 API, CPE coordinates, API-key credential)
- [x] 4.4 VulnCheck producer (KEV+NVD enriched, PURL/CPE, token credential)
- [x] 4.5 Verify ProducerScheduleCatalog.sync_package materializes schedules on import/update
- [x] 4.6 Package + sign via native-addon/Wasm delivery; BUILD.bazel deps
