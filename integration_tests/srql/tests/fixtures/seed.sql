-- Canonical SRQL device fixture rows (OCSF v1.7.0 aligned).
-- Assessments, matches, and inventory packages reference endpoint_packages;
-- assertions, matches, and coordinates reference vulnerability_advisories.
-- Postgres requires every referencing table in the same TRUNCATE statement,
-- even when a referencing table is already empty. ocsf_devices is referenced
-- by device_agent_availability and the virtualization_* tables, so CASCADE.
TRUNCATE endpoint_vulnerability_assessments, endpoint_vulnerability_matches,
    advisory_package_assertions, advisory_coordinates, vulnerability_advisories,
    endpoint_inventory_packages, endpoint_packages;
TRUNCATE endpoint_inventory_scans;
TRUNCATE endpoint_inventory_current_package_counts;
TRUNCATE endpoint_inventory_current_cpe_counts;
TRUNCATE endpoint_inventory_package_counts_hourly;
TRUNCATE endpoint_inventory_cpe_counts_hourly;
TRUNCATE public.ocsf_devices CASCADE;
WITH base AS (
    SELECT NOW() AS now_ts
)
INSERT INTO public.ocsf_devices (
        uid,
        type_id,
        type,
        name,
        hostname,
        ip,
        mac,
        vendor_name,
        model,
        first_seen_time,
        last_seen_time,
        created_time,
        modified_time,
        risk_level_id,
        risk_level,
        os,
        gateway_id,
        agent_id,
        availability_source_agent_id,
        discovery_sources,
        is_available,
        is_active,
        metadata,
        tags
    )
SELECT 'device-alpha',
    12,  -- Router
    'Router',
    'Alpha Edge Router',
    'alpha-edge',
    '10.10.10.5',
    'aa:bb:cc:dd:ee:01',
    'Cisco',
    'ISR 4451',
    base.now_ts - INTERVAL '14 days',
    base.now_ts - INTERVAL '30 minutes',
    base.now_ts - INTERVAL '14 days',
    base.now_ts - INTERVAL '30 minutes',
    0,  -- Info
    'Info',
    '{"name":"IOS-XE","version":"17.9.3"}'::jsonb,
    'gateway-1',
    'agent-1',
    'agent-1',
    ARRAY ['sweep','armis'],
    TRUE,
    TRUE,
    '{"site":"dfw-edge","packet_loss_bucket":"low"}'::jsonb,
    '{"site":"DFW","Gate":"A1","role":"edge"}'::jsonb
FROM base
UNION ALL
SELECT 'device-beta',
    10,  -- Switch
    'Switch',
    'Beta Core Switch',
    'beta-core',
    '10.10.20.6',
    'aa:bb:cc:dd:ee:02',
    'Cisco',
    'Nexus 9300',
    base.now_ts - INTERVAL '10 days',
    base.now_ts - INTERVAL '3 hours',
    base.now_ts - INTERVAL '10 days',
    base.now_ts - INTERVAL '3 hours',
    2,  -- Medium
    'Medium',
    '{"name":"NX-OS","version":"10.2(4)"}'::jsonb,
    'gateway-1',
    'agent-2',
    NULL,
    ARRAY ['armis'],
    FALSE,
    FALSE,
    '{"site":"dfw-edge","packet_loss_bucket":"medium"}'::jsonb,
    '{"site":"DFW","Gate":"A1","role":"core"}'::jsonb
FROM base
UNION ALL
SELECT 'device-gamma',
    9,  -- Firewall
    'Firewall',
    'Gamma Edge Firewall',
    'gamma-edge',
    '10.10.30.7',
    'aa:bb:cc:dd:ee:03',
    'Palo Alto Networks',
    'PA-5220',
    base.now_ts - INTERVAL '6 days',
    base.now_ts - INTERVAL '2 hours',
    base.now_ts - INTERVAL '6 days',
    base.now_ts - INTERVAL '2 hours',
    3,  -- High
    'High',
    '{"name":"PAN-OS","version":"11.1.0"}'::jsonb,
    'gateway-2',
    'agent-3',
    NULL,
    ARRAY ['sweep'],
    TRUE,
    TRUE,
    '{"site":"phx-edge","packet_loss_bucket":"high"}'::jsonb,
    '{"site":"DFW","Gate":"B2","role":"edge"}'::jsonb
FROM base
UNION ALL
SELECT 'device-delta',
    10,  -- Switch
    'Switch',
    'Delta Legacy Switch',
    'delta-legacy',
    '10.10.40.8',
    'aa:bb:cc:dd:ee:04',
    'Cisco',
    'Catalyst 3850',
    base.now_ts - INTERVAL '20 days',
    base.now_ts - INTERVAL '8 days',
    base.now_ts - INTERVAL '20 days',
    base.now_ts - INTERVAL '8 days',
    0,  -- Info
    'Info',
    '{"name":"IOS","version":"15.2"}'::jsonb,
    'gateway-2',
    'agent-3',
    NULL,
    ARRAY ['sweep'],
    TRUE,
    TRUE,
    '{"site":"phx-edge","packet_loss_bucket":"low"}'::jsonb,
    '{}'::jsonb
FROM base;

WITH base AS (
    SELECT NOW() AS now_ts
)
INSERT INTO endpoint_inventory_scans (
    id,
    device_uid,
    agent_id,
    scan_id,
    collector_name,
    collector_version,
    state,
    coverage_state,
    package_count,
    enabled_sources,
    manager_counts,
    source_summaries,
    artifact_count,
    current,
    last_successful_scan_at,
    last_scan_at,
    last_changed_scan_at,
    ingested_at,
    package_set_hash,
    artifact_hash,
    hash_algorithm,
    upload_reason,
    server_package_set_hash,
    package_set_hash_mismatch,
    unchanged_scan_count,
    reconcile_floor_due,
    metadata,
    inserted_at,
    updated_at
)
SELECT 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'::uuid,
    'device-alpha',
    'agent-1',
    'scan-current',
    'serviceradar-endpoint-inventory',
    '1.0.0',
    'scanned',
    'complete',
    2,
    ARRAY ['dpkg'],
    '{"dpkg":2}'::jsonb,
    ARRAY ['{"source":"dpkg","state":"scanned","package_count":2}'::jsonb],
    1,
    TRUE,
    base.now_ts - INTERVAL '20 minutes',
    base.now_ts - INTERVAL '20 minutes',
    base.now_ts - INTERVAL '20 minutes',
    base.now_ts - INTERVAL '19 minutes',
    'sha256:current-package-set',
    'sha256:current-artifact',
    'sha256-v1',
    'changed',
    'sha256:current-package-set',
    FALSE,
    0,
    FALSE,
    '{"fixture":"current"}'::jsonb,
    base.now_ts - INTERVAL '20 minutes',
    base.now_ts - INTERVAL '20 minutes'
FROM base
UNION ALL
SELECT 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'::uuid,
    'device-alpha',
    'agent-1',
    'scan-historical',
    'serviceradar-endpoint-inventory',
    '1.0.0',
    'scanned',
    'complete',
    1,
    ARRAY ['dpkg'],
    '{"dpkg":1}'::jsonb,
    ARRAY ['{"source":"dpkg","state":"scanned","package_count":1}'::jsonb],
    1,
    FALSE,
    base.now_ts - INTERVAL '2 days',
    base.now_ts - INTERVAL '2 days',
    base.now_ts - INTERVAL '2 days',
    base.now_ts - INTERVAL '2 days',
    'sha256:historical-package-set',
    'sha256:historical-artifact',
    'sha256-v1',
    'changed',
    'sha256:historical-package-set',
    FALSE,
    0,
    FALSE,
    '{"fixture":"historical"}'::jsonb,
    base.now_ts - INTERVAL '2 days',
    base.now_ts - INTERVAL '2 days'
FROM base;

WITH base AS (
    SELECT NOW() AS now_ts
)
INSERT INTO endpoint_packages (
    id,
    coordinate_key,
    purl_canonical,
    primary_cpe,
    cpes,
    package_manager,
    name,
    version,
    architecture,
    ecosystem,
    source_scope,
    metadata,
    inserted_at,
    updated_at
)
SELECT 'aaaaaaaa-1111-4111-8111-111111111111'::uuid,
    'purl:pkg:deb/nginx@1.24.0-2ubuntu7',
    'pkg:deb/nginx@1.24.0-2ubuntu7',
    'cpe:2.3:a:nginx:nginx:1.24.0:*:*:*:*:*:*:*',
    ARRAY ['cpe:2.3:a:nginx:nginx:1.24.0:*:*:*:*:*:*:*'],
    'dpkg',
    'nginx',
    '1.24.0-2ubuntu7',
    'amd64',
    'deb',
    'host',
    '{"fixture":"catalog"}'::jsonb,
    base.now_ts - INTERVAL '20 minutes',
    base.now_ts - INTERVAL '20 minutes'
FROM base
UNION ALL
SELECT 'aaaaaaaa-2222-4222-8222-222222222222'::uuid,
    'purl:pkg:deb/openssl@3.0.13-0ubuntu3.5',
    'pkg:deb/openssl@3.0.13-0ubuntu3.5',
    'cpe:2.3:a:openssl:openssl:3.0.13:*:*:*:*:*:*:*',
    ARRAY ['cpe:2.3:a:openssl:openssl:3.0.13:*:*:*:*:*:*:*'],
    'dpkg',
    'openssl',
    '3.0.13-0ubuntu3.5',
    'amd64',
    'deb',
    'host',
    '{"fixture":"catalog"}'::jsonb,
    base.now_ts - INTERVAL '20 minutes',
    base.now_ts - INTERVAL '20 minutes'
FROM base
UNION ALL
SELECT 'aaaaaaaa-3333-4333-8333-333333333333'::uuid,
    'purl:pkg:deb/nginx@1.22.1-9',
    'pkg:deb/nginx@1.22.1-9',
    'cpe:2.3:a:nginx:nginx:1.22.1:*:*:*:*:*:*:*',
    ARRAY ['cpe:2.3:a:nginx:nginx:1.22.1:*:*:*:*:*:*:*'],
    'dpkg',
    'nginx',
    '1.22.1-9',
    'amd64',
    'deb',
    'host',
    '{"fixture":"catalog"}'::jsonb,
    base.now_ts - INTERVAL '2 days',
    base.now_ts - INTERVAL '2 days'
FROM base;

WITH base AS (
    SELECT NOW() AS now_ts
)
INSERT INTO endpoint_inventory_packages (
    id,
    scan_ref,
    device_uid,
    agent_id,
    name,
    version,
    architecture,
    package_manager,
    ecosystem,
    purl,
    purl_canonical,
    endpoint_package_ref,
    cpes,
    supplier,
    license,
    source,
    evidence,
    current,
    metadata,
    inserted_at,
    updated_at
)
SELECT '11111111-1111-4111-8111-111111111111'::uuid,
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'::uuid,
    'device-alpha',
    'agent-1',
    'nginx',
    '1.24.0-2ubuntu7',
    'amd64',
    'dpkg',
    'deb',
    'pkg:deb/nginx@1.24.0-2ubuntu7',
    'pkg:deb/nginx@1.24.0-2ubuntu7',
    'aaaaaaaa-1111-4111-8111-111111111111'::uuid,
    ARRAY ['cpe:2.3:a:nginx:nginx:1.24.0:*:*:*:*:*:*:*'],
    'nginx',
    'BSD-2-Clause',
    '/var/lib/dpkg/status',
    '{"method":"dpkg-query"}'::jsonb,
    TRUE,
    '{"scan":"current"}'::jsonb,
    base.now_ts - INTERVAL '20 minutes',
    base.now_ts - INTERVAL '20 minutes'
