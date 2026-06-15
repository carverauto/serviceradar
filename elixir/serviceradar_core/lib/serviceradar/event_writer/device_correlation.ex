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

  defp explicit_device_uid(candidate, actor) do
    case normalize(candidate[:device_uid] || candidate["device_uid"]) do
      nil ->
        nil

      "sr:" <> _ = uid ->
        uid

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

  defp candidate_value(candidate, key) when is_map(candidate) do
    normalize(candidate[key] || candidate[to_string(key)])
  end
end
