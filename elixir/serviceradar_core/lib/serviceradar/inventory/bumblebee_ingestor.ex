defmodule ServiceRadar.Inventory.BumblebeeIngestor do
  @moduledoc """
  Ingests sanitized Bumblebee scan summaries from an agent spool.

  The root-owned scanner owns host filesystem traversal. This ingestor only
  accepts already-sanitized posture and finding data, associates it to the
  agent's canonical device, and publishes a source-specific risk contribution.
  """

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Inventory.DeviceRiskReducer
  alias ServiceRadar.Repo

  require Ash.Query

  @source "bumblebee"
  @severity_scores %{
    "critical" => 95,
    "high" => 80,
    "medium" => 55,
    "low" => 25,
    "info" => 5,
    "informational" => 5
  }
  @severity_rank %{
    "critical" => 5,
    "high" => 4,
    "medium" => 3,
    "low" => 2,
    "info" => 1,
    "informational" => 1
  }

  @doc """
  Ingest a single scan payload.

  Expected payload keys are intentionally broad so the scanner spool can evolve:
  `agent_id`, optional `device_uid`, `run_id`, `catalog_snapshot_ref`,
  `scanner_version`, root coverage counts, `skipped_roots`, and `findings`.
  """
  def ingest_scan(payload, opts \\ []) when is_map(payload) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:bumblebee_ingestor))

    with {:ok, agent_id} <- required_string(payload, :agent_id),
         {:ok, context} <- build_context(payload, agent_id, actor) do
      Repo.transaction(fn ->
        finding_records = build_finding_records(payload, context)
        upsert_posture(payload, context, finding_records)
        backfill_posture_device_uid(context)
        backfill_pending_findings(context)
        upsert_findings(context, finding_records)
        resolve_stale_findings(context, finding_records)
        upsert_risk_contribution(context, finding_records)

        %{
          agent_id: context.agent_id,
          device_uid: context.device_uid,
          active_finding_count: length(finding_records),
          risk_score: context.risk_score,
          coverage_state: context.coverage_state
        }
      end)
    end
  end

  defp build_context(payload, agent_id, actor) do
    now = DateTime.utc_now()
    findings = list_value(payload, :findings)

    device_uid =
      string_value(payload, :device_uid) || resolve_agent_device_uid(agent_id, actor) ||
        existing_posture_device_uid(agent_id)

    skipped_roots = normalize_skipped_roots(value(payload, :skipped_roots, []))

    attempted_root_count =
      integer_value(payload, :attempted_root_count, nil) || root_count(payload, :attempted_roots)

    scanned_root_count =
      integer_value(payload, :scanned_root_count, nil) || root_count(payload, :scanned_roots)

    skipped_root_count = integer_value(payload, :skipped_root_count, nil) || length(skipped_roots)
    root_covered = boolean_value(payload, :root_covered)

    coverage_state =
      coverage_state(
        payload,
        attempted_root_count,
        scanned_root_count,
        skipped_root_count,
        root_covered
      )

    finding_scores = Enum.map(findings, &finding_risk_score/1)
    finding_risk = Enum.max([0 | finding_scores])
    risk_score = max(finding_risk, coverage_risk_score(coverage_state))
    highest_severity = highest_severity(findings)

    scan_time =
      datetime_value(payload, :last_scan_at) || datetime_value(payload, :scanned_at) || now

    {:ok,
     %{
       agent_id: agent_id,
       device_uid: device_uid,
       run_id:
         string_value(payload, :run_id) || "scan-#{DateTime.to_unix(scan_time, :microsecond)}",
       catalog_snapshot_ref: string_value(payload, :catalog_snapshot_ref),
       scanner_version: string_value(payload, :scanner_version),
       attempted_root_count: attempted_root_count,
       scanned_root_count: scanned_root_count,
       skipped_root_count: skipped_root_count,
       root_covered: root_covered,
       skipped_roots: skipped_roots,
       coverage_state: coverage_state,
       state: scan_state(payload),
       risk_score: risk_score,
       highest_severity: highest_severity,
       last_scan_at: scan_time,
       last_successful_scan_at: successful_scan_time(payload, scan_time),
       now: now,
       metadata: metadata(payload)
     }}
  end

  defp upsert_posture(payload, context, finding_records) do
    row = %{
      device_uid: context.device_uid,
      agent_id: context.agent_id,
      run_id: context.run_id,
      catalog_snapshot_ref: context.catalog_snapshot_ref,
      scanner_version: context.scanner_version,
      state: context.state,
      coverage_state: context.coverage_state,
      attempted_root_count: context.attempted_root_count,
      scanned_root_count: context.scanned_root_count,
      skipped_root_count: context.skipped_root_count,
      root_covered: context.root_covered,
      skipped_roots: context.skipped_roots,
      risk_score: context.risk_score,
      highest_severity: context.highest_severity,
      active_finding_count: length(finding_records),
      last_successful_scan_at: context.last_successful_scan_at,
      last_scan_at: context.last_scan_at,
      metadata: Map.merge(context.metadata, posture_metadata(payload, context)),
      inserted_at: context.now,
      updated_at: context.now
    }

    Repo.insert_all(
      "bumblebee_device_postures",
      [row],
      prefix: "platform",
      on_conflict:
        {:replace,
         [
           :run_id,
           :catalog_snapshot_ref,
           :scanner_version,
           :state,
           :coverage_state,
           :attempted_root_count,
           :scanned_root_count,
           :skipped_root_count,
           :root_covered,
           :skipped_roots,
           :risk_score,
           :highest_severity,
           :active_finding_count,
           :last_successful_scan_at,
           :last_scan_at,
           :metadata,
           :updated_at
         ]},
      conflict_target: [:agent_id]
    )
  end

  defp backfill_posture_device_uid(%{device_uid: nil}), do: :ok

  defp backfill_posture_device_uid(context) do
    query =
      from(p in "bumblebee_device_postures",
        where: p.agent_id == ^context.agent_id and is_nil(p.device_uid)
      )

    Repo.update_all(
      query,
      [set: [device_uid: context.device_uid, updated_at: context.now]],
      prefix: "platform"
    )

    :ok
  end

  defp backfill_pending_findings(%{device_uid: nil}), do: :ok

  defp backfill_pending_findings(context) do
    query =
      from(f in "bumblebee_findings",
        where: f.agent_id == ^context.agent_id and is_nil(f.device_uid)
      )

    Repo.update_all(
      query,
      [set: [device_uid: context.device_uid, updated_at: context.now]],
      prefix: "platform"
    )

    :ok
  end

  defp upsert_findings(_context, []), do: :ok

  defp upsert_findings(context, finding_records) do
    rows =
      Enum.map(finding_records, fn finding ->
        finding
        |> Map.put(:inserted_at, context.now)
        |> Map.put(:updated_at, context.now)
      end)

    Repo.insert_all(
      "bumblebee_findings",
      rows,
      prefix: "platform",
      on_conflict:
        {:replace,
         [
           :device_uid,
           :run_id,
           :catalog_id,
           :catalog_snapshot_ref,
           :scanner_version,
           :severity,
           :risk_score,
           :ecosystem,
           :package_name,
           :package_version,
           :evidence,
           :confidence,
           :status,
           :last_seen_at,
           :resolved_at,
           :metadata,
           :updated_at
         ]},
      conflict_target: [:agent_id, :finding_id]
    )
  end

  defp resolve_stale_findings(context, finding_records) do
    active_ids = Enum.map(finding_records, & &1.finding_id)

    query =
      from(f in "bumblebee_findings",
        where: f.agent_id == ^context.agent_id and f.status == "active"
      )

    query =
      if active_ids == [] do
        query
      else
        from(f in query, where: f.finding_id not in ^active_ids)
      end

    Repo.update_all(
      query,
      [
        set: [
          status: "resolved",
          resolved_at: context.now,
          updated_at: context.now
        ]
      ],
      prefix: "platform"
    )
  end

  defp upsert_risk_contribution(%{device_uid: nil}, _finding_records), do: :ok

  defp upsert_risk_contribution(context, finding_records) do
    source_ref = "agent:#{context.agent_id}"

    DeviceRiskReducer.resolve_other_contributions(@source, source_ref, context.device_uid)

    DeviceRiskReducer.upsert_contribution(%{
      device_uid: context.device_uid,
      source: @source,
      source_ref: source_ref,
      score: context.risk_score,
      reason: risk_reason(context, finding_records),
      occurred_at: context.last_scan_at,
      metadata: %{
        "agent_id" => context.agent_id,
        "run_id" => context.run_id,
        "catalog_snapshot_ref" => context.catalog_snapshot_ref,
        "scanner_version" => context.scanner_version,
        "coverage_state" => context.coverage_state,
        "active_finding_count" => length(finding_records),
        "highest_severity" => context.highest_severity
      }
    })
  end

  defp build_finding_records(payload, context) do
    payload
    |> list_value(:findings)
    |> Enum.map(&normalize_finding(&1, context))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.finding_id)
  end

  defp normalize_finding(finding, context) when is_map(finding) do
    severity = normalize_severity(string_value(finding, :severity) || "info")

    risk_score =
      integer_value(finding, :risk_score, nil) || Map.get(@severity_scores, severity, 5)

    finding_id =
      string_value(finding, :finding_id) || string_value(finding, :id) ||
        generated_finding_id(finding)

    now = context.now

    %{
      device_uid: context.device_uid,
      agent_id: context.agent_id,
      run_id: context.run_id,
      finding_id: finding_id,
      catalog_id: string_value(finding, :catalog_id),
      catalog_snapshot_ref: context.catalog_snapshot_ref,
      scanner_version: context.scanner_version,
      severity: severity,
      risk_score: clamp_score(risk_score),
      ecosystem: string_value(finding, :ecosystem),
      package_name: string_value(finding, :package_name) || string_value(finding, :package),
      package_version: string_value(finding, :package_version) || string_value(finding, :version),
      evidence: map_value(finding, :evidence),
      confidence: string_value(finding, :confidence),
      status: "active",
      first_seen_at: datetime_value(finding, :first_seen_at) || now,
      last_seen_at: datetime_value(finding, :last_seen_at) || context.last_scan_at,
      resolved_at: nil,
      metadata: metadata(finding)
    }
  end

  defp normalize_finding(_finding, _context), do: nil

  defp resolve_agent_device_uid(agent_id, actor) do
    query = Ash.Query.for_read(Agent, :by_uid, %{uid: agent_id})

    case Ash.read_one(query, actor: actor) do
      {:ok, %{device_uid: device_uid}} when is_binary(device_uid) and device_uid != "" ->
        device_uid

      _ ->
        nil
    end
  end

  defp existing_posture_device_uid(agent_id) do
    query =
      from(p in "bumblebee_device_postures",
        where: p.agent_id == ^agent_id and not is_nil(p.device_uid),
        select: p.device_uid,
        limit: 1
      )

    Repo.one(query, prefix: "platform")
  end

  defp risk_reason(context, finding_records) do
    cond do
      finding_records != [] ->
        "Bumblebee detected #{length(finding_records)} active developer endpoint exposure(s)"

      context.coverage_state != "complete" ->
        "Bumblebee scan coverage is #{context.coverage_state}"

      true ->
        "Bumblebee scan reported no active exposures"
    end
  end

  defp coverage_state(payload, attempted, scanned, skipped, root_covered) do
    explicit = string_value(payload, :coverage_state)

    cond do
      explicit in ["complete", "partial", "not_scanned", "failed"] -> explicit
      scanned == 0 -> "not_scanned"
      root_covered == false or skipped > 0 or scanned < attempted -> "partial"
      true -> "complete"
    end
  end

  defp coverage_risk_score("failed"), do: 45
  defp coverage_risk_score("partial"), do: 40
  defp coverage_risk_score(_), do: 0

  defp scan_state(payload) do
    case string_value(payload, :state) || string_value(payload, :status) do
      value when value in ["scanned", "scan_failed", "not_scanned"] -> value
      "failed" -> "scan_failed"
      _ -> "scanned"
    end
  end

  defp successful_scan_time(payload, scan_time) do
    case scan_state(payload) do
      "scanned" -> datetime_value(payload, :last_successful_scan_at) || scan_time
      _ -> datetime_value(payload, :last_successful_scan_at)
    end
  end

  defp highest_severity(findings) do
    findings
    |> Enum.map(&(string_value(&1, :severity) || "info"))
    |> Enum.map(&normalize_severity/1)
    |> Enum.max_by(&Map.get(@severity_rank, &1, 0), fn -> nil end)
  end

  defp finding_risk_score(finding) when is_map(finding) do
    severity = normalize_severity(string_value(finding, :severity) || "info")
    integer_value(finding, :risk_score, nil) || Map.get(@severity_scores, severity, 5)
  end

  defp finding_risk_score(_finding), do: 0

  defp generated_finding_id(finding) do
    [
      string_value(finding, :catalog_id),
      string_value(finding, :ecosystem),
      string_value(finding, :package_name) || string_value(finding, :package),
      string_value(finding, :package_version) || string_value(finding, :version)
    ]
    |> Enum.map_join("|", &(&1 || ""))
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp posture_metadata(payload, context) do
    %{
      "source" => @source,
      "attempted_root_count" => context.attempted_root_count,
      "scanned_root_count" => context.scanned_root_count,
      "skipped_root_count" => context.skipped_root_count,
      "raw_state" => string_value(payload, :state) || string_value(payload, :status)
    }
  end

  defp required_string(payload, key) do
    case string_value(payload, key) do
      nil -> {:error, {:missing_required_key, key}}
      value -> {:ok, value}
    end
  end

  defp value(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp string_value(map, key) when is_map(map) do
    case value(map, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      value when is_atom(value) and not is_nil(value) ->
        Atom.to_string(value)

      value when is_integer(value) ->
        Integer.to_string(value)

      _ ->
        nil
    end
  end

  defp string_value(_map, _key), do: nil

  defp integer_value(map, key, default) when is_map(map) do
    case value(map, key) do
      value when is_integer(value) -> value
      value when is_float(value) -> round(value)
      value when is_binary(value) -> parse_integer(value, default)
      _ -> default
    end
  end

  defp integer_value(_map, _key, default), do: default

  defp parse_integer(value, default) do
    case Integer.parse(String.trim(value)) do
      {int, _rest} -> int
      :error -> default
    end
  end

  defp boolean_value(map, key) when is_map(map) do
    case value(map, key) do
      value when is_boolean(value) -> value
      value when is_binary(value) -> String.downcase(String.trim(value)) in ["true", "1", "yes"]
      _ -> nil
    end
  end

  defp boolean_value(_map, _key), do: nil

  defp datetime_value(map, key) when is_map(map) do
    case value(map, key) do
      %DateTime{} = dt ->
        dt

      %NaiveDateTime{} = ndt ->
        DateTime.from_naive!(ndt, "Etc/UTC")

      value when is_binary(value) ->
        parse_datetime(value)

      _ ->
        nil
    end
  end

  defp datetime_value(_map, _key), do: nil

  defp parse_datetime(value) do
    value = String.trim(value)

    with {:error, _} <- DateTime.from_iso8601(value),
         {:ok, ndt} <- NaiveDateTime.from_iso8601(value) do
      DateTime.from_naive!(ndt, "Etc/UTC")
    else
      {:ok, dt, _offset} -> dt
      {:error, _} -> nil
    end
  end

  defp list_value(map, key) when is_map(map) do
    case value(map, key, []) do
      value when is_list(value) -> value
      _ -> []
    end
  end

  defp list_value(_map, _key), do: []

  defp map_value(map, key) when is_map(map) do
    case value(map, key, %{}) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp map_value(_map, _key), do: %{}

  defp metadata(map) when is_map(map), do: map_value(map, :metadata)
  defp metadata(_map), do: %{}

  defp root_count(payload, key) do
    payload
    |> list_value(key)
    |> length()
  end

  defp normalize_skipped_roots(roots) when is_list(roots) do
    Enum.map(roots, fn
      root when is_binary(root) -> %{"path" => root}
      root when is_map(root) -> stringify_keys(root)
      _ -> %{}
    end)
  end

  defp normalize_skipped_roots(_roots), do: []

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_severity(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> "info"
      "informational" -> "info"
      value -> value
    end
  end

  defp normalize_severity(_value), do: "info"

  defp clamp_score(score) when is_integer(score), do: score |> max(0) |> min(100)
  defp clamp_score(_score), do: 0
end