FROM base
UNION ALL
SELECT '22222222-2222-4222-8222-222222222222'::uuid,
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'::uuid,
    'device-alpha',
    'agent-1',
    'openssl',
    '3.0.13-0ubuntu3.5',
    'amd64',
    'dpkg',
    'deb',
    'pkg:deb/openssl@3.0.13-0ubuntu3.5',
    'pkg:deb/openssl@3.0.13-0ubuntu3.5',
    'aaaaaaaa-2222-4222-8222-222222222222'::uuid,
    ARRAY ['cpe:2.3:a:openssl:openssl:3.0.13:*:*:*:*:*:*:*'],
    'OpenSSL Project',
    'Apache-2.0',
    '/var/lib/dpkg/status',
    '{"method":"dpkg-query"}'::jsonb,
    TRUE,
    '{"scan":"current"}'::jsonb,
    base.now_ts - INTERVAL '20 minutes',
    base.now_ts - INTERVAL '20 minutes'
FROM base
UNION ALL
SELECT '44444444-4444-4444-8444-444444444444'::uuid,
    'cccccccc-cccc-4ccc-8ccc-cccccccccccc'::uuid,
    'device-gamma',
    'agent-3',
    'nginx',
    '1.24.0-2ubuntu7',
    'amd64',
    'dpkg',
    'deb',
    'pkg:deb/nginx@1.24.0-2ubuntu7',
    'pkg:deb/nginx@1.24.0-2ubuntu7',
    'aaaaaaaa-1111-4111-8111-111111111111'::uuid,
    ARRAY ['cpe:2.3:a:nginx:nginx:1.24.0:*:*:*:*:*:*:*'],
    'nginx',
    'BSD-2-Clause',
    '/var/lib/dpkg/status',
    '{"method":"dpkg-query","fixture":"cross-device-correlation"}'::jsonb,
    TRUE,
    '{"scan":"current"}'::jsonb,
    base.now_ts - INTERVAL '20 minutes',
    base.now_ts - INTERVAL '20 minutes'
FROM base
UNION ALL
SELECT '33333333-3333-4333-8333-333333333333'::uuid,
    'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'::uuid,
    'device-alpha',
    'agent-1',
    'nginx',
    '1.22.1-9',
    'amd64',
    'dpkg',
    'deb',
    'pkg:deb/nginx@1.22.1-9',
    'pkg:deb/nginx@1.22.1-9',
    'aaaaaaaa-3333-4333-8333-333333333333'::uuid,
    ARRAY ['cpe:2.3:a:nginx:nginx:1.22.1:*:*:*:*:*:*:*'],
    'nginx',
    'BSD-2-Clause',
    '/var/lib/dpkg/status',
    '{"method":"dpkg-query"}'::jsonb,
    FALSE,
    '{"scan":"historical"}'::jsonb,
    base.now_ts - INTERVAL '2 days',
    base.now_ts - INTERVAL '2 days'
FROM base;

WITH base AS (
    SELECT NOW() AS now_ts
)
INSERT INTO vulnerability_advisories (
    id,
    provider,
    feed_key,
    source_object_id,
    advisory_id,
    cve_id,
    title,
    description,
    severity,
    cvss_score,
    cvss_vector,
    published_at,
    modified_at,
    kev,
    exploit_available,
    affected_coordinates,
    "references",
    metadata,
    raw,
    generation,
    current
)
SELECT
    'bbbbbbbb-1111-4111-8111-111111111111'::uuid,
    'vulncheck',
    'nist-nvd2',
    'CVE-2026-0001',
    'CVE-2026-0001',
    'CVE-2026-0001',
    'nginx HTTP/2 memory corruption',
    'A memory corruption issue in nginx 1.24.',
    'critical',
    9.8,
    'CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H',
    base.now_ts - INTERVAL '10 days',
    base.now_ts - INTERVAL '2 days',
    TRUE,
    TRUE,
    ARRAY[]::jsonb[],
    ARRAY['https://nvd.nist.gov/vuln/detail/CVE-2026-0001'],
    '{"due_date":"2026-02-01","epss_score":0.84,"ransomware_use":"unknown"}'::jsonb,
    '{"nvd":"omitted-from-srql"}'::jsonb,
    1,
    TRUE
FROM base
UNION ALL
SELECT
    'bbbbbbbb-2222-4222-8222-222222222222'::uuid,
    'vulncheck',
    'nist-nvd2',
    'CVE-2026-0001-stale',
    'CVE-2026-0001',
    'CVE-2026-0001',
    'stale generation',
    'Should be hidden by current:true default.',
    'critical',
    9.8,
    NULL,
    base.now_ts - INTERVAL '40 days',
    base.now_ts - INTERVAL '40 days',
    FALSE,
    FALSE,
    ARRAY[]::jsonb[],
    ARRAY[]::text[],
    '{}'::jsonb,
    '{"stale":true}'::jsonb,
    0,
    FALSE
FROM base;

INSERT INTO advisory_package_assertions (
    id,
    assertion_key,
    advisory_ref,
    provider,
    feed_key,
    generation,
    cve_id,
    authority,
    source_kind,
    package_type,
    namespace,
    release,
    source_package,
    disposition,
    fixed_version
)
VALUES (
    'ffffffff-1111-4111-8111-111111111111'::uuid,
    'ubuntu:noble:openssl:CVE-2026-0001',
    'bbbbbbbb-1111-4111-8111-111111111111'::uuid,
    'ubuntu',
    'ubuntu-osv-vex',
    7,
    'CVE-2026-0001',
    'Ubuntu',
    'osv',
    'deb',
    'ubuntu',
    'noble',
    'openssl',
    'affected',
    '3.0.13-0ubuntu3.6'
);

INSERT INTO advisory_coordinates (
    id,
    advisory_ref,
    provider,
    feed_key,
    generation,
    coordinate_type,
    value,
    cpe_part,
    cpe_vendor,
    cpe_product,
    cpe_version,
    version_start,
    version_start_inclusive,
    version_end,
    version_end_inclusive
)
VALUES
    (
        'cccccccc-1111-4111-8111-111111111111'::uuid,
        'bbbbbbbb-1111-4111-8111-111111111111'::uuid,
        'vulncheck',
        'nist-nvd2',
        1,
        'cpe',
        'cpe:2.3:a:nginx:nginx:*:*:*:*:*:*:*:*',
        'a',
        'nginx',
        'nginx',
        '*',
        '1.24.0',
        TRUE,
        '1.25.0',
        FALSE
    ),
    (
        'cccccccc-2222-4222-8222-222222222222'::uuid,
        'bbbbbbbb-1111-4111-8111-111111111111'::uuid,
        'vulncheck',
        'nist-nvd2',
        1,
        'cpe',
        'cpe:2.3:a:nginx:nginx:1.24.0:*:*:*:*:*:*:*',
        'a',
        'nginx',
        'nginx',
        '1.24.0',
        NULL,
        NULL,
        NULL,
        NULL
    );

WITH base AS (
    SELECT NOW() AS now_ts
)
INSERT INTO endpoint_vulnerability_matches (
    id,
    device_uid,
    agent_id,
    inventory_package_ref,
    endpoint_package_ref,
    advisory_ref,
    provider,
    feed_key,
    advisory_id,
    cve_id,
    coordinate_type,
    coordinate_value,
    version_evidence,
    confidence,
    status,
    severity,
    cvss_score,
    kev,
    exploit_available,
    evidence,
    first_seen_at,
    last_seen_at,
    metadata
)
SELECT
    'dddddddd-1111-4111-8111-111111111111'::uuid,
    'device-alpha',
    'agent-1',
    '11111111-1111-4111-8111-111111111111'::uuid,
    'aaaaaaaa-1111-4111-8111-111111111111'::uuid,
    'bbbbbbbb-1111-4111-8111-111111111111'::uuid,
    'vulncheck',
    'nist-nvd2',
    'CVE-2026-0001',
    'CVE-2026-0001',
    'cpe',
    'cpe:2.3:a:nginx:nginx:1.24.0:*:*:*:*:*:*:*',
    '{"installed":"1.24.0-2ubuntu7"}'::jsonb,
    'high',
    'active',
    'critical',
    9.8,
    TRUE,
    TRUE,
    '{"matcher":"cpe"}'::jsonb,
    base.now_ts - INTERVAL '1 day',
    base.now_ts - INTERVAL '20 minutes',
    '{"due_date":"2026-02-01","epss_score":0.84,"ransomware_use":"unknown"}'::jsonb
FROM base
UNION ALL
SELECT
    'dddddddd-2222-4222-8222-222222222222'::uuid,
    'device-gamma',
    'agent-3',
    NULL::uuid,
    'aaaaaaaa-2222-4222-8222-222222222222'::uuid,
    'bbbbbbbb-2222-4222-8222-222222222222'::uuid,
    'vulncheck',
    'nist-nvd2',
    'CVE-2026-0001',
    'CVE-2026-0001',
    'cpe',
    'cpe:2.3:a:openssl:openssl:3.0.13:*:*:*:*:*:*:*',
    '{"installed":"3.0.13-0ubuntu3.5"}'::jsonb,
    'high',
    'active',
    'critical',
    9.8,
    TRUE,
    TRUE,
    '{"matcher":"cpe","regression_child":1}'::jsonb,
    base.now_ts - INTERVAL '3 hours',
    base.now_ts - INTERVAL '3 hours',
    '{}'::jsonb
FROM base
UNION ALL
SELECT
    'dddddddd-3333-4333-8333-333333333333'::uuid,
    'device-gamma',
    'agent-3',
    NULL::uuid,
    'aaaaaaaa-2222-4222-8222-222222222222'::uuid,
    'bbbbbbbb-2222-4222-8222-222222222222'::uuid,
    'vulncheck',
    'nist-nvd2',
    'CVE-2026-0001',
    'CVE-2026-0001',
    'purl',
    'pkg:generic/curl@8.5.0',
    '{"installed":"3.0.13-0ubuntu3.5"}'::jsonb,
    'medium',
    'active',
    'critical',
    9.8,
    TRUE,
    TRUE,
    '{"matcher":"purl","regression_child":2}'::jsonb,
    base.now_ts - INTERVAL '3 hours',
    base.now_ts - INTERVAL '3 hours',
    '{}'::jsonb
FROM base;

