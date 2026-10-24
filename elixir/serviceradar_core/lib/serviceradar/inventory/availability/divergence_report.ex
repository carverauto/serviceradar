defmodule ServiceRadar.Inventory.Availability.DivergenceReport do
  @moduledoc """
  The stage-b divergence report of `add-merged-device-availability`: what the resolver's
  shadow decisions would change, measured before anything switches (design Decision 10,
  stage b). Read-only.

  It counts live devices by legacy `is_available`, legacy badge, shadow state and the
  deciding `source_kind` and `authority_class`, with up to 20 sample uids per cell, and
  reports:

    * devices that would become `unknown`, and how many of them hold `is_available` true;
    * devices whose state would change, policy violations, invalid pins and conflicts;
    * for every canonical Armis northbound source (no agent selected), how many linked
      Armis ids would push a different value under `merged` semantics, and in which
      direction (unknown is withheld);
    * review finding R5: evidence flips to `down` inside the coalescing window
      (`EvidencePlan.coalesced_flip_key/0`), and decisions whose deciding observation is
      within half a lease of a disagreeing fresh one.

  The legacy badge is web-ng's `DeviceLive.IndexData.Availability.effective_availability/2`:
  fresh per-agent rows (checked within 2 hours) decide, the pinned agent's row when the
  device is pinned, otherwise any reachable agent; with no fresh row (or no fresh row from
  the pinned agent) the column shows.

  Every query runs in one read-only transaction under a statement timeout, so the report
  can never write and never waits on a writer (it takes no row locks). Sections are read
  at `READ COMMITTED`, so on a busy deployment two sections may differ by the writes that
  landed between them. Each section is one aggregate pass; nothing is loaded per device.

  Run it on a deployment with

      bin/serviceradar_core rpc 'ServiceRadar.Inventory.Availability.Operator.report()'

  or `mix serviceradar.availability.report`.
  """

  import Ecto.Query

  alias ServiceRadar.Integrations.ArmisAvailabilityPreview
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Inventory.Availability.EvidencePlan
  alias ServiceRadar.Inventory.Availability.Resolver
  alias ServiceRadar.Repo

  @samples 20
  @statement_timeout_ms 120_000
  @log_count_cap 100_000

  @devices_cte """
  WITH dev AS (
    SELECT d.uid, d.is_available, NULLIF(btrim(d.availability_source_agent_id), '') AS pin,
           s.device_uid IS NOT NULL AS resolved,
           COALESCE(s.availability_state, 'unresolved') AS shadow_state,
           s.decided_by, COALESCE(s.conflict, false) AS conflict, s.agents
    FROM platform.ocsf_devices AS d
    LEFT JOIN platform.device_availability_shadow AS s ON s.device_uid = d.uid
    WHERE d.deleted_at IS NULL
  )
  , badged AS (
    SELECT dev.*,
           CASE
             WHEN fresh.n = 0 THEN dev.is_available
             WHEN dev.pin IS NOT NULL THEN COALESCE(fresh.pinned, dev.is_available)
             ELSE fresh.any_up
           END AS legacy_badge
    FROM dev
    LEFT JOIN LATERAL (
      SELECT count(*) AS n,
             bool_or(a.is_available) AS any_up,
             bool_or(a.is_available) FILTER (WHERE a.agent_id = dev.pin) AS pinned
      FROM platform.device_agent_availability AS a
      WHERE a.device_uid = dev.uid
        AND a.checked_at > (now() AT TIME ZONE 'utc') - interval '2 hours'
    ) AS fresh ON true
  )
  """

  @cells @devices_cte <>
           """
           SELECT is_available, legacy_badge, shadow_state,
                  decided_by ->> 'source_kind', decided_by ->> 'authority_class',
                  count(*), (array_agg(uid ORDER BY uid))[1:$1]
           FROM badged
           GROUP BY 1, 2, 3, 4, 5
           ORDER BY count(*) DESC, 3, 4, 5
           """

  @summary @devices_cte <>
             """
             SELECT
               count(*),
               count(*) FILTER (WHERE resolved),
               count(*) FILTER (WHERE shadow_state = 'unknown'),
               count(*) FILTER (WHERE shadow_state = 'unknown' AND is_available),
               (array_agg(uid ORDER BY uid) FILTER (WHERE shadow_state = 'unknown'))[1:$1],
               count(*) FILTER (WHERE resolved
                 AND shadow_state <> platform.availability_projection(is_available)),
               (array_agg(uid ORDER BY uid) FILTER (WHERE resolved
                 AND shadow_state <> platform.availability_projection(is_available)))[1:$1],
               count(*) FILTER (WHERE resolved
                 AND shadow_state <> platform.availability_projection(legacy_badge)),
               count(*) FILTER (WHERE COALESCE((agents ->> 'policy_violation')::int, 0) > 0),
               (array_agg(uid ORDER BY uid)
                 FILTER (WHERE COALESCE((agents ->> 'policy_violation')::int, 0) > 0))[1:$1],
               count(*) FILTER (WHERE COALESCE((decided_by ->> 'invalid_pin')::boolean, false)),
               (array_agg(uid ORDER BY uid)
                 FILTER (WHERE COALESCE((decided_by ->> 'invalid_pin')::boolean, false)))[1:$1],
               count(*) FILTER (WHERE conflict),
               (array_agg(uid ORDER BY uid) FILTER (WHERE conflict))[1:$1],
               count(*) FILTER (WHERE COALESCE((agents ->> 'down')::int, 0) > 0
                 AND shadow_state = 'available'),
               count(*) FILTER (WHERE decided_by ->> 'rule' = 'hysteresis_hold')
             FROM badged
             """

  @transitions @devices_cte <>
                 """
                 SELECT platform.availability_projection(is_available), shadow_state, count(*)
                 FROM dev
                 GROUP BY 1, 2
                 ORDER BY 1, 2
                 """

  @coalesced_flips """
  SELECT e.source_kind, e.authority_class, count(*), (array_agg(e.device_uid ORDER BY e.device_uid))[1:$2]
  FROM platform.device_availability_evidence AS e
  JOIN platform.ocsf_devices AS d ON d.uid = e.device_uid AND d.deleted_at IS NULL
  WHERE e.state = 'down' AND e.detail ? $1
  GROUP BY 1, 2
  ORDER BY 3 DESC, 1, 2
  """

  # A decision whose deciding observation is within half its lease of a fresh observation
  # that disagrees: where coalesced or reordered observations could have decided it.
  @near_conflicts """
  WITH decided AS (
    SELECT s.device_uid, s.availability_state AS state,
           s.decided_by ->> 'source_kind' AS kind,
           COALESCE(s.decided_by ->> 'source_instance', '') AS instance,
           COALESCE(s.decided_by ->> 'reporter_agent_id', '') AS reporter
    FROM platform.device_availability_shadow AS s
    JOIN platform.ocsf_devices AS d ON d.uid = s.device_uid AND d.deleted_at IS NULL
    WHERE s.decided_by ->> 'rule' = 'highest_class'
  )
  , decider AS (
    SELECT x.device_uid, x.state, e.observed_at AS at, (e.expires_at - e.observed_at) / 2 AS half
    FROM decided AS x
    JOIN platform.device_availability_evidence AS e
      ON e.device_uid = x.device_uid AND e.source_kind = x.kind
     AND e.source_instance = x.instance AND e.reporter_agent_id = x.reporter
    UNION ALL
    SELECT x.device_uid, x.state, a.checked_at,
           platform.availability_ledger_ttl(a.sweep_group_id) / 2
    FROM decided AS x
    JOIN platform.device_agent_availability AS a
      ON a.device_uid = x.device_uid AND a.agent_id = x.reporter
    WHERE x.kind = $1
  )
  , near AS (
    SELECT DISTINCT dc.device_uid
    FROM decider AS dc
    WHERE EXISTS (
      SELECT 1 FROM platform.device_availability_evidence AS o
      WHERE o.device_uid = dc.device_uid AND o.reporter_eligible
        AND o.expires_at > (now() AT TIME ZONE 'utc')
        AND (CASE WHEN o.state = 'up' THEN 'available' ELSE 'unavailable' END) <> dc.state
        AND abs(extract(epoch FROM o.observed_at - dc.at)) < extract(epoch FROM dc.half)
    ) OR EXISTS (
      SELECT 1 FROM platform.device_agent_availability AS o
      WHERE o.device_uid = dc.device_uid
        AND o.checked_at + platform.availability_ledger_ttl(o.sweep_group_id)
            > (now() AT TIME ZONE 'utc')
        AND (CASE WHEN o.is_available THEN 'available' ELSE 'unavailable' END) <> dc.state
        AND abs(extract(epoch FROM o.checked_at - dc.at)) < extract(epoch FROM dc.half)
        AND NOT EXISTS (
          SELECT 1 FROM platform.device_vantage_expectations AS v
          WHERE v.device_uid = o.device_uid AND v.agent_id = o.agent_id
            AND v.expectation = 'blocked'
        )
    )
  )
  SELECT count(*), (array_agg(device_uid ORDER BY device_uid))[1:$2] FROM near
  """

  @status """
  SELECT platform.availability_mode(),
         (SELECT expiry_watermark FROM platform.availability_settings WHERE singleton),
         (SELECT count(*) FROM (
            SELECT 1 FROM platform.availability_invalidations LIMIT $1
          ) AS capped),
         now() AT TIME ZONE 'utc'
  """

  @doc """
  Builds the report. Options: `:samples` (sample uids per cell, default #{@samples}).
  """
  @spec build(keyword()) :: map()
  def build(opts \\ []) do
    samples = Keyword.get(opts, :samples, @samples)
    query_opts = [timeout: @statement_timeout_ms + 5_000]

    {:ok, report} =
      Repo.transaction(
        fn ->
          # Read-only can be set at any point, also when nested in a caller's transaction.
          Repo.query!("SET LOCAL transaction_read_only = on")
          Repo.query!("SET LOCAL statement_timeout = #{@statement_timeout_ms}")

          %{
            status: status(query_opts),
            devices: summary(samples, query_opts),
            transitions: transitions(query_opts),
            cells: cells(samples, query_opts),
            armis: armis(samples, query_opts),
            r5: r5(samples, query_opts)
          }
        end,
        timeout: :infinity
      )

    report
  end

  @doc "A short human summary of a built report."
  @spec summary_text(map()) :: String.t()
  def summary_text(report) do
    %{status: status, devices: devices, r5: r5} = report

    armis =
      Enum.map(report.armis, fn source ->
        "  armis source #{source.name} (#{source.id}): #{source.linked_ids} linked ids, " <>
          "#{source.would_change} would push a different value, #{source.withheld} withheld"
      end)

    Enum.join(
      [
        "availability divergence report (mode #{status.mode}, generated #{status.generated_at})",
        "  live devices #{devices.total}, resolved #{devices.resolved}, " <>
          "state would change for #{devices.would_change.count}, " <>
          "differs from the legacy badge for #{devices.differs_from_badge}",
        "  would become unknown #{devices.would_become_unknown.count} " <>
          "(#{devices.would_become_unknown.holding_is_available_true} of them hold is_available true)",
        "  conflicts #{devices.conflicts.count}, policy violations " <>
          "#{devices.policy_violations.count}, invalid pins #{devices.invalid_pins.count}, " <>
          "hysteresis holds #{devices.hysteresis_holds}",
        "  R5: #{Enum.sum(Enum.map(r5.coalesced_flips, & &1.count))} coalesced flips to down, " <>
          "#{r5.near_conflicts.count} decisions within half a lease of a disagreeing observation",
        "  invalidation log backlog #{status.invalidation_backlog}" <>
          if(status.invalidation_backlog_capped, do: "+", else: "")
        | armis
      ],
      "\n"
    )
  end

  defp status(query_opts) do
    %{rows: [[mode, watermark, backlog, now]]} =
      Repo.query!(@status, [@log_count_cap], query_opts)

    %{
      mode: mode,
      generated_at: iso8601(now),
      expiry_watermark: iso8601(watermark),
      expiry_lag_seconds: watermark && NaiveDateTime.diff(now, watermark),
      invalidation_backlog: backlog,
      invalidation_backlog_capped: backlog >= @log_count_cap
    }
  end

  defp summary(samples, query_opts) do
    %{
      rows: [
        [
          total,
          resolved,
          unknown,
          unknown_true,
          unknown_samples,
          changes,
          change_samples,
          differs_from_badge,
          violations,
          violation_samples,
          invalid_pins,
          invalid_pin_samples,
          conflicts,
          conflict_samples,
          partially_reachable,
          holds
        ]
      ]
    } = Repo.query!(@summary, [samples], query_opts)

    %{
      total: total,
      resolved: resolved,
      unresolved: total - resolved,
      would_become_unknown: %{
        count: unknown,
        holding_is_available_true: unknown_true,
        samples: unknown_samples || []
      },
      would_change: %{count: changes, samples: change_samples || []},
      differs_from_badge: differs_from_badge,
      policy_violations: %{count: violations, samples: violation_samples || []},
      invalid_pins: %{count: invalid_pins, samples: invalid_pin_samples || []},
      conflicts: %{count: conflicts, samples: conflict_samples || []},
      available_with_unreachable_agents: partially_reachable,
      hysteresis_holds: holds
    }
  end

  defp transitions(query_opts) do
    %{rows: rows} = Repo.query!(@transitions, [], query_opts)

    Enum.map(rows, fn [legacy, shadow, count] ->
      %{legacy_state: legacy, shadow_state: shadow, count: count}
    end)
  end

  defp cells(samples, query_opts) do
    %{rows: rows} = Repo.query!(@cells, [samples], query_opts)

    Enum.map(rows, fn [legacy, badge, shadow, kind, class, count, uids] ->
      %{
        legacy_is_available: legacy,
        legacy_badge: badge_label(badge),
        shadow_state: shadow,
        source_kind: kind,
        authority_class: class,
        count: count,
        samples: uids || []
      }
    end)
  end

  defp r5(samples, query_opts) do
    %{rows: flips} =
      Repo.query!(@coalesced_flips, [EvidencePlan.coalesced_flip_key(), samples], query_opts)

    %{rows: [[near, near_samples]]} =
      Repo.query!(@near_conflicts, [Resolver.ledger_kind(), samples], query_opts)

    %{
      coalesced_flips:
        Enum.map(flips, fn [kind, class, count, uids] ->
          %{source_kind: kind, authority_class: class, count: count, samples: uids || []}
        end),
      near_conflicts: %{count: near, samples: near_samples || []}
    }
  end

  # -- Armis northbound ------------------------------------------------------------------

  defp armis(samples, query_opts) do
    IntegrationSource
    |> where([s], s.source_type == :armis)
    |> select([s], %{
      id: s.id,
      name: s.name,
      northbound_enabled: s.northbound_enabled,
      northbound_availability_source_agent_id: s.northbound_availability_source_agent_id,
      northbound_availability_semantics: s.northbound_availability_semantics
    })
    |> order_by([s], s.name)
    |> Repo.all(query_opts)
    |> Enum.filter(&canonical?/1)
    |> Enum.map(&armis_source(&1, samples, query_opts))
  end

  defp canonical?(source) do
    case source.northbound_availability_source_agent_id do
      agent_id when is_binary(agent_id) -> String.trim(agent_id) == ""
      _ -> true
    end
  end

  # The same per-source counts the settings preview shows once a forecast exists:
  # legacy (the compatibility value) against merged (the shadow state here).
  defp armis_source(source, samples, query_opts) do
    preview = ArmisAvailabilityPreview.build(source, samples: samples, query_opts: query_opts)

    Map.merge(preview, %{
      id: to_string(source.id),
      name: source.name,
      northbound_enabled: source.northbound_enabled,
      semantics: to_string(source.northbound_availability_semantics)
    })
  end

  defp badge_label(true), do: "online"
  defp badge_label(false), do: "offline"
  defp badge_label(nil), do: "none"

  defp iso8601(%NaiveDateTime{} = at),
    do: at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  defp iso8601(_at), do: nil
end
