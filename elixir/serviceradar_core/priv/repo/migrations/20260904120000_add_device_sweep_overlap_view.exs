defmodule ServiceRadar.Repo.Migrations.AddDeviceSweepOverlapView do
  @moduledoc false
  use Ecto.Migration

  # Diagnostic view (issue 4167, task 4): for every sweep-group declaration and
  # every observed coverage row, answers "declared vs observed" so an operator
  # can find a group that was told to scan a device and returned nothing
  # (`relationship = 'declared_not_observed'`).
  #
  # This SQL was validated against a real migrated Postgres BEFORE it was
  # written here, which found four defects in the shape the plan originally
  # called for. The worst: a group declaring one scanned target and one silent
  # target produced zero rows for the silent one, so `declared_not_observed`
  # -- the entity's entire purpose -- could not find the thing it exists to
  # find. The corrected form is also ~15x faster (4.6s vs 70.7s on a full
  # scan; 1.8s vs 13s on the `declared_not_observed` headline query, both
  # measured at 144k declared x 142k observed rows).
  #
  # Do not "simplify" it back toward the obvious shape. The two least-obvious
  # choices are deliberate:
  #
  #   - Observed IPs are expanded to their supernet at each declared prefix
  #     length so inet containment (`<<=`) becomes an equality join. `<<=` is
  #     neither hash- nor merge-joinable, and Postgres rejects it outright
  #     inside a FULL OUTER JOIN.
  #   - The `declared` CTE is a `UNION ALL` of two arms (SRQL-derived device
  #     targets, and static CIDR/IP targets) plus a dedup, not two
  #     `LEFT JOIN LATERAL`s -- two laterals would be a cartesian product, and
  #     the dedup is needed because a target can be both static and
  #     SRQL-derived.
  def up do
    execute("""
    CREATE VIEW platform.device_sweep_overlap AS
    WITH declared_raw AS (
        -- Arm 1: device_targets[] produced by an SRQL target_query.
        -- SweepCompiler omits the key entirely when empty, and jsonb_array_elements is
        -- strict, so a group without device targets contributes zero rows here (no
        -- NULL-extended phantom row).  network is always a bare IP
        -- (normalize_device_ip_target/1 requires :inet.parse_strict_address).
        SELECT i.agent_id,
               (g.value ->> 'sweep_group_id')::uuid            AS sweep_group_id,
               dt.value ->> 'network'                          AS target,
               NULLIF(dt.value #>> '{metadata,device_uid}', '') AS declared_device_uid,
               i.last_delivered_at
        FROM platform.agent_config_instances i
        CROSS JOIN LATERAL jsonb_array_elements(i.compiled_config -> 'groups') AS g(value)
        CROSS JOIN LATERAL jsonb_array_elements(g.value -> 'device_targets') AS dt(value)
        WHERE i.config_type = 'sweep'
          AND jsonb_typeof(i.compiled_config -> 'groups') = 'array'
          AND jsonb_typeof(g.value -> 'device_targets') = 'array'

        UNION ALL

        -- Arm 2: static targets[] (SweepGroup.static_targets, verbatim CIDRs/IPs).
        -- UNION ALL, never a lateral cross product: with N device targets and M static
        -- targets the old form emitted N*M rows and COALESCE() made every static target
        -- unreachable.
        SELECT i.agent_id,
               (g.value ->> 'sweep_group_id')::uuid AS sweep_group_id,
               t.value                              AS target,
               NULL::text                           AS declared_device_uid,
               i.last_delivered_at
        FROM platform.agent_config_instances i
        CROSS JOIN LATERAL jsonb_array_elements(i.compiled_config -> 'groups') AS g(value)
        CROSS JOIN LATERAL jsonb_array_elements_text(g.value -> 'targets') AS t(value)
        WHERE i.config_type = 'sweep'
          AND jsonb_typeof(i.compiled_config -> 'groups') = 'array'
          AND jsonb_typeof(g.value -> 'targets') = 'array'
    ),
    declared_dedup AS MATERIALIZED (
        -- One declared row per (agent, group, target).  GROUP BY (not UNION) because
        -- agent_config_instances is unique on (config_type, partition, agent_id): the same
        -- agent_id can legitimately appear in two partitions with different
        -- last_delivered_at, and the same target can arrive both statically and from the
        -- SRQL query.
        SELECT agent_id,
               sweep_group_id,
               target,
               max(declared_device_uid) AS declared_device_uid,
               max(last_delivered_at)   AS last_delivered_at
        FROM declared_raw
        WHERE target IS NOT NULL AND target <> ''
        GROUP BY agent_id, sweep_group_id, target
    ),
    declared AS MATERIALIZED (
        SELECT row_number() OVER () AS d_id,
               d.agent_id,
               d.sweep_group_id,
               d.target,
               d.declared_device_uid,
               d.last_delivered_at,
               x.target_inet,
               -- a network target (masklen below host width) is matched by containment
               (x.target_inet IS NOT NULL AND masklen(x.target_inet) < x.maxlen) AS is_network,
               -- a host target is matched by equality on the NORMALIZED host text, so
               -- '203.0.113.9/32' and '203.0.113.9' are the same key; a target that is not
               -- an inet at all (hostname) falls back to its raw text.
               CASE WHEN x.target_inet IS NULL                  THEN d.target
                    WHEN masklen(x.target_inet) = x.maxlen      THEN host(x.target_inet)
               END AS host_key
        FROM declared_dedup d
        CROSS JOIN LATERAL (
            SELECT s.ti,
                   CASE WHEN s.ti IS NULL THEN NULL
                        WHEN family(s.ti) = 4 THEN 32 ELSE 128 END
            -- static_targets is unvalidated text[]; an unguarded ::inet cast would abort
            -- the whole view at query time on a value like 'not-an-ip'.
            FROM (SELECT CASE WHEN pg_input_is_valid(d.target, 'inet') THEN d.target::inet END) s(ti)
        ) x(target_inet, maxlen)
    ),
    observed_raw AS (
        SELECT device_uid, ip, sweep_group_id, agent_id,
               max(last_seen_at)     AS last_seen_at,
               sum(available_count)  AS available_count,
               sum(execution_count)  AS execution_count
        FROM platform.sweep_coverage_daily
        GROUP BY device_uid, ip, sweep_group_id, agent_id
    ),
    observed AS MATERIALIZED (
        SELECT row_number() OVER () AS o_id,
               o.device_uid, o.ip, o.sweep_group_id, o.agent_id,
               o.last_seen_at, o.available_count, o.execution_count,
               x.ip_inet,
               COALESCE(host(x.ip_inet), o.ip) AS ip_key
        FROM observed_raw o
        CROSS JOIN LATERAL (
            SELECT CASE WHEN pg_input_is_valid(o.ip, 'inet') THEN o.ip::inet END
        ) x(ip_inet)
    ),
    net_lens AS (
        -- The distinct prefix lengths that actually appear among declared network targets.
        -- Operators declare a handful (/24, /25, /48...), so this stays tiny.
        SELECT DISTINCT masklen(target_inet) AS len, family(target_inet) AS fam
        FROM declared
        WHERE is_network
    ),
    observed_net_keys AS (
        -- Expand every observed IP to its supernet at each declared prefix length.  This
        -- turns containment into EQUALITY, so the network arm is a hash join instead of the
        -- nested loop that `o.ip_inet <<= d.target_inet` forces (and which Postgres will not
        -- accept inside a FULL OUTER JOIN at all).
        SELECT o.o_id, o.device_uid, o.ip, o.sweep_group_id, o.agent_id,
               o.last_seen_at, o.available_count, o.execution_count,
               network(set_masklen(o.ip_inet, n.len)) AS net_key
        FROM observed o
        JOIN net_lens n ON n.fam = family(o.ip_inet)
        WHERE o.ip_inet IS NOT NULL
    ),
    covers_raw AS MATERIALIZED (
        -- Host arm: hash-joinable equality on the normalized host key.
        SELECT d.d_id, o.o_id,
               d.agent_id AS d_agent, d.sweep_group_id AS d_group, d.target AS declared_target,
               d.declared_device_uid, d.last_delivered_at,
               o.device_uid, o.ip, o.agent_id AS o_agent, o.sweep_group_id AS o_group,
               o.last_seen_at, o.available_count, o.execution_count,
               'host'::text AS match_via,
               1000 AS specificity
        FROM declared d
        JOIN observed o
          ON d.host_key = o.ip_key
         -- NULL group / NULL agent are first-class grain values on BOTH sides
         -- (sweep_coverage_daily writes NULLIF(...); agent_config_instances.agent_id IS NULL
         -- means partition-wide).  An unattributed key is compatible with any attributed one.
         AND (d.sweep_group_id IS NULL OR o.sweep_group_id IS NULL OR d.sweep_group_id = o.sweep_group_id)
         AND (d.agent_id       IS NULL OR o.agent_id       IS NULL OR d.agent_id       = o.agent_id)

        UNION ALL

        -- Network arm: containment, evaluated as equality on the supernet key.  Disjoint
        -- from the host arm by construction (host_key is NULL for network targets), so no
        -- de-duplication is needed between them.
        SELECT d.d_id, o.o_id,
               d.agent_id, d.sweep_group_id, d.target,
               d.declared_device_uid, d.last_delivered_at,
               o.device_uid, o.ip, o.agent_id, o.sweep_group_id,
               o.last_seen_at, o.available_count, o.execution_count,
               'network'::text,
               masklen(d.target_inet)
        FROM declared d
        JOIN observed_net_keys o
          ON network(d.target_inet) = o.net_key
         AND d.is_network
         AND (d.sweep_group_id IS NULL OR o.sweep_group_id IS NULL OR d.sweep_group_id = o.sweep_group_id)
         AND (d.agent_id       IS NULL OR o.agent_id       IS NULL OR d.agent_id       = o.agent_id)
    ),
    covers_keyed AS (
        SELECT COALESCE(c.d_group, c.o_group) AS sweep_group_id,
               COALESCE(c.d_agent, c.o_agent) AS agent_id,
               c.device_uid, c.ip, c.o_id,
               c.declared_target, c.specificity, c.match_via,
               c.declared_device_uid, c.last_delivered_at,
               c.last_seen_at, c.available_count, c.execution_count,
               -- compat matching guarantees equal-or-one-side-NULL, so IS DISTINCT FROM is
               -- true exactly when the match was inferred across a NULL.
               (c.d_group IS DISTINCT FROM c.o_group) AS group_inferred,
               (c.d_agent IS DISTINCT FROM c.o_agent) AS agent_inferred,
               -- one representative per (output key, coverage grain) so the counts below are
               -- summed once even when several declarations cover the same coverage row.
               (row_number() OVER (PARTITION BY COALESCE(c.d_group, c.o_group),
                                                COALESCE(c.d_agent, c.o_agent),
                                                c.device_uid, c.ip, c.o_id
                                   ORDER BY c.specificity DESC, c.declared_target) = 1) AS first_for_grain
        FROM covers_raw c
    ),
    covers AS (
        -- Output grain is (sweep group, agent, device, ip): a group that declares both
        -- 192.0.2.0/24 and 192.0.2.10 renders 192.0.2.10 ONCE.  Every declaration that
        -- covered the device is still visible in covering_declarations, so no declared
        -- target disappears from the view.
        SELECT sweep_group_id, agent_id, device_uid, ip,
               (array_agg(declared_target ORDER BY specificity DESC, declared_target))[1] AS declared_target,
               array_agg(DISTINCT declared_target)                                        AS covering_declarations,
               max(declared_device_uid)  AS declared_device_uid,
               max(last_delivered_at)    AS last_delivered_at,
               bool_and(group_inferred)  AS group_inferred,
               bool_and(agent_inferred)  AS agent_inferred,
               CASE WHEN bool_or(match_via = 'host') THEN 'host' ELSE 'network' END AS match_via,
               max(last_seen_at)    FILTER (WHERE first_for_grain) AS last_seen_at,
               sum(available_count) FILTER (WHERE first_for_grain) AS available_count,
               sum(execution_count) FILTER (WHERE first_for_grain) AS execution_count
        FROM covers_keyed
        GROUP BY 1, 2, 3, 4
    ),
    combined AS (
        -- 1. declared_and_observed
        SELECT c.sweep_group_id,
               c.agent_id,
               c.device_uid                        AS observed_device_uid,
               c.declared_device_uid,
               c.declared_target,
               c.covering_declarations,
               c.ip                                AS observed_ip,
               TRUE                                AS declared,
               TRUE                                AS observed,
               'declared_and_observed'::text       AS relationship,
               CASE WHEN c.group_inferred AND c.agent_inferred THEN 'inferred_group_and_agent'
                    WHEN c.group_inferred THEN 'inferred_group'
                    WHEN c.agent_inferred THEN 'inferred_agent'
                    ELSE 'exact' END               AS match_kind,
               c.match_via,
               c.last_seen_at, c.available_count, c.execution_count,
               c.last_delivered_at
        FROM covers c

        UNION ALL

        -- 2. declared_not_observed -- the alert this view exists to produce.
        SELECT d.sweep_group_id, d.agent_id,
               NULL::text, d.declared_device_uid, d.target, ARRAY[d.target],
               NULL::text,
               TRUE, FALSE,
               'declared_not_observed'::text,
               NULL::text, NULL::text,
               NULL::timestamp, NULL::numeric, NULL::numeric,
               d.last_delivered_at
        FROM declared d
        WHERE NOT EXISTS (SELECT 1 FROM covers_raw c WHERE c.d_id = d.d_id)

        UNION ALL

        -- 3. observed_not_declared
        SELECT o.sweep_group_id, o.agent_id,
               o.device_uid, NULL::text, NULL::text, NULL::text[],
               o.ip,
               FALSE, TRUE,
               'observed_not_declared'::text,
               NULL::text, NULL::text,
               o.last_seen_at, o.available_count, o.execution_count,
               NULL::timestamp
        FROM observed o
        WHERE NOT EXISTS (SELECT 1 FROM covers_raw c WHERE c.o_id = o.o_id)
    )
    SELECT
        COALESCE(r.observed_device_uid, r.declared_device_uid, dev.uid) AS device_uid,
        COALESCE(r.observed_ip, r.declared_target)                     AS ip,
        r.declared_target,
        r.covering_declarations,
        r.observed_ip,
        r.sweep_group_id,
        sg.name                                                        AS sweep_group_name,
        -- `admin_only` on a scanner profile is a row-level Ash READ restriction
        -- (`sweep_profile.ex`: `authorize_if expr(admin_only == false)`), and
        -- `networks.sweeps.view` is granted to @all_roles -- so projecting the
        -- profile here would hand every authenticated user the identity of a
        -- profile that `in:sweep_profiles` correctly hides from them. That is
        -- the same bypass closed for sweep_profiles itself; closing it there
        -- and leaving it open on a view that joins to the same table would be
        -- no fix at all.
        --
        -- MASK the two profile columns rather than dropping the row: "group G
        -- declared this device and never swept it" is the alert this view
        -- exists to raise, and it is equally true, and equally the operator's
        -- business, whether or not the profile behind it is admin-only.
        CASE WHEN sp.admin_only THEN NULL ELSE sg.profile_id END       AS profile_id,
        CASE WHEN sp.admin_only THEN NULL ELSE sp.name END             AS scanner_profile_name,
        sg.sweep_modes                                                 AS declared_modes,
        sg.ports                                                       AS declared_ports,
        r.agent_id,
        r.declared,
        r.observed,
        r.relationship,
        r.match_kind,
        r.match_via,
        r.last_seen_at,
        r.available_count,
        r.execution_count,
        r.last_delivered_at                                            AS config_delivered_at,
        -- device_agent_availability is UNIQUE(device_uid, agent_id): at most one row per
        -- device/agent, so at most one sweep group can own it and 'other_group' is a real
        -- state, not an anomaly.
        (daa.device_uid IS NOT NULL)                                   AS has_availability_row,
        daa.agent_id                                                   AS availability_agent_id,
        daa.sweep_group_id                                             AS availability_group_id,
        CASE WHEN daa.device_uid     IS NULL THEN 'none'
             WHEN daa.sweep_group_id IS NULL THEN 'unattributed'
             WHEN daa.sweep_group_id = r.sweep_group_id THEN 'this_group'
             ELSE 'other_group' END                                    AS availability_row_owner,
        -- NEVER derived from a nullable column of the outer-joined table:
        -- daa.device_uid is NOT NULL in the table, so NULL there can only mean "no match".
        (daa.device_uid     IS NOT NULL
         AND daa.sweep_group_id IS NOT NULL
         AND r.sweep_group_id   IS NOT NULL
         AND daa.sweep_group_id = r.sweep_group_id)                    AS owns_availability_row
    FROM combined r
    LEFT JOIN platform.sweep_groups   sg ON sg.id = r.sweep_group_id
    LEFT JOIN platform.sweep_profiles sp ON sp.id = sg.profile_id
    -- Device resolution, in order: the observed coverage row, then the device_uid the
    -- compiler already wrote into device_targets[].metadata (authoritative), then a lookup
    -- by host IP.  That lookup is scoped to the group's partition and to live rows.
    --
    -- The partition scope is here for CORRECTNESS, not for the index: an unscoped
    -- lookup can resolve a declared target to a device in someone else's partition.
    -- `ocsf_devices_unique_active_ip_idx` is UNIQUE ON (ip) WHERE deleted_at IS NULL
    -- AND ip IS NOT NULL AND ip <> '' -- `ip` alone, no partition column -- so the
    -- `deleted_at IS NULL` and non-empty-ip predicates are what let this use it, and
    -- the scoped and unscoped forms would use it equally well. A consequence worth
    -- knowing: that index makes `ip` unique among live rows, so the ORDER BY below
    -- can never actually break a tie; it is there to keep the result deterministic
    -- if the index is ever relaxed.
    LEFT JOIN LATERAL (
        SELECT d2.uid
        FROM platform.ocsf_devices d2
        WHERE r.observed_device_uid IS NULL
          AND r.declared_device_uid IS NULL
          AND r.declared_target IS NOT NULL
          AND sg.partition IS NOT NULL
          AND d2.partition = sg.partition
          AND d2.ip = r.declared_target
          AND d2.ip IS NOT NULL
          AND d2.ip <> ''
          AND d2.deleted_at IS NULL
        ORDER BY d2.last_seen_time DESC NULLS LAST, d2.uid
        LIMIT 1
    ) dev ON TRUE
    LEFT JOIN LATERAL (
        SELECT a.device_uid, a.agent_id, a.sweep_group_id
        FROM platform.device_agent_availability a
        WHERE a.device_uid = COALESCE(r.observed_device_uid, r.declared_device_uid, dev.uid)
          AND (r.agent_id IS NULL OR a.agent_id = r.agent_id)
        ORDER BY (a.agent_id IS NOT DISTINCT FROM r.agent_id) DESC, a.checked_at DESC, a.agent_id
        LIMIT 1
    ) daa ON TRUE
    """)
  end

  def down do
    execute("DROP VIEW IF EXISTS platform.device_sweep_overlap")
  end
end