WITH base AS (
    SELECT NOW() AS now_ts
)
INSERT INTO endpoint_vulnerability_assessments (
    id,
    device_uid,
    package_identity_key,
    source_scope,
    agent_id,
    inventory_package_ref,
    endpoint_package_ref,
    cve_id,
    status,
    assessment,
    disposition,
    authority,
    applicability_reason,
    authority_generation,
    authority_as_of,
    freshness,
    provider,
    feed_key,
    advisory_id,
    package_type,
    package_manager,
    ecosystem,
    package_namespace,
    package_release,
    package_name,
    package_purl,
    installed_version,
    source_package,
    source_version,
    binary_package,
    architecture,
    version_scheme,
    fixed_version,
    severity,
    cvss_score,
    kev,
    exploit_available,
    supporting_match_ids,
    supporting_assertion_ids,
    evidence,
    transition_reason,
    metadata,
    first_seen_at,
    last_seen_at,
    resolved_at
)
SELECT
    'eeeeeeee-1111-4111-8111-111111111111'::uuid,
    'device-alpha',
    'pkgid:v1:nginx',
    'host',
    'agent-1',
    '11111111-1111-4111-8111-111111111111'::uuid,
    'aaaaaaaa-1111-4111-8111-111111111111'::uuid,
    'CVE-2026-0001',
    'active',
    'confirmed',
    'affected',
    'Ubuntu',
    'exact Ubuntu affected version',
    7,
    base.now_ts - INTERVAL '20 minutes',
    'fresh',
    'ubuntu',
    'ubuntu-osv-vex',
    'CVE-2026-0001',
    'deb',
    'dpkg',
    'deb',
    'ubuntu',
    'noble',
    'nginx',
    'pkg:deb/ubuntu/nginx@1.24.0-2ubuntu7?distro=noble',
    '1.24.0-2ubuntu7',
    'nginx',
    '1.24.0-2ubuntu7',
    'nginx',
    'amd64',
    'deb',
    '1.24.0-2ubuntu8',
    'critical',
    9.8,
    TRUE,
    TRUE,
    ARRAY['dddddddd-1111-4111-8111-111111111111'::uuid],
    ARRAY[]::uuid[],
    '{"authority":"ubuntu"}'::jsonb,
    'assessment_created',
    '{"due_date":"2026-02-01","epss_score":0.84,"ransomware_use":"unknown"}'::jsonb,
    base.now_ts - INTERVAL '1 day',
    base.now_ts - INTERVAL '20 minutes',
    NULL::timestamptz
FROM base
UNION ALL
SELECT
    'eeeeeeee-2222-4222-8222-222222222222'::uuid,
    'device-gamma',
    'pkgid:v1:openssl-candidate',
    'host',
    'agent-3',
    NULL,
    'aaaaaaaa-2222-4222-8222-222222222222'::uuid,
    'CVE-2026-0001',
    'active',
    'candidate',
    'unknown',
    NULL,
    'missing fresh distro assertion',
    NULL,
    NULL,
    'unknown',
    'nvd',
    'nist-nvd2',
    'CVE-2026-0001',
    'deb',
    'dpkg',
    'deb',
    'ubuntu',
    'noble',
    'openssl',
    'pkg:deb/ubuntu/openssl@3.0.13-0ubuntu3.5?distro=noble',
    '3.0.13-0ubuntu3.5',
    'openssl',
    '3.0.13-0ubuntu3.5',
    'openssl',
    'amd64',
    'deb',
    NULL,
    'critical',
    9.8,
    TRUE,
    TRUE,
    ARRAY[
        'dddddddd-2222-4222-8222-222222222222'::uuid,
        'dddddddd-3333-4333-8333-333333333333'::uuid
    ],
    ARRAY['ffffffff-1111-4111-8111-111111111111'::uuid],
    '{}'::jsonb,
    'assessment_created',
    '{"epss_score":0.72}'::jsonb,
    base.now_ts - INTERVAL '3 hours',
    base.now_ts - INTERVAL '3 hours',
    NULL::timestamptz
FROM base
UNION ALL
SELECT
    'eeeeeeee-3333-4333-8333-333333333333'::uuid,
    'device-beta',
    'pkgid:v1:openssl-history',
    'host',
    'agent-2',
    NULL,
    'aaaaaaaa-2222-4222-8222-222222222222'::uuid,
    'CVE-2025-9999',
    'resolved',
    'confirmed',
    'fixed',
    'Ubuntu',
    'installed version reaches Ubuntu fixed boundary',
    6,
    base.now_ts - INTERVAL '2 days',
    'fresh',
    'ubuntu',
    'ubuntu-osv-vex',
    'CVE-2025-9999',
    'deb',
    'dpkg',
    'deb',
    'ubuntu',
    'noble',
    'openssl',
    'pkg:deb/ubuntu/openssl@3.0.13-0ubuntu3.5?distro=noble',
    '3.0.13-0ubuntu3.5',
    'openssl',
    '3.0.13-0ubuntu3.5',
    'openssl',
    'amd64',
    'deb',
    '3.0.13-0ubuntu3.5',
    'medium',
    5.0,
    FALSE,
    FALSE,
    ARRAY[]::uuid[],
    ARRAY[]::uuid[],
    '{}'::jsonb,
    'active:confirmed:affected:to:resolved:confirmed:fixed',
    '{}'::jsonb,
    base.now_ts - INTERVAL '10 days',
    base.now_ts - INTERVAL '2 days',
    base.now_ts - INTERVAL '2 days'
FROM base;

WITH base AS (
    SELECT NOW() AS now_ts
)
INSERT INTO endpoint_inventory_current_package_counts (
    coordinate_hash,
    package_manager,
    ecosystem,
    name,
    version,
    architecture,
    purl_canonical,
    cpes,
    host_count,
    first_seen_at,
    last_seen_at,
    updated_at
)
SELECT
    'coord:dpkg:nginx:1.24.0-2ubuntu7:amd64',
    'dpkg',
    'deb',
    'nginx',
    '1.24.0-2ubuntu7',
    'amd64',
    'pkg:deb/nginx@1.24.0-2ubuntu7',
    ARRAY ['cpe:2.3:a:nginx:nginx:1.24.0:*:*:*:*:*:*:*'],
    1,
    base.now_ts - INTERVAL '20 minutes',
    base.now_ts - INTERVAL '20 minutes',
    base.now_ts - INTERVAL '20 minutes'
FROM base
UNION ALL
SELECT
    'coord:dpkg:openssl:3.0.13-0ubuntu3.5:amd64',
    'dpkg',
    'deb',
    'openssl',
    '3.0.13-0ubuntu3.5',
    'amd64',
    'pkg:deb/openssl@3.0.13-0ubuntu3.5',
    ARRAY ['cpe:2.3:a:openssl:openssl:3.0.13:*:*:*:*:*:*:*'],
    1,
    base.now_ts - INTERVAL '20 minutes',
    base.now_ts - INTERVAL '20 minutes',
    base.now_ts - INTERVAL '20 minutes'
FROM base;

WITH base AS (
    SELECT NOW() AS now_ts
)
INSERT INTO endpoint_inventory_current_cpe_counts (
    cpe,
    host_count,
    first_seen_at,
    last_seen_at,
    updated_at
)
SELECT
    'cpe:2.3:a:nginx:nginx:1.24.0:*:*:*:*:*:*:*',
    1,
    base.now_ts - INTERVAL '20 minutes',
    base.now_ts - INTERVAL '20 minutes',
    base.now_ts - INTERVAL '20 minutes'
FROM base;

WITH base AS (
    SELECT NOW() AS now_ts
)
INSERT INTO endpoint_inventory_package_counts_hourly (
    bucket,
    coordinate_hash,
    package_manager,
    ecosystem,
    name,
    version,
    architecture,
    purl_canonical,
    max_host_count,
    min_host_count,
    net_count_delta,
    sample_count
)
SELECT
    date_trunc('hour', base.now_ts - INTERVAL '1 hour'),
    'coord:dpkg:nginx:1.24.0-2ubuntu7:amd64',
    'dpkg',
    'deb',
    'nginx',
    '1.24.0-2ubuntu7',
    'amd64',
    'pkg:deb/nginx@1.24.0-2ubuntu7',
    1,
    1,
    1,
    1
FROM base;

WITH base AS (
    SELECT NOW() AS now_ts
)
INSERT INTO endpoint_inventory_cpe_counts_hourly (
    bucket,
    cpe,
    max_host_count,
    min_host_count,
    net_count_delta,
    sample_count
)
SELECT
    date_trunc('hour', base.now_ts - INTERVAL '1 hour'),
    'cpe:2.3:a:nginx:nginx:1.24.0:*:*:*:*:*:*:*',
    1,
    1,
    1,
    1
FROM base;

WITH base AS (
    SELECT NOW() AS now_ts
),
ids AS (
    SELECT
        'aaaaaaaa-0000-0000-0000-000000000001'::uuid AS cluster_id,
        'aaaaaaaa-0000-0000-0000-000000000101'::uuid AS host_id,
        'aaaaaaaa-0000-0000-0000-000000000201'::uuid AS guest_id
)
INSERT INTO virtualization_clusters (
    id,
    provider,
    provider_ref,
    name,
    status,
    version,
    observed_at,
    inserted_at,
    updated_at
)
SELECT
    ids.cluster_id,
    'proxmox',
    'proxmox:cluster:lab',
    'lab',
    'quorate',
    '8.3.2',
    base.now_ts - INTERVAL '5 minutes',
    base.now_ts,
    base.now_ts
FROM base, ids;

WITH base AS (
    SELECT NOW() AS now_ts
),
ids AS (
    SELECT
        'aaaaaaaa-0000-0000-0000-000000000001'::uuid AS cluster_id,
        'aaaaaaaa-0000-0000-0000-000000000101'::uuid AS host_id
)
INSERT INTO virtualization_hosts (
    id,
    provider,
    provider_ref,
    cluster_id,
    device_uid,
    name,
    status,
    version,
    cpu_ratio,
    memory_used_bytes,
    memory_total_bytes,
    uptime_seconds,
    observed_at,
    inserted_at,
    updated_at
)
SELECT
    ids.host_id,
    'proxmox',
    'proxmox:node:pve-a',
    ids.cluster_id,
    'device-alpha',
    'pve-a',
    'online',
    '8.3.2',
    0.23,
    8589934592,
    34359738368,
    86400,
    base.now_ts - INTERVAL '5 minutes',
    base.now_ts,
    base.now_ts
FROM base, ids;

WITH base AS (
    SELECT NOW() AS now_ts
),
ids AS (
    SELECT
        'aaaaaaaa-0000-0000-0000-000000000101'::uuid AS host_id,
        'aaaaaaaa-0000-0000-0000-000000000201'::uuid AS guest_id
)
INSERT INTO virtualization_guests (
    id,
    provider,
    provider_ref,
    host_id,
    device_uid,
    name,
    guest_type,
    vmid,
    status,
    cpu_ratio,
    memory_used_bytes,
    memory_total_bytes,
    disk_used_bytes,
    disk_total_bytes,
    uptime_seconds,
    observed_at,
    inserted_at,
    updated_at
)
SELECT
    ids.guest_id,
    'proxmox',
    'proxmox:guest:pve-a:qemu:100',
    ids.host_id,
    'device-beta',
    'vm-100',
    'vm',
    100,
    'running',
    0.12,
    1073741824,
    4294967296,
    2147483648,
    8589934592,
    3600,
    base.now_ts - INTERVAL '5 minutes',
    base.now_ts,
    base.now_ts
