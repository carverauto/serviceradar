defmodule ServiceRadar.EventWriter.DeviceCorrelation do
  @moduledoc """
  Resolves scanner/event identities to canonical inventory device UIDs.

  Event producers often know a hostname, node name, agent id, or IP address before
  they know the canonical `ocsf_devices.uid`. This helper keeps OCSF event
  metadata stable by preferring explicit device UIDs, then agent mappings, then
  inventory IP/hostname lookups.
  """

  import Ash.Expr

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.EventWriter.DeviceCorrelationCache
  alias ServiceRadar.Identity.DeviceLookup
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.Identity.Resolver
  alias ServiceRadar.Repo

  require Ash.Query
  require Logger

  @lookup_timeout_ms 1_500

  @type candidate :: %{
          optional(:device_uid) => String.t() | nil,
          optional(:agent_id) => String.t() | nil,
          optional(:ip) => String.t() | nil,
          optional(:hostname) => String.t() | nil,
          optional(:name) => String.t() | nil,
          optional(:partition) => String.t() | nil,
          optional(:pod_uid) => String.t() | nil,
          optional(:pod_namespace) => String.t() | nil,
          optional(:pod_name) => String.t() | nil,
          optional(:container_id) => String.t() | nil
        }

  @spec resolve(candidate()) :: String.t() | nil
  def resolve(candidate) when is_map(candidate) do
    # Cache the full resolution keyed by the correlation inputs so a burst of
    # events for the same device costs one DB lookup per device (cache miss)
    # rather than one set of DB round-trips per event. The cache is fail-open:
    # on any cache error it runs `resolve_uncached/1` directly.
    DeviceCorrelationCache.fetch(candidate, fn -> resolve_uncached(candidate) end)
  end

  def resolve(_), do: nil

  @doc """
  Resolve an SNMP/interface anomaly to the canonical device that owns the
  persisted interface metric tuple.

  SNMP polling runs from an agent, but the metric belongs to the polled network
  device. This resolver intentionally does not use the anomaly series key and
  does not fall back to the polling agent: it resolves by
  `{device_id, metric_name, if_index}` against recent persisted metrics, with
  the interface hourly rollup as a longer-retention fallback.
  """
  # The SNMP/interface path normalizes free-form anomaly payload values
  # (`candidate_value/2`, `normalize_if_index/1`, `canonical_device_uid/1`
  # all accept `term()`), so its input shape is wider than `candidate/0`.
  @type snmp_metric_candidate :: %{
          optional(:device_uid) => term(),
          optional(:target_device_ip) => term(),
          optional(:ip) => term(),
          optional(:partition) => term(),
          optional(:metric_name) => term(),
          optional(:if_index) => term()
        }

  @spec resolve_snmp_interface_metric(snmp_metric_candidate()) :: String.t() | nil
  def resolve_snmp_interface_metric(candidate) when is_map(candidate) do
    case snmp_interface_metric_candidate(candidate) do
      nil ->
        nil

      normalized ->
        DeviceCorrelationCache.fetch(normalized, fn ->
          resolve_snmp_interface_metric_uncached(normalized)
        end)
    end
  end

  def resolve_snmp_interface_metric(_), do: nil

  @doc false
  def snmp_interface_metric_cache_key(candidate) when is_map(candidate) do
    case snmp_interface_metric_candidate(candidate) do
      nil -> nil
      normalized -> DeviceCorrelationCache.cache_key(normalized)
    end
  end

  def snmp_interface_metric_cache_key(_), do: nil

  @doc false
  @spec resolve_uncached(candidate()) :: String.t() | nil
  def resolve_uncached(candidate) when is_map(candidate) do
    actor = SystemActor.system(:event_writer_device_correlation)

    with nil <- explicit_device_uid(candidate, actor),
         nil <- device_uid_for_agent(candidate[:agent_id], actor),
         nil <- device_uid_for_workload(candidate, actor),
         nil <- device_uid_for_ip(candidate[:ip], candidate[:partition], actor),
         nil <- device_uid_for_hostname(candidate[:hostname], actor) do
      device_uid_for_hostname(candidate[:name], actor)
    end
  rescue
    error ->
      Logger.debug("Device correlation lookup failed: #{Exception.message(error)}")
      nil
  end

  defp snmp_interface_metric_candidate(candidate) do
    metric_name = candidate_value(candidate, :metric_name)
    if_index = normalize_if_index(candidate_raw_value(candidate, :if_index))

    target_device_ip =
      candidate_value(candidate, :target_device_ip) || candidate_value(candidate, :ip)

    raw_device_uid = canonical_device_uid(candidate_value(candidate, :device_uid))
    partition = candidate_value(candidate, :partition)

    has_target? = is_binary(target_device_ip) and target_device_ip != ""
    has_canonical_device? = canonical_device_uid?(raw_device_uid)

    if metric_name && if_index && (has_target? || has_canonical_device?) do
      %{
        device_uid: raw_device_uid,
        target_device_ip: target_device_ip,
        ip: target_device_ip,
        partition: partition,
        metric_name: metric_name,
        if_index: if_index
      }
    end
  end

  defp resolve_snmp_interface_metric_uncached(candidate) do
    canonical_hint = snmp_metric_canonical_hint(candidate)

    cond do
      is_binary(canonical_hint) ->
        query_snmp_metric_by_device(candidate, canonical_hint) ||
          query_snmp_metric_hourly_by_device(candidate, canonical_hint)

      is_binary(candidate.target_device_ip) ->
        query_snmp_metric_hourly_by_target(candidate)

      true ->
        nil
    end
  rescue
    error ->
      Logger.debug("SNMP metric tuple correlation lookup failed: #{Exception.message(error)}")
      nil
  end

  defp snmp_metric_canonical_hint(%{device_uid: "sr:" <> _ = uid}), do: uid

  defp snmp_metric_canonical_hint(%{target_device_ip: target_device_ip, partition: partition})
       when is_binary(target_device_ip) do
    resolve_uncached(%{
      device_uid: target_device_ip,
      ip: target_device_ip,
      partition: partition
    })
  end

  defp snmp_metric_canonical_hint(_candidate), do: nil

  defp query_snmp_metric_by_device(candidate, device_uid) do
    query_snmp_metric_device_uid(
      """
      SELECT device_id
      FROM platform.timeseries_metrics
      WHERE device_id = $1
        AND metric_name = $2
        AND if_index = $3
        AND ($4::text IS NULL OR partition = $4)
        AND timestamp >= now() - INTERVAL '48 hours'
        AND NULLIF(btrim(device_id), '') IS NOT NULL
      ORDER BY timestamp DESC
      LIMIT 1
      """,
      [device_uid, candidate.metric_name, candidate.if_index, candidate.partition]
    )
  end

  defp query_snmp_metric_hourly_by_device(candidate, device_uid) do
    query_snmp_metric_device_uid(
      """
      SELECT device_id
      FROM platform.timeseries_metrics_interface_hourly
      WHERE device_id = $1
        AND metric_name = $2
        AND if_index = $3
        AND ($4::text IS NULL OR partition = $4)
        AND NULLIF(btrim(device_id), '') IS NOT NULL
      ORDER BY bucket DESC
      LIMIT 1
      """,
      [device_uid, candidate.metric_name, candidate.if_index, candidate.partition]
    )
  end

  defp query_snmp_metric_hourly_by_target(candidate) do
    query_snmp_metric_device_uid(
      """
      SELECT device_id
      FROM platform.timeseries_metrics_interface_hourly
      WHERE target_device_ip = $1
        AND metric_name = $2
        AND if_index = $3
        AND ($4::text IS NULL OR partition = $4)
        AND NULLIF(btrim(device_id), '') IS NOT NULL
      ORDER BY bucket DESC
      LIMIT 1
      """,
      [candidate.target_device_ip, candidate.metric_name, candidate.if_index, candidate.partition]
    )
  end

  defp query_snmp_metric_device_uid(sql, params) do
    case bounded_lookup(fn -> Repo.query(sql, params) end) do
      {:ok, %{rows: [[device_uid] | _]}} -> normalize(device_uid)
      _ -> nil
    end
  end

  defp explicit_device_uid(candidate, actor) do
    case normalize(candidate[:device_uid] || candidate["device_uid"]) do
      nil ->
        nil

      # A ServiceRadar uid used to be returned verbatim here, with no lookup at
      # all. Since every canonical uid is `sr:<uuid>`, that made this -- the one
      # place whose job is re-resolving identity before a write -- a no-op in
      # production: a producer holding a pre-merge uid wrote against the dead
      # identity and nothing noticed.
      #
      # follow_canonical_device_id/2 rather than an existence check. An existence
      # check answers nil for a tombstoned device, and the correlation chain below
      # can only rescue candidates that also carry an agent id or an IP -- one
      # anchored solely on the uid would resolve to nothing. Following the merge
      # chain returns the survivor instead, which is the answer the caller wanted.
      #
      # Cheap on the common path: the follow returns its input unchanged unless
      # the row is actually tombstoned, and DeviceCorrelationCache fronts this.
      "sr:" <> _ = uid ->
        bounded_lookup(fn -> Resolver.follow_canonical_device_id(uid, actor) end) || uid

      uid ->
        case bounded_lookup(fn -> Device.get_by_uid(uid, false, actor: actor) end) do
          {:ok, %Device{uid: resolved}} -> resolved
          _ -> nil
        end
    end
  end

  defp device_uid_for_agent(nil, _actor), do: nil

  defp device_uid_for_agent(agent_id, actor) do
    agent_id = normalize(agent_id)

    if is_nil(agent_id) do
      nil
    else
      case bounded_lookup(fn -> Agent.get_by_uid(agent_id, actor: actor) end) do
        {:ok, %Agent{device_uid: uid}} when is_binary(uid) and uid != "" -> uid
        _ -> nil
      end
    end
  end

  defp device_uid_for_ip(nil, _partition, _actor), do: nil

  defp device_uid_for_ip(ip, partition, actor) do
    ip = normalize(ip)

    if is_nil(ip) do
      nil
    else
      partition = normalize(partition) || "default"

      keys =
        if is_binary(partition) and partition != "" do
          [%{kind: :partition_ip, value: "#{partition}:#{ip}"}, %{kind: :ip, value: ip}]
        else
          [%{kind: :ip, value: ip}]
        end

      case bounded_lookup(fn ->
             DeviceLookup.get_canonical_device(keys,
               actor: actor,
               ip_hint: ip,
               use_cache: false,
               include_detected: true
             )
           end) do
        {:ok, %{record: %{canonical_device_id: uid}}} when is_binary(uid) and uid != "" -> uid
        _ -> nil
      end
    end
  end

  defp device_uid_for_workload(candidate, _actor) do
    partition = candidate_value(candidate, :partition) || "default"

    workload_device_uid(candidate, partition)
  end

  defp workload_device_uid(candidate, partition) do
    cond do
      pod_uid = candidate_value(candidate, :pod_uid) ->
        query_workload_device_uid(
          """
          SELECT agent.device_uid
          FROM platform.workload_identity_current AS workload
          JOIN platform.ocsf_agents AS agent
            ON agent.uid = workload.agent_id
          WHERE workload.partition = $1
            AND workload.pod_uid = $2
            AND NULLIF(btrim(agent.device_uid), '') IS NOT NULL
          ORDER BY workload.observed_at DESC, workload.updated_at DESC
          LIMIT 1
          """,
          [partition, pod_uid]
        )

      pod_namespace = candidate_value(candidate, :pod_namespace) ->
        case candidate_value(candidate, :pod_name) do
          nil ->
            nil

          pod_name ->
            query_workload_device_uid(
              """
              SELECT agent.device_uid
              FROM platform.workload_identity_current AS workload
              JOIN platform.ocsf_agents AS agent
                ON agent.uid = workload.agent_id
              WHERE workload.partition = $1
                AND workload.pod_namespace = $2
                AND workload.pod_name = $3
                AND NULLIF(btrim(agent.device_uid), '') IS NOT NULL
              ORDER BY workload.observed_at DESC, workload.updated_at DESC
              LIMIT 1
              """,
              [partition, pod_namespace, pod_name]
            )
        end

      container_id = candidate_value(candidate, :container_id) ->
        query_workload_device_uid(
          """
          SELECT agent.device_uid
          FROM platform.workload_identity_current AS workload
          JOIN platform.ocsf_agents AS agent
            ON agent.uid = workload.agent_id
          WHERE workload.partition = $1
            AND workload.container_id = $2
            AND NULLIF(btrim(agent.device_uid), '') IS NOT NULL
          ORDER BY workload.observed_at DESC, workload.updated_at DESC
          LIMIT 1
          """,
          [partition, container_id]
        )

      true ->
        nil
    end
  end

  defp query_workload_device_uid(sql, params) do
    case bounded_lookup(fn -> Repo.query(sql, params) end) do
      {:ok, %{rows: [[device_uid] | _]}} -> normalize(device_uid)
      _ -> nil
    end
  end

  defp device_uid_for_hostname(nil, _actor), do: nil

  defp device_uid_for_hostname(hostname, actor) do
    hostname = normalize(hostname)

    cond do
      is_nil(hostname) ->
        nil

      String.starts_with?(hostname, "sr:") ->
        explicit_device_uid(%{device_uid: hostname}, actor)

      true ->
        case bounded_lookup(fn -> Device.get_by_uid(hostname, false, actor: actor) end) do
          {:ok, %Device{uid: uid}} ->
            uid

          _ ->
            lookup_device_by_hostname(hostname, actor)
        end
    end
  end

  defp lookup_device_by_hostname(hostname, actor) do
    Device
    |> Ash.Query.for_read(:read, %{include_deleted: false})
    |> Ash.Query.filter(expr(hostname == ^hostname or name == ^hostname))
    |> Ash.Query.sort(is_active: :desc, last_seen_time: :desc, modified_time: :desc, uid: :asc)
    |> Ash.Query.limit(1)
    |> then(fn query -> bounded_lookup(fn -> Ash.read(query, actor: actor) end) end)
    |> case do
      {:ok, [%Device{uid: uid} | _]} -> uid
      _ -> nil
    end
  end

  defp bounded_lookup(fun) when is_function(fun, 0) do
    task = Task.async(fun)

    case Task.yield(task, @lookup_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> nil
    end
  end

  defp normalize(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize(_), do: nil

  defp normalize_if_index(value) when is_integer(value) and value > 0, do: value

  defp normalize_if_index(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer > 0 -> integer
      _ -> nil
    end
  end

  defp normalize_if_index(_value), do: nil

  defp canonical_device_uid?("sr:" <> _), do: true
  defp canonical_device_uid?(_), do: false

  defp canonical_device_uid("sr:" <> _ = uid), do: uid
  defp canonical_device_uid(_), do: nil

  defp candidate_value(candidate, key) when is_map(candidate) do
    normalize(candidate[key] || candidate[to_string(key)])
  end

  defp candidate_raw_value(candidate, key) when is_map(candidate) do
    candidate[key] || candidate[to_string(key)]
  end
end