FROM base, ids;

WITH base AS (
    SELECT NOW() AS now_ts
),
ids AS (
    SELECT
        'aaaaaaaa-0000-0000-0000-000000000001'::uuid AS cluster_id,
        'aaaaaaaa-0000-0000-0000-000000000101'::uuid AS host_id
)
INSERT INTO virtualization_datastores (
    id,
    provider,
    provider_ref,
    cluster_id,
    host_id,
    name,
    storage_type,
    active,
    enabled,
    shared,
    used_bytes,
    available_bytes,
    total_bytes,
    observed_at,
    inserted_at,
    updated_at
)
SELECT
    'aaaaaaaa-0000-0000-0000-000000000301'::uuid,
    'proxmox',
    'proxmox:datastore:pve-a:local-zfs',
    ids.cluster_id,
    ids.host_id,
    'local-zfs',
    'zfspool',
    true,
    true,
    false,
    53687091200,
    53687091200,
    107374182400,
    base.now_ts - INTERVAL '5 minutes',
    base.now_ts,
    base.now_ts
FROM base, ids;

WITH base AS (
    SELECT NOW() AS now_ts
),
ids AS (
    SELECT 'aaaaaaaa-0000-0000-0000-000000000101'::uuid AS host_id
)
INSERT INTO virtualization_host_disks (
    id,
    provider,
    provider_ref,
    host_id,
    device_uid,
    path,
    disk_type,
    model,
    health,
    size_bytes,
    wearout,
    observed_at,
    inserted_at,
    updated_at
)
SELECT
    'aaaaaaaa-0000-0000-0000-000000000401'::uuid,
    'proxmox',
    'proxmox:disk:pve-a:/dev/sda',
    ids.host_id,
    'device-alpha',
    '/dev/sda',
    'ssd',
    'SSD',
    'PASSED',
    107374182400,
    4,
    base.now_ts - INTERVAL '5 minutes',
    base.now_ts,
    base.now_ts
FROM base, ids;

WITH base AS (
    SELECT NOW() AS now_ts
),
ids AS (
    SELECT 'aaaaaaaa-0000-0000-0000-000000000101'::uuid AS host_id
)
INSERT INTO virtualization_network_interfaces (
    id,
    provider,
    provider_ref,
    host_id,
    device_uid,
    name,
    interface_type,
    active,
    exists,
    address,
    bridge_ports,
    mac_address,
    ip_addresses,
    source,
    observed_at,
    inserted_at,
    updated_at
)
SELECT
    'aaaaaaaa-0000-0000-0000-000000000501'::uuid,
    'proxmox',
    'proxmox:nic:pve-a:vmbr0',
    ids.host_id,
    'device-alpha',
    'vmbr0',
    'bridge',
    true,
    true,
    '10.10.10.5',
    'eno1',
    NULL,
    '{}',
    'host_config',
    base.now_ts - INTERVAL '5 minutes',
    base.now_ts,
    base.now_ts
FROM base, ids;

WITH base AS (
    SELECT NOW() AS now_ts
),
ids AS (
    SELECT
        'aaaaaaaa-0000-0000-0000-000000000001'::uuid AS cluster_id,
        'aaaaaaaa-0000-0000-0000-000000000101'::uuid AS host_id,
        'aaaaaaaa-0000-0000-0000-000000000201'::uuid AS guest_id
)
INSERT INTO virtualization_network_interfaces (
    id,
    provider,
    provider_ref,
    host_id,
    guest_id,
    guest_provider_ref,
    device_uid,
    name,
    interface_type,
    active,
    exists,
    address,
    cidr,
    bridge_ports,
    mac_address,
    ip_addresses,
    source,
    observed_at,
    inserted_at,
    updated_at
)
SELECT
    'aaaaaaaa-0000-0000-0000-000000000502'::uuid,
    'proxmox',
    'proxmox:guest-nic:proxmox:guest:pve-a:qemu:100:52:54:00:aa:bb:cc',
    ids.host_id,
    ids.guest_id,
    'proxmox:guest:pve-a:qemu:100',
    'device-beta',
    'eth0',
    'virtio',
    true,
    true,
    '10.10.10.20',
    '10.10.10.20/24',
    'vmbr0',
    '52:54:00:aa:bb:cc',
    ARRAY['10.10.10.20/24', 'fe80::5054:ff:feaa:bbcc/64'],
    'guest_agent',
    base.now_ts - INTERVAL '5 minutes',
    base.now_ts,
    base.now_ts
FROM base, ids;

WITH base AS (
    SELECT NOW() AS now_ts
),
ids AS (
    SELECT
        'aaaaaaaa-0000-0000-0000-000000000001'::uuid AS cluster_id,
        'aaaaaaaa-0000-0000-0000-000000000101'::uuid AS host_id
)
INSERT INTO virtualization_storage_systems (
    id,
    provider,
    provider_ref,
    cluster_id,
    host_id,
    name,
    storage_system_type,
    health,
    status,
    observed_at,
    inserted_at,
    updated_at
)
SELECT
    'aaaaaaaa-0000-0000-0000-000000000601'::uuid,
    'proxmox',
    'proxmox:ceph:pve-a',
    ids.cluster_id,
    ids.host_id,
    'Ceph',
    'ceph',
    'HEALTH_WARN',
    'HEALTH_WARN',
    base.now_ts - INTERVAL '5 minutes',
    base.now_ts,
    base.now_ts
FROM base, ids;

WITH base AS (
    SELECT NOW() AS now_ts
)
INSERT INTO device_agent_availability (
        device_uid,
        agent_id,
        agent_name,
        is_available,
        checked_at,
        response_time_ms,
        open_ports,
        sweep_modes_results,
        metadata
    )
SELECT 'device-alpha',
    'agent-1',
    'Agent One',
    TRUE,
    base.now_ts - INTERVAL '30 minutes',
    12,
    ARRAY [22, 443],
    '{"icmp":"success","tcp":"success"}'::jsonb,
    '{}'::jsonb
FROM base
UNION ALL
SELECT 'device-alpha',
    'agent-2',
    'Agent Two',
    FALSE,
    base.now_ts - INTERVAL '20 minutes',
    NULL,
    ARRAY []::INT[],
    '{"icmp":"failed","tcp":"no_response"}'::jsonb,
    '{}'::jsonb
FROM base
UNION ALL
SELECT 'device-beta',
    'agent-1',
    'Agent One',
    TRUE,
    base.now_ts - INTERVAL '25 minutes',
    18,
    ARRAY [80],
    '{"icmp":"success","tcp":"success"}'::jsonb,
    '{}'::jsonb
FROM base;

WITH base AS (
    SELECT NOW() AS now_ts
)
INSERT INTO gateways (
        gateway_id,
        component_id,
        registration_source,
        status,
        spiffe_identity,
        first_registered,
        first_seen,
        last_seen,
        metadata,
        created_by,
        is_healthy,
        agent_count,
        checker_count,
        updated_at,
        partition_id
    )
SELECT 'gateway-1',
    'comp-1',
    'manual',
    'active',
    'spiffe://example.org/gateway/1',
    base.now_ts - INTERVAL '30 days',
    base.now_ts - INTERVAL '30 days',
    base.now_ts - INTERVAL '1 minute',
    '{"region":"us-west"}'::jsonb,
    'admin',
    true,
    10,
    50,
    base.now_ts,
    '00000000-0000-0000-0000-000000000010'::uuid
FROM base
UNION ALL
SELECT 'gateway-2',
    'comp-2',
    'auto',
    'active',
    'spiffe://example.org/gateway/2',
    base.now_ts - INTERVAL '15 days',
    base.now_ts - INTERVAL '15 days',
    base.now_ts - INTERVAL '2 minutes',
    '{"region":"us-east"}'::jsonb,
    'system',
    true,
    5,
    25,
    base.now_ts,
    '00000000-0000-0000-0000-000000000011'::uuid
FROM base;
WITH base AS (
    SELECT NOW() AS now_ts
)
INSERT INTO service_status (
        timestamp,
        gateway_id,
        agent_id,
        service_id,
        service_name,
        service_type,
        available,
        message,
        details,
        partition,
        created_at
    )
SELECT base.now_ts - INTERVAL '5 minutes',
    'gateway-1',
    'agent-1',
    '10000000-0000-0000-0000-000000000001'::uuid,
    'ssh',
    'ssh',
    true,
    'SSH service running',
    'listening on port 22',
    'default',
    base.now_ts
FROM base
UNION ALL
SELECT base.now_ts - INTERVAL '10 minutes',
    'gateway-1',
    'agent-1',
    '10000000-0000-0000-0000-000000000002'::uuid,
    'http',
    'http',
    false,
    'HTTP service down',
    'connection refused',
    'default',
    base.now_ts
FROM base;
WITH base AS (
    SELECT NOW() AS now_ts
)
INSERT INTO cpu_metrics (
        timestamp,
        gateway_id,
        agent_id,
        host_id,
        core_id,
        usage_percent,
        frequency_hz,
        label,
        cluster,
        device_id,
        partition,
        created_at
    )
SELECT base.now_ts - INTERVAL '1 minute',
    'gateway-1',
    'agent-1',
    'host-1',
    0,
    45.5,
    2400000000,
    'cpu0',
    'cluster-a',
    'device-alpha',
    'default',
    base.now_ts
FROM base
UNION ALL
SELECT base.now_ts - INTERVAL '2 minutes',
    'gateway-1',
    'agent-1',
    'host-1',
    1,
    88.2,
    2400000000,
    'cpu1',
    'cluster-a',
    'device-alpha',
    'default',
    base.now_ts
FROM base;
TRUNCATE timeseries_metrics;
TRUNCATE timeseries_metrics_hourly;
WITH base AS (
    SELECT NOW() AS now_ts
)
INSERT INTO timeseries_metrics (
        timestamp,
        gateway_id,
        agent_id,
        series_key,
        metric_name,
        metric_type,
        device_id,
        value,
        unit,
        tags,
        partition,
        scale,
        is_delta,
        target_device_ip,
        if_index,
        metadata,
        created_at
    )
SELECT base.now_ts - INTERVAL '5 minutes',
    'gateway-1',
    'agent-1',
    'seed-snmp-ifinoctets-device-alpha-ifindex-1',
    'snmp.ifInOctets',
    'snmp',
    'device-alpha',
    12345.5,
    'bytes',
    '{"direction":"in"}'::jsonb,
    'default',
    NULL::FLOAT8,
    FALSE,
    '10.10.10.5',
    1,
    '{"device_id":"device-alpha"}'::jsonb,
    base.now_ts
FROM base
UNION ALL
SELECT base.now_ts - INTERVAL '3 minutes',
    'gateway-2',
    'agent-3',
    'seed-rperf-latency-device-beta',
    'rperf.latency_ms',
    'rperf',
    'device-beta',
    12.3,
    'ms',
    '{"test":"throughput"}'::jsonb,
    'default',
    NULL::FLOAT8,
    FALSE,
    '10.10.20.6',
    NULL,
    '{"target":"device-beta"}'::jsonb,
    base.now_ts
FROM base
UNION ALL
SELECT base.now_ts - INTERVAL '1 minute',
    'gateway-1',
    'agent-1',
    'seed-sysmon-cpu-device-alpha',
    'sysmon.cpu_usage',
    'sysmon',
    'device-alpha',
    76.2,
    'percent',
    '{"source":"sysmon"}'::jsonb,
    'default',
    NULL::FLOAT8,
    FALSE,
    '10.10.10.5',
    NULL,
    '{"component":"cpu"}'::jsonb,
    base.now_ts
FROM base;
INSERT INTO timeseries_metrics_hourly (
    bucket,
    device_id,
    metric_type,
    metric_name,
    avg_value,
    min_value,
    max_value,
    sample_count
)
VALUES
    ('2026-01-04T03:00:00Z'::timestamptz, 'device-alpha', 'sysmon.cpu', 'cpu.usage_percent', 10.0, 10.0, 10.0, 12),
    ('2026-01-11T03:00:00Z'::timestamptz, 'device-alpha', 'sysmon.cpu', 'cpu.usage_percent', 11.0, 11.0, 11.0, 12),
    ('2026-01-18T03:00:00Z'::timestamptz, 'device-alpha', 'sysmon.cpu', 'cpu.usage_percent', 9.0, 9.0, 9.0, 12),
    ('2026-01-25T03:00:00Z'::timestamptz, 'device-alpha', 'sysmon.cpu', 'cpu.usage_percent', 800.0, 800.0, 800.0, 12),
    ('2026-01-25T03:00:00Z'::timestamptz, 'device-beta', 'sysmon.cpu', 'cpu.usage_percent', 42.0, 42.0, 42.0, 12),
    ('2026-01-25T04:00:00Z'::timestamptz, 'device-sparse', 'sysmon.cpu', 'cpu.usage_percent', 123.0, 123.0, 123.0, 12),
    ('2026-01-25T03:00:00Z'::timestamptz, 'device-alpha', 'sysmon.memory', 'memory.used_percent', 55.0, 55.0, 55.0, 12);
WITH base AS (
    SELECT NOW() AS now_ts
)
INSERT INTO logs (
        timestamp,
        observed_timestamp,
        trace_id,
        span_id,
        severity_text,
        severity_number,
        body,
        service_name,
        service_version,
        service_instance,
        scope_name,
        scope_version,
        source,
        attributes,
        resource_attributes,
        source_ip,
        created_at
    )
SELECT base.now_ts - INTERVAL '1 minute',
    NULL,
    'trace-1',
    'span-1',
    'INFO',
    9,
    'Application started',
    'my-service',
    '1.0.0',
    'inst-1',
    'my-scope',
    '1.0',
    'app',
    '{"key":"value"}'::text,
    '{"res":"val","serviceradar.device_id":"device-alpha","serviceradar.gateway_id":"gw-1","serviceradar.agent_id":"agent-1"}'::text,
    '198.51.100.42',
    base.now_ts
FROM base
UNION ALL
SELECT base.now_ts - INTERVAL '2 hours',
    base.now_ts - INTERVAL '30 seconds',
    'trace-2',
    'span-2',
    'ERROR',
    17,
    'Connection failed',
    'my-service',
    '1.0.0',
    'inst-1',
    'my-scope',
    '1.0',
    'app',
    '{"error":"timeout"}'::text,
    '{"res":"val"}'::text,
    NULL,
    base.now_ts
FROM base;
WITH base AS (
    SELECT NOW() AS now_ts,
        NOW() - INTERVAL '20 minutes' AS effective_ts
)
INSERT INTO logs (
        timestamp,
        observed_timestamp,
        id,
        severity_text,
        severity_number,
        body,
        source,
        service_name,
        created_at
    )
SELECT base.effective_ts,
    base.effective_ts,
    tied.id::uuid,
    tied.severity_text,
    tied.severity_number,
    'Top-N timestamp tie ' || tied.id,
    'srql-topn-tie',
    'srql-test',
    base.now_ts
FROM base
CROSS JOIN (
    VALUES
        ('00000000-0000-0000-0000-000000000001', 'FATAL', 21),
        ('00000000-0000-0000-0000-000000000002', 'CRITICAL', 21),
        ('00000000-0000-0000-0000-000000000003', 'FATAL', 21),
        ('00000000-0000-0000-0000-000000000004', 'CRITICAL', 21)
) AS tied(id, severity_text, severity_number);
WITH base AS (
    SELECT NOW() AS now_ts
)
INSERT INTO ocsf_events (
        time,
        id,
        class_uid,
        category_uid,
        type_uid,
        activity_id,
        activity_name,
        severity_id,
        severity,
        message,
        status_id,
        status,
        status_code,
        status_detail,
        metadata,
        observables,
        trace_id,
        span_id,
        actor,
        device,
        src_endpoint,
        dst_endpoint,
        log_name,
        log_provider,
        log_level,
        log_version,
        unmapped,
        raw_data,
        created_at
    )
SELECT base.now_ts - INTERVAL '3 minutes',
    '11111111-1111-4111-8111-111111111111'::uuid,
    4001,
    4,
    400101,
    1,
    'Log Activity',
    3,
    'Informational',
    'Device scoped event',
    1,
    'Success',
    'ok',
    NULL,
    '{"serviceradar.device_id":"device-alpha"}'::jsonb,
    '[]'::jsonb,
    'trace-event-1',
    'span-event-1',
    '{}'::jsonb,
    '{"uid":"device-alpha","hostname":"alpha.example"}'::jsonb,
    '{}'::jsonb,
    '{}'::jsonb,
    'syslog',
    'proxmox',
    'info',
    NULL,
    '{}'::jsonb,
    NULL,
    base.now_ts
FROM base;
WITH base AS (
    SELECT NOW() AS now_ts
)
INSERT INTO ocsf_events (
        time,
        id,
        class_uid,
        category_uid,
        type_uid,
        activity_id,
        activity_name,
        severity_id,
        severity,
        message,
        status_id,
        status,
        status_code,
        status_detail,
        metadata,
        observables,
        trace_id,
        span_id,
        actor,
        device,
        src_endpoint,
        dst_endpoint,
        log_name,
        log_provider,
        log_level,
        log_version,
        unmapped,
        raw_data,
        created_at
    )
SELECT base.now_ts - INTERVAL '2 minutes',
    '44444444-4444-4444-8444-444444444444'::uuid,
    2002,
    2,
    200201,
    1,
    'Create',
    5,
    'Critical',
    'endpoint vulnerability finding: CVE-2026-0001: nginx 1.24.0-2ubuntu7',
    NULL,
    'open',
    NULL,
    NULL,
    '{"signal_type":"inventory","primary_domain":"security","vulnerability_finding":{"cve":"CVE-2026-0001","cvss_score":9.8,"package":{"purl_canonical":"pkg:deb/nginx@1.24.0-2ubuntu7","purl":"pkg:deb/nginx@1.24.0-2ubuntu7","cpes":["cpe:2.3:a:nginx:nginx:1.24.0:*:*:*:*:*:*:*"],"package_manager":"dpkg","name":"nginx","version":"1.24.0-2ubuntu7","architecture":"amd64"}}}'::jsonb,
    '[]'::jsonb,
    NULL,
    NULL,
    '{}'::jsonb,
    '{"uid":"device-alpha"}'::jsonb,
    '{}'::jsonb,
    '{}'::jsonb,
    'signals.analytics.inventory.vulnerability',
    'endpoint_inventory',
    'critical',
    'endpoint-inventory-v1',
    '{"signal_type":"inventory","event_type":"vulnerability_match","device_uid":"device-alpha","cve":"CVE-2026-0001","package":{"purl_canonical":"pkg:deb/nginx@1.24.0-2ubuntu7","cpes":["cpe:2.3:a:nginx:nginx:1.24.0:*:*:*:*:*:*:*"]}}'::jsonb,
    NULL,
    base.now_ts
FROM base;
WITH base AS (
    SELECT NOW() AS now_ts
)
INSERT INTO otel_traces (
        timestamp,
        trace_id,
        span_id,
        parent_span_id,
        name,
        kind,
        start_time_unix_nano,
        end_time_unix_nano,
        service_name,
        service_version,
        service_instance,
        scope_name,
        scope_version,
        status_code,
        status_message,
        attributes,
        resource_attributes,
        events,
        links,
        created_at
    )
SELECT base.now_ts - INTERVAL '1 minute',
    'trace-1',
    'span-1',
    NULL,
    'handle_request',
    1,
    1600000000000000000,
    1600000000100000000,
    'api-service',
    'v1',
    'pod-1',
    'http-server',
    '1.0',
    1,
    'OK',
    '{"http.method":"GET"}'::text,
    '{"k8s.pod":"pod-1"}'::text,
    '[]',
    '[]',
    base.now_ts
FROM base;

TRUNCATE mtr_traces;
INSERT INTO mtr_traces (
    id,
    time,
    agent_id,
    gateway_id,
    check_id,
    check_name,
    device_id,
    target,
    target_ip,
    target_reached,
    total_hops,
    protocol,
    ip_version,
    packet_size,
    partition,
    error,
    created_at
)
VALUES
    (
        '00000000-0000-4000-8000-000000000010'::uuid,
        NOW() - INTERVAL '1 minute',
        'agent-mtr-latest',
        NULL,
        NULL,
        NULL,
        NULL,
        'latest.example',
        '203.0.113.1',
        TRUE,
        5,
        'icmp',
        4,
        NULL,
        NULL,
        NULL,
        NOW()
    ),
    (
        '00000000-0000-4000-8000-000000000020'::uuid,
        NOW() - INTERVAL '2 minutes',
        'agent-mtr-a',
        'gateway-mtr-a',
        'check-mtr-a',
        'edge-check',
        'device-mtr-a',
        'edge.example',
        '203.0.113.10',
        FALSE,
        12,
        'icmp',
        4,
        64,
        'partition-mtr-a',
        'destination timeout',
        NOW()
    ),
    (
        '00000000-0000-4000-8000-000000000001'::uuid,
        NOW() - INTERVAL '5 minutes',
        'agent-mtr-tie',
        NULL,
        NULL,
        NULL,
        NULL,
        'tie.example',
        '198.51.100.20',
        TRUE,
        7,
        'udp',
        4,
        NULL,
        NULL,
        NULL,
        NOW()
    ),
    (
        '00000000-0000-4000-8000-000000000002'::uuid,
        NOW() - INTERVAL '5 minutes',
        'agent-mtr-tie',
        'gateway-mtr-tie',
        'check-mtr-tie',
        'tie-check',
        'device-mtr-tie',
        'tie.example',
        '198.51.100.21',
        TRUE,
        8,
        'udp',
        4,
        128,
        'partition-mtr-tie',
        'late reply',
        NOW()
    ),
    (
        '00000000-0000-4000-8000-000000000030'::uuid,
        NOW() - INTERVAL '2 hours',
        'agent-mtr-a',
        'gateway-mtr-a',
        'check-mtr-a-old',
        'edge-check',
        'device-mtr-a',
        'edge.example',
        '203.0.113.10',
        FALSE,
        11,
        'icmp',
        4,
        64,
        'partition-mtr-a',
        'destination timeout',
        NOW() - INTERVAL '2 hours'
    ),
    (
        '00000000-0000-4000-8000-000000000040'::uuid,
        NOW() - INTERVAL '3 minutes',
        'agent-mtr-other',
        'gateway-mtr-other',
        'check-mtr-other',
        'other-check',
        'device-mtr-other',
        'other.example',
        '192.0.2.40',
        TRUE,
        3,
        'tcp',
        6,
        256,
        'partition-mtr-other',
        NULL,
        NOW()
    ),
    (
        '00000000-0000-4000-8000-000000000100'::uuid,
        '2026-06-01T00:00:00Z'::timestamptz,
        'agent-mtr-absolute',
        NULL,
        'check-mtr-lower',
        'absolute-check',
        NULL,
        'absolute.example',
        '192.0.2.100',
        TRUE,
        4,
        'icmp',
        4,
        NULL,
        NULL,
        NULL,
        '2026-06-01T00:00:01Z'::timestamptz
    ),
    (
        '00000000-0000-4000-8000-000000000101'::uuid,
        '2026-06-01T00:30:00Z'::timestamptz,
        'agent-mtr-absolute',
        'gateway-mtr-absolute',
        'check-mtr-middle',
        'absolute-check',
        'device-mtr-absolute',
        'absolute.example',
        '192.0.2.101',
        FALSE,
        9,
        'icmp',
        4,
        84,
        'partition-mtr-absolute',
        'middle sample',
        '2026-06-01T00:30:01Z'::timestamptz
    ),
    (
        '00000000-0000-4000-8000-000000000102'::uuid,
        '2026-06-01T01:00:00Z'::timestamptz,
        'agent-mtr-absolute',
        'gateway-mtr-absolute',
        'check-mtr-upper',
        'absolute-check',
        'device-mtr-absolute',
        'absolute.example',
        '192.0.2.102',
        TRUE,
        10,
        'icmp',
        4,
        84,
        'partition-mtr-absolute',
        'upper-bound sample',
        '2026-06-01T01:00:01Z'::timestamptz
    );

-- Seed AGE graph data for device_graph SRQL queries (best-effort when privileges allow).
SET LOCAL search_path = ag_catalog, public, "$user";

DO $$
BEGIN
    BEGIN
        PERFORM ag_catalog.create_graph('platform_graph');
    EXCEPTION
        WHEN others THEN NULL;
    END;

    BEGIN
        EXECUTE format('GRANT USAGE ON SCHEMA %I TO PUBLIC', 'platform_graph');
        EXECUTE format('GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA %I TO PUBLIC', 'platform_graph');
    EXCEPTION
        WHEN insufficient_privilege THEN NULL;
        WHEN others THEN NULL;
    END;

    BEGIN
        GRANT USAGE ON SCHEMA ag_catalog TO PUBLIC;
        GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA ag_catalog TO PUBLIC;
    EXCEPTION
        WHEN insufficient_privilege THEN NULL;
        WHEN others THEN NULL;
    END;

    BEGIN
        PERFORM ag_catalog.create_vlabel('platform_graph', 'Device');
    EXCEPTION
        WHEN others THEN NULL;
    END;
    BEGIN
        PERFORM ag_catalog.create_vlabel('platform_graph', 'Collector');
    EXCEPTION
        WHEN others THEN NULL;
    END;
    BEGIN
        PERFORM ag_catalog.create_vlabel('platform_graph', 'Service');
    EXCEPTION
        WHEN others THEN NULL;
    END;
    BEGIN
        PERFORM ag_catalog.create_vlabel('platform_graph', 'Interface');
    EXCEPTION
        WHEN others THEN NULL;
    END;
    BEGIN
        PERFORM ag_catalog.create_vlabel('platform_graph', 'Capability');
    EXCEPTION
        WHEN others THEN NULL;
    END;

    BEGIN
        PERFORM ag_catalog.create_elabel('platform_graph', 'HOSTS_SERVICE');
    EXCEPTION
        WHEN others THEN NULL;
    END;
    BEGIN
        PERFORM ag_catalog.create_elabel('platform_graph', 'TARGETS');
    EXCEPTION
        WHEN others THEN NULL;
    END;
    BEGIN
        PERFORM ag_catalog.create_elabel('platform_graph', 'HAS_INTERFACE');
    EXCEPTION
        WHEN others THEN NULL;
    END;
    BEGIN
        PERFORM ag_catalog.create_elabel('platform_graph', 'REPORTED_BY');
    EXCEPTION
        WHEN others THEN NULL;
    END;
    BEGIN
        PERFORM ag_catalog.create_elabel('platform_graph', 'PROVIDES_CAPABILITY');
    EXCEPTION
        WHEN others THEN NULL;
    END;

    PERFORM * FROM ag_catalog.cypher('platform_graph', $_cypher$
        MERGE (d:Device {id: 'device-alpha', hostname: 'alpha-edge'})
        MERGE (peer_d:Device {id: 'device-beta', hostname: 'beta-edge'})
        MERGE (c:Collector {id: 'serviceradar:agent:agent-1'})
        MERGE (svc:Service {id: 'serviceradar:service:ssh@agent-1', type: 'ssh'})
        MERGE (iface:Interface {id: 'device-alpha/eth0', name: 'eth0'})
        MERGE (peer_iface:Interface {id: 'device-beta/eth1', name: 'eth1'})
        MERGE (cap:Capability {type: 'snmp'})
        MERGE (d)-[:HAS_INTERFACE]->(iface)
        MERGE (peer_d)-[:HAS_INTERFACE]->(peer_iface)
        MERGE (iface)-[:CONNECTS_TO]->(peer_iface)
        MERGE (d)-[:PROVIDES_CAPABILITY]->(cap)
        MERGE (c)-[:HOSTS_SERVICE]->(svc)
        MERGE (svc)-[:TARGETS]->(d)
        MERGE (d)-[:REPORTED_BY]->(c)
    $_cypher$) AS (result agtype);
EXCEPTION
    WHEN insufficient_privilege THEN
        RAISE NOTICE 'Skipping AGE graph seed due to insufficient privileges';
END $$;

-- Device identity for the log correlation path.
--
-- `in:logs device_id:"..."` deliberately does NOT match on resource_attributes:
-- rust/srql/src/query/logs/metadata.rs routes device_id filters to
-- device_inventory_identity_clause only, because an attribute ILIKE over
-- last_24h logs times out. It correlates the log's syslog source columns
-- against device inventory instead.
--
-- The in-window log below carries source_ip 198.51.100.42, while device-alpha's
-- ocsf_devices row has ip 10.10.10.5 -- so the ocsf_devices branch cannot match
-- it. The identifier row here is what ties that source_ip to device-alpha, which
-- is what `in:logs device_id:"device-alpha" time:last_10m` expects to find.
INSERT INTO device_identifiers (
        device_id,
        identifier_type,
        identifier_value,
        partition,
        confidence,
        source,
        first_seen,
        last_seen,
        verified,
        metadata
    )
VALUES (
        'device-alpha',
        'ip',
        '198.51.100.42',
        'default',
        'high',
        'sweep',
        NOW() - INTERVAL '14 days',
        NOW() - INTERVAL '1 minute',
        TRUE,
        '{}'::jsonb
    );

CREATE OR REPLACE FUNCTION public.age_device_neighborhood(
    p_device_id text,
    p_collector_owned_only boolean DEFAULT false,
    p_include_topology boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    cypher_sql text;
    cypher_result ag_catalog.agtype;
    graph_name text := 'platform_graph';
    include_topology text := CASE WHEN coalesce(p_include_topology, true) THEN 'true' ELSE 'false' END;
    collector_only text := CASE WHEN coalesce(p_collector_owned_only, false) THEN 'true' ELSE 'false' END;
BEGIN
    PERFORM set_config('search_path', 'ag_catalog,pg_catalog,"$user",public', false);

    cypher_sql := format($cypher$
        WITH %s::boolean AS include_topology, %s::boolean AS collector_only
            MATCH (c:Collector {id: %L})
            OPTIONAL MATCH (c)-[:REPORTED_BY]->(parentCol:Collector)
            OPTIONAL MATCH (devAlias:Device {id: %L})-[:REPORTED_BY]->(parentFromAlias:Collector)
            OPTIONAL MATCH (childCol:Collector)-[:REPORTED_BY]->(c)
            OPTIONAL MATCH (childDev:Device)-[:REPORTED_BY]->(c)
                WHERE childDev.id STARTS WITH 'serviceradar:'
        WITH c, include_topology,
             collect(DISTINCT parentCol) + collect(DISTINCT parentFromAlias) AS parent_collectors,
             collect(DISTINCT childCol) AS child_collectors,
             collect(DISTINCT childDev.id) AS child_dev_ids
        WITH c, include_topology, parent_collectors, child_collectors,
             CASE WHEN size(child_dev_ids) = 0 THEN [NULL] ELSE child_dev_ids END AS child_dev_ids_safe
        UNWIND child_dev_ids_safe AS child_dev_id
            OPTIONAL MATCH (aliasCol:Collector {id: child_dev_id})
            WITH c, include_topology,
                 parent_collectors,
                 child_collectors,
                 collect(DISTINCT aliasCol) AS alias_child_collectors
            WITH c, include_topology,
                 [col IN parent_collectors WHERE col IS NOT NULL] AS parent_collectors,
                 [col IN (child_collectors + alias_child_collectors) WHERE col IS NOT NULL] AS child_collectors,
                 [c] + [col IN (child_collectors + alias_child_collectors) WHERE col IS NOT NULL | col] AS host_collectors
            UNWIND host_collectors AS host_col
        OPTIONAL MATCH (host_col)-[:HOSTS_SERVICE]->(svc:Service)
        OPTIONAL MATCH (svc)-[:TARGETS]->(t:Device)
        OPTIONAL MATCH (svc)-[:PROVIDES_CAPABILITY]->(svcCap:Capability)
        OPTIONAL MATCH (reported:Device)-[:REPORTED_BY]->(host_col)
        WITH c, include_topology, parent_collectors, child_collectors,
             collect(DISTINCT CASE WHEN svc IS NOT NULL THEN {service: properties(svc), collector_id: host_col.id, collector_owned: true} ELSE NULL END) AS services_output_raw,
             collect(DISTINCT t) AS service_targets,
             collect(DISTINCT svcCap) AS service_caps,
             collect(DISTINCT reported) AS reported_devices
        WITH c, include_topology, parent_collectors, child_collectors, services_output_raw, service_targets, service_caps, reported_devices,
             CASE WHEN size(service_targets + reported_devices) = 0 THEN [NULL] ELSE service_targets + reported_devices END AS combined_targets
        UNWIND combined_targets AS tgt
        WITH c, include_topology, parent_collectors, child_collectors, services_output_raw, service_caps,
             collect(DISTINCT tgt) AS all_targets
        RETURN {
            device: properties(c),
            collectors: [col IN (parent_collectors + child_collectors) WHERE col IS NOT NULL | properties(col)],
            services: [s IN services_output_raw WHERE s IS NOT NULL | s],
            targets: [tgt IN all_targets WHERE tgt IS NOT NULL | properties(tgt)],
            interfaces: [],
            peer_interfaces: [],
            device_capabilities: [],
            service_capabilities: [cap IN service_caps WHERE cap IS NOT NULL | properties(cap)]
        } AS result
    $cypher$, include_topology, collector_only, p_device_id, p_device_id);

    -- Quote the Cypher text as an SQL literal so embedded dollar quoting stays data.
    EXECUTE format(
        'SELECT result FROM ag_catalog.cypher(%L, %L) AS (result ag_catalog.agtype)',
        graph_name,
        cypher_sql
    )
    INTO cypher_result;

    IF cypher_result IS NULL OR cypher_result::text = 'null' THEN
        cypher_sql := format($cypher$
            WITH %s::boolean AS include_topology, %s::boolean AS collector_only
            MATCH (d:Device {id: %L})
            OPTIONAL MATCH (d)-[:REPORTED_BY]->(col:Collector)
            OPTIONAL MATCH (col)-[:HOSTS_SERVICE]->(svc:Service)
            OPTIONAL MATCH (svc)-[:TARGETS]->(t:Device)
            OPTIONAL MATCH (svc)-[:PROVIDES_CAPABILITY]->(svcCap:Capability)
            OPTIONAL MATCH (d)-[:PROVIDES_CAPABILITY]->(dcap:Capability)
            OPTIONAL MATCH (d)-[:HAS_INTERFACE]->(iface:Interface)
            OPTIONAL MATCH (iface)-[:CONNECTS_TO]->(peer:Interface)
            OPTIONAL MATCH (peer_owner:Device)-[:HAS_INTERFACE]->(peer)
            WITH d, include_topology, collector_only,
                 collect(DISTINCT col) AS collectors,
                 collect(DISTINCT CASE WHEN svc IS NOT NULL AND t IS NOT NULL AND t.id = d.id AND col IS NOT NULL THEN {
                     service: properties(svc),
                     collector_id: col.id,
                     collector_owned: col IS NOT NULL
                 } ELSE NULL END) AS services_output_raw,
                 collect(DISTINCT CASE WHEN svc IS NOT NULL AND t IS NOT NULL AND t.id = d.id AND col IS NOT NULL THEN col ELSE NULL END) AS host_collectors_raw,
                 collect(DISTINCT CASE WHEN t IS NOT NULL AND t.id <> d.id THEN properties(t) ELSE NULL END) AS target_props_raw,
                 collect(DISTINCT iface) AS interfaces,
                 collect(DISTINCT CASE WHEN peer IS NOT NULL THEN {
                     id: peer.id,
                     name: peer.name,
                     ifindex: peer.ifindex,
                     descr: peer.descr,
                     alias: peer.alias,
                     mac: peer.mac,
                     ip_addresses: peer.ip_addresses,
                     device_id: coalesce(peer.device_id, peer_owner.id),
                     owner_device_id: peer_owner.id,
                     owner_device: properties(peer_owner),
                     properties: properties(peer)
                 } ELSE NULL END) AS peer_interfaces_raw,
                 collect(DISTINCT dcap) AS device_caps,
                 collect(DISTINCT svcCap) AS service_caps
            WITH d, include_topology, collector_only, collectors, target_props_raw, interfaces, peer_interfaces_raw, device_caps, service_caps,
                 [c IN host_collectors_raw WHERE c IS NOT NULL] AS host_collectors,
                 [s IN services_output_raw WHERE s IS NOT NULL] AS services_output
            WITH d, include_topology, collector_only, collectors, services_output, target_props_raw, interfaces, peer_interfaces_raw, device_caps, service_caps, host_collectors,
                 CASE WHEN size(host_collectors) > 0 THEN host_collectors ELSE collectors END AS collector_list,
                 (size(host_collectors) > 0 OR size([c IN collectors WHERE c IS NOT NULL]) > 0) AS has_collector,
                 [tgt IN target_props_raw WHERE tgt IS NOT NULL | tgt] AS target_props
            WITH d, include_topology, collector_only, services_output, target_props, interfaces, peer_interfaces_raw, device_caps, service_caps, has_collector,
                 CASE WHEN size(collector_list) = 0 THEN [NULL] ELSE collector_list END AS collector_list_safe
            UNWIND collector_list_safe AS base_col
            OPTIONAL MATCH (parentCol:Collector)<-[:REPORTED_BY]-(base_col)
            WITH d, include_topology, collector_only, services_output, target_props, interfaces, peer_interfaces_raw, device_caps, service_caps, has_collector,
                 collect(DISTINCT base_col) AS collector_list_dedup,
                 collect(DISTINCT parentCol) AS parent_collectors
            WITH d, include_topology, collector_only, services_output, target_props, interfaces, peer_interfaces_raw, device_caps, service_caps,
                 collector_list_dedup + parent_collectors AS combined_collectors,
                 (has_collector OR size([p IN parent_collectors WHERE p IS NOT NULL]) > 0) AS has_any_collector
            WHERE NOT collector_only OR has_any_collector
            RETURN {
                device: properties(d),
                collectors: [c IN combined_collectors WHERE c IS NOT NULL | properties(c)],
                services: services_output,
                targets: target_props,
                interfaces: CASE WHEN include_topology THEN [i IN interfaces WHERE i IS NOT NULL | properties(i)] ELSE [] END,
                peer_interfaces: CASE WHEN include_topology THEN [p IN peer_interfaces_raw WHERE p IS NOT NULL | p] ELSE [] END,
                device_capabilities: [cap IN device_caps WHERE cap IS NOT NULL | properties(cap)],
                service_capabilities: [cap IN service_caps WHERE cap IS NOT NULL | properties(cap)]
            } AS result
        $cypher$, include_topology, collector_only, p_device_id, p_device_id);

        EXECUTE format(
            'SELECT result FROM ag_catalog.cypher(%L, %L) AS (result ag_catalog.agtype)',
            graph_name,
            cypher_sql
        )
        INTO cypher_result;
    END IF;

    IF cypher_result IS NULL OR cypher_result::text = 'null' THEN
        cypher_sql := format($cypher$
            WITH %s::boolean AS include_topology, %s::boolean AS collector_only
            MATCH (svc:Service {id: %L})
            OPTIONAL MATCH (col:Collector)-[:HOSTS_SERVICE]->(svc)
            OPTIONAL MATCH (svc)-[:TARGETS]->(t:Device)
            OPTIONAL MATCH (svc)-[:PROVIDES_CAPABILITY]->(svcCap:Capability)
            WITH svc, include_topology, collector_only,
                 collect(DISTINCT col) AS collectors,
                 collect(DISTINCT t) AS targets,
                 collect(DISTINCT svcCap) AS service_caps
            WITH svc, include_topology, collector_only,
                 CASE WHEN size(collectors) = 0 THEN [NULL] ELSE collectors END AS collectors_list,
                 CASE WHEN size(targets) = 0 THEN [NULL] ELSE targets END AS targets_list,
                 service_caps
            UNWIND collectors_list AS base_col
            OPTIONAL MATCH (parentCol:Collector)<-[:REPORTED_BY]-(base_col)
            UNWIND targets_list AS tgt
            WITH svc, include_topology, collector_only, service_caps,
                 collect(DISTINCT base_col) AS collectors,
                 collect(DISTINCT parentCol) AS parent_collectors,
                 collect(DISTINCT tgt) AS targets_flat
            WITH svc, include_topology, collector_only,
                 collectors + parent_collectors AS combined_collectors,
                 targets_flat,
                 service_caps,
                 size([c IN (collectors + parent_collectors) WHERE c IS NOT NULL]) > 0 AS has_collector
            WHERE NOT collector_only OR has_collector
            RETURN {
                device: properties(svc),
                collectors: [c IN combined_collectors WHERE c IS NOT NULL | properties(c)],
                services: [{
                    service: properties(svc),
                    collector_id: CASE WHEN size([c IN combined_collectors WHERE c IS NOT NULL]) > 0 THEN (combined_collectors[0].id) ELSE NULL END,
                    collector_owned: size([c IN combined_collectors WHERE c IS NOT NULL]) > 0
                }],
                targets: [tgt IN targets_flat WHERE tgt IS NOT NULL | properties(tgt)],
                interfaces: [],
                peer_interfaces: [],
                device_capabilities: [],
                service_capabilities: [cap IN service_caps WHERE cap IS NOT NULL | properties(cap)]
            } AS result
        $cypher$, include_topology, collector_only, p_device_id);

        EXECUTE format(
            'SELECT result FROM ag_catalog.cypher(%L, %L) AS (result ag_catalog.agtype)',
            graph_name,
            cypher_sql
        )
        INTO cypher_result;
    END IF;

    RETURN (cypher_result::text)::jsonb;
EXCEPTION
    WHEN undefined_function THEN
        RETURN NULL;
END;
$$;

-- ---------------------------------------------------------------------------
-- Identity reconciliation diagnostics (GitHub #4229)
-- ---------------------------------------------------------------------------
--
-- The shapes an identity investigation has to distinguish, seeded so the SRQL
-- entities are tested against data that actually exercises them rather than a
-- single happy row:
--
--   * a three-hop merge chain  identity-src -> identity-mid -> identity-survivor
--   * an oscillating pair      identity-osc-a <-> identity-osc-b, both directions,
--                              repeatedly. A recursive walk that does not guard
--                              on visited ids never terminates on this.
--   * an unmerge row           which the default projection must hide
--   * a tombstoned device with a revival that preserved the prior tombstone
--   * one corroborated MAC (current column), one corroborated only via an
--     interface, one purely historical
--   * a cross-partition identifier collision
--   * a transitive component A-B-C where A and C share nothing directly
--   * a completed run that hit its cap, and a failed run
--
-- EVERY device below is tombstoned (`deleted_at` set), and that is load-bearing
-- rather than incidental. `ocsf_devices` is shared, and existing tests assert
-- exact totals over it: `in:devices` and the grouped-stats paths all push
-- `deleted_at IS NULL`, so nine live rows here shifted the untagged "Unknown"
-- bucket to 8, broke a `time:last_7d` count, and survived two negated tag
-- filters. Tombstoning keeps these fixtures invisible to every default device
-- query while leaving them fully visible to the identity entities, none of
-- which filters on `deleted_at`.
--
-- The live-owner side of `matches_current_facts` and `owner_deleted` is covered
-- by an identifier row on the pre-existing `device-alpha` instead of by adding
-- another device.

INSERT INTO public.ocsf_devices (uid, type_id, type, name, hostname, ip, mac,
        first_seen_time, last_seen_time, created_time, modified_time,
        partition, deleted_at, deleted_by, deleted_reason, agent_id)
SELECT * FROM (VALUES
    ('identity-survivor', 12, 'Router', 'Identity Survivor', 'identity-survivor',
     '10.30.0.1', 'AA:BB:CC:00:00:01', NOW() - INTERVAL '30 days', NOW(), NOW(), NOW(),
     'default', NOW() - INTERVAL '1 hour', 'identity-fixture', 'identity fixture: tombstoned so it stays out of shared device totals', 'agent-identity-1'),
    ('identity-src', 12, 'Router', 'Identity Source', 'identity-src',
     '10.30.0.2', 'AA:BB:CC:00:00:02', NOW() - INTERVAL '30 days', NOW(), NOW(), NOW(),
     'default', NOW() - INTERVAL '2 days', 'operator', 'merged into identity-survivor', NULL),
    ('identity-mid', 12, 'Router', 'Identity Middle', 'identity-mid',
     '10.30.0.3', 'AA:BB:CC:00:00:03', NOW() - INTERVAL '30 days', NOW(), NOW(), NOW(),
     'default', NOW() - INTERVAL '1 day', 'system', 'duplicate', NULL),
    ('identity-revived', 12, 'Router', 'Identity Revived', 'identity-revived',
     '169.254.0.1', 'AA:BB:CC:00:00:04', NOW() - INTERVAL '30 days', NOW(), NOW(), NOW(),
     'default', NOW() - INTERVAL '1 hour', 'identity-fixture', 'identity fixture: tombstoned so it stays out of shared device totals', NULL),
    ('identity-comp-a', 12, 'Router', 'Component A', 'identity-comp-a',
     '10.31.0.1', 'AA:BB:CC:00:00:0A', NOW() - INTERVAL '30 days', NOW(), NOW(), NOW(),
     'default', NOW() - INTERVAL '1 hour', 'identity-fixture', 'identity fixture: tombstoned so it stays out of shared device totals', NULL),
    ('identity-comp-b', 12, 'Router', 'Component B', 'identity-comp-b',
     '10.31.0.2', 'AA:BB:CC:00:00:0B', NOW() - INTERVAL '30 days', NOW(), NOW(), NOW(),
     'default', NOW() - INTERVAL '1 hour', 'identity-fixture', 'identity fixture: tombstoned so it stays out of shared device totals', NULL),
    ('identity-comp-c', 12, 'Router', 'Component C', 'identity-comp-c',
     '10.31.0.3', 'AA:BB:CC:00:00:0C', NOW() - INTERVAL '30 days', NOW(), NOW(), NOW(),
     'edge-west', NOW() - INTERVAL '1 hour', 'identity-fixture', 'identity fixture: tombstoned so it stays out of shared device totals', NULL),
    ('identity-osc-a', 12, 'Router', 'Oscillating A', 'identity-osc-a',
     '10.32.0.1', 'AA:BB:CC:00:00:1A', NOW() - INTERVAL '30 days', NOW(), NOW(), NOW(),
     'default', NOW() - INTERVAL '1 hour', 'identity-fixture', 'identity fixture: tombstoned so it stays out of shared device totals', NULL),
    ('identity-osc-b', 12, 'Router', 'Oscillating B', 'identity-osc-b',
     '10.32.0.2', 'AA:BB:CC:00:00:1B', NOW() - INTERVAL '30 days', NOW(), NOW(), NOW(),
     'default', NOW() - INTERVAL '1 hour', 'identity-fixture', 'identity fixture: tombstoned so it stays out of shared device totals', NULL)
) AS v;

-- A three-hop chain plus an unmerge row the default projection must hide.
INSERT INTO public.merge_audit
    (event_id, from_device_id, to_device_id, reason, confidence_score, source, details, created_at)
VALUES
    ('11111111-1111-4111-8111-111111111111', 'identity-src', 'identity-mid',
     'duplicate_mac', 0.95, 'scheduled_reconciliation',
     '{"source":"scheduled_reconciliation","component_size":2,"secret_token":"must-not-appear"}'::jsonb,
     NOW() - INTERVAL '3 days'),
    ('22222222-2222-4222-8222-222222222222', 'identity-mid', 'identity-survivor',
     'identifier_backfill', 0.99, 'scheduled_reconciliation',
     '{"source":"scheduled_reconciliation","component_size":2}'::jsonb,
     NOW() - INTERVAL '2 days'),
    ('33333333-3333-4333-8333-333333333333', 'identity-comp-a', 'identity-comp-b',
     'unmerge', NULL, 'operator', '{}'::jsonb, NOW() - INTERVAL '1 day'),
    -- The oscillating pair: same two devices, both directions, four rows.
    ('44444444-4444-4444-8444-444444444441', 'identity-osc-a', 'identity-osc-b',
     'ip_alias_conflict', 0.5, 'sync', '{}'::jsonb, NOW() - INTERVAL '6 hours'),
    ('44444444-4444-4444-8444-444444444442', 'identity-osc-b', 'identity-osc-a',
     'ip_alias_conflict', 0.5, 'sync', '{}'::jsonb, NOW() - INTERVAL '5 hours'),
    ('44444444-4444-4444-8444-444444444443', 'identity-osc-a', 'identity-osc-b',
     'ip_alias_conflict', 0.5, 'sync', '{}'::jsonb, NOW() - INTERVAL '4 hours'),
    ('44444444-4444-4444-8444-444444444444', 'identity-osc-b', 'identity-osc-a',
     'ip_alias_conflict', 0.5, 'sync', '{}'::jsonb, NOW() - INTERVAL '3 hours');

INSERT INTO public.device_revival_audit
    (device_uid, previous_deleted_at, previous_deleted_by, previous_deleted_reason,
     revived_at, revived_by_application)
VALUES
    ('identity-revived', NOW() - INTERVAL '5 days', 'operator',
     'phantom apipa address', NOW() - INTERVAL '4 days', 'serviceradar-sync'),
    ('identity-revived', NOW() - INTERVAL '3 days', 'operator',
     'phantom apipa address', NOW() - INTERVAL '2 days', 'serviceradar-core');

-- identity-survivor reports 00:00:01 as its current mac column and 00:00:99 on
-- an interface. Both are corroborated; the third is history.
INSERT INTO public.device_interface_macs (device_id, mac, partition, first_seen, last_seen)
VALUES ('identity-survivor', 'AABBCC000099', 'default', NOW() - INTERVAL '10 days', NOW());

INSERT INTO public.device_identifiers
    (device_id, identifier_type, identifier_value, partition, confidence, source,
     first_seen, last_seen, verified, metadata)
VALUES
    ('identity-survivor', 'mac', 'AABBCC000001', 'default', 'strong', 'mapper',
     NOW() - INTERVAL '20 days', NOW(), TRUE,
     '{"source":"mapper","secret_token":"must-not-appear"}'::jsonb),
    ('identity-survivor', 'mac', 'AABBCC000099', 'default', 'strong', 'mapper',
     NOW() - INTERVAL '10 days', NOW(), TRUE, '{"source":"mapper"}'::jsonb),
    ('identity-survivor', 'mac', 'AABBCCDEAD01', 'default', 'strong', 'armis',
     NOW() - INTERVAL '90 days', NOW() - INTERVAL '60 days', FALSE, '{}'::jsonb),
    ('identity-survivor', 'agent_id', 'agent-identity-1', 'default', 'strong', 'agent',
     NOW() - INTERVAL '20 days', NOW(), TRUE, '{}'::jsonb),
    -- An external system's key. No column on ocsf_devices can equal it, so
    -- matches_current_facts is null rather than false: "not applicable", not
    -- "stale".
    ('identity-survivor', 'armis_device_id', '99887766', 'default', 'strong', 'armis',
     NOW() - INTERVAL '20 days', NOW(), TRUE, '{}'::jsonb),
    -- A-B share a MAC; B-C share a different MAC; A and C share nothing.
    ('identity-comp-a', 'mac', 'AABBCC00AB01', 'default', 'strong', 'mapper',
     NOW() - INTERVAL '20 days', NOW(), TRUE, '{}'::jsonb),
    ('identity-comp-b', 'mac', 'AABBCC00AB01', 'default', 'strong', 'mapper',
     NOW() - INTERVAL '20 days', NOW(), TRUE, '{}'::jsonb),
    ('identity-comp-b', 'mac', 'AABBCC00BC01', 'default', 'strong', 'mapper',
     NOW() - INTERVAL '20 days', NOW(), TRUE, '{}'::jsonb),
    -- identity-comp-c is in partition edge-west: the edge B-C is cross-partition.
    ('identity-comp-c', 'mac', 'AABBCC00BC01', 'default', 'strong', 'mapper',
     NOW() - INTERVAL '20 days', NOW(), TRUE, '{}'::jsonb),
    -- Owned by a device that IS tombstoned: the row must still be returned, with
    -- owner_deleted true and the owner's deleted_reason carried through.
    ('identity-src', 'mac', 'AABBCC00DEAD', 'default', 'strong', 'armis',
     NOW() - INTERVAL '20 days', NOW(), TRUE, '{}'::jsonb),
    -- The live-owner case, hung off the PRE-EXISTING device-alpha rather than a
    -- new device: every identity fixture device is tombstoned to stay out of the
    -- shared device totals, so without this row `owner_deleted = false` and a
    -- corroborated identifier on a live owner would go untested.
    ('device-alpha', 'mac', 'AABBCCDDEE01', 'default', 'strong', 'mapper',
     NOW() - INTERVAL '20 days', NOW(), TRUE, '{}'::jsonb);

INSERT INTO public.identity_reconciliation_runs
    (run_id, started_at, completed_at, duration_ms, status, error_summary,
     duplicate_identifier_count, duplicate_components, mergeable_components,
     blocked_components, blocked_devices, largest_blocked_component,
     merges, errors, max_merges_configured, merge_cap_reached,
     blocked_component_devices, trigger, job_schedule_id)
VALUES
    ('55555555-5555-4555-8555-555555555555', NOW() - INTERVAL '2 hours',
     NOW() - INTERVAL '2 hours' + INTERVAL '31 seconds', 31000, 'completed', NULL,
     412, 96, 92, 4, 17, 5, 200, 1, 200, TRUE,
     '[{"device_ids":["identity-comp-a","identity-comp-b","identity-comp-c"]}]'::jsonb,
     'scheduled', 7),
    ('66666666-6666-4666-8666-666666666666', NOW() - INTERVAL '1 hour',
     NOW() - INTERVAL '1 hour' + INTERVAL '4 seconds', 4000, 'completed', NULL,
     12, 3, 3, 0, 0, 0, 3, 0, 200, FALSE, '[]'::jsonb, 'scheduled', 7),
    ('77777777-7777-4777-8777-777777777777', NOW() - INTERVAL '30 minutes',
     NOW() - INTERVAL '30 minutes' + INTERVAL '2 seconds', 2000, 'failed',
     '** (Postgrex.Error) ERROR 40001 (serialization_failure)',
     0, 0, 0, 0, 0, 0, 0, 0, 200, FALSE, '[]'::jsonb, 'scheduled', 7);
