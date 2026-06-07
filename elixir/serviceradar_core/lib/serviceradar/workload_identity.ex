defmodule ServiceRadar.WorkloadIdentity do
  @moduledoc """
  Coalesces node-local workload identity snapshots forwarded by agents.

  The collector runs as its own native add-on and writes bounded JSON snapshots
  locally. The Go agent forwards those snapshots through agent-gateway; this
  module performs the upstream decode and current-state upsert so netprobe is not
  required to carry workload metadata.
  """

  alias ServiceRadar.FlowAttribution
  alias ServiceRadar.Repo

  require Logger

  @table "workload_identity_current"
  @max_identities_per_snapshot 50_000

  @spec persist_snapshot(map()) :: :ok | {:error, term()}
  def persist_snapshot(%{message: message} = status) when is_binary(message) do
    with {:ok, snapshot} <- Jason.decode(message),
         {:ok, rows} <- rows_from_snapshot(snapshot, status) do
      insert_rows(rows)
    else
      {:error, reason} = error ->
        Logger.warning("WorkloadIdentity.persist_snapshot failed: #{inspect(reason)}")
        error
    end
  end

  def persist_snapshot(_status), do: {:error, :missing_workload_identity_message}

  defp rows_from_snapshot(snapshot, status) when is_map(snapshot) do
    identities = Map.get(snapshot, "identities", [])

    cond do
      not is_list(identities) ->
        {:error, :invalid_workload_identity_identities}

      length(identities) > @max_identities_per_snapshot ->
        {:error, :workload_identity_snapshot_too_large}

      true ->
        observed_at = observed_at(snapshot)
        partition = normalize_string(status[:partition]) || "default"
        agent_id = normalize_string(status[:agent_id])
        gateway_id = normalize_string(status[:gateway_id])
        snapshot_degradation = normalize_string(Map.get(snapshot, "degradation_reason"))
        snapshot_endpoint = Map.get(snapshot, "endpoint")
        snapshot_cluster = cluster_identity_from_snapshot(snapshot)

        rows =
          identities
          |> Enum.map(
            &row_from_lookup(
              &1,
              observed_at,
              partition,
              agent_id,
              gateway_id,
              snapshot_endpoint,
              snapshot_degradation,
              snapshot_cluster
            )
          )
          |> Enum.reject(&is_nil/1)

        {:ok, rows}
    end
  end

  defp rows_from_snapshot(_snapshot, _status), do: {:error, :invalid_workload_identity_snapshot}

  defp row_from_lookup(
         lookup,
         observed_at,
         partition,
         agent_id,
         gateway_id,
         snapshot_endpoint,
         snapshot_degradation,
         snapshot_cluster
       )
       when is_map(lookup) do
    identity = Map.get(lookup, "identity")
    identity_container_id = if is_map(identity), do: Map.get(identity, "container_id")

    container_id =
      normalize_string(Map.get(lookup, "container_id")) || normalize_string(identity_container_id)

    if container_id in [nil, ""] or not is_map(identity) do
      nil
    else
      identity =
        identity
        |> Map.put_new("container_id", container_id)
        |> Map.put_new("snapshot_endpoint", snapshot_endpoint)
        |> Map.put_new("snapshot_degradation_reason", snapshot_degradation)
        |> put_snapshot_cluster_identity(snapshot_cluster)

      %{
        observed_at: observed_at,
        partition: partition,
        agent_id: agent_id,
        gateway_id: gateway_id,
        container_id: container_id,
        pod_uid: normalize_string(Map.get(identity, "pod_uid")),
        pod_namespace: normalize_string(Map.get(identity, "pod_namespace")),
        pod_name: normalize_string(Map.get(identity, "pod_name")),
        container_name: normalize_string(Map.get(identity, "container_name")),
        image:
          normalize_string(Map.get(identity, "image")) ||
            normalize_string(Map.get(identity, "image_ref")),
        runtime_source: runtime_source(identity),
        confidence: normalize_string(Map.get(identity, "confidence")),
        degradation_reason:
          normalize_string(Map.get(identity, "degradation_reason")) || snapshot_degradation,
        identity: identity
      }
    end
  end

  defp row_from_lookup(
         _lookup,
         _observed_at,
         _partition,
         _agent_id,
         _gateway_id,
         _endpoint,
         _degradation,
         _snapshot_cluster
       ),
       do: nil

  defp insert_rows([]), do: :ok

  defp insert_rows(rows) do
    now = DateTime.utc_now()

    rows =
      rows
      |> Enum.map(&Map.merge(&1, %{inserted_at: now, updated_at: now}))
      |> Jason.encode!()

    sql = """
    INSERT INTO platform.#{@table} (
      observed_at,
      inserted_at,
      updated_at,
      partition,
      agent_id,
      gateway_id,
      container_id,
      pod_uid,
      pod_namespace,
      pod_name,
      container_name,
      image,
      runtime_source,
      confidence,
      degradation_reason,
      identity
    )
    SELECT
      r.observed_at,
      r.inserted_at,
      r.updated_at,
      r.partition,
      r.agent_id,
      r.gateway_id,
      r.container_id,
      r.pod_uid,
      r.pod_namespace,
      r.pod_name,
      r.container_name,
      r.image,
      r.runtime_source,
      r.confidence,
      r.degradation_reason,
      r.identity
    FROM jsonb_to_recordset(($1::text)::jsonb) AS r(
      observed_at timestamptz,
      inserted_at timestamptz,
      updated_at timestamptz,
      partition text,
      agent_id text,
      gateway_id text,
      container_id text,
      pod_uid text,
      pod_namespace text,
      pod_name text,
      container_name text,
      image text,
      runtime_source text,
      confidence text,
      degradation_reason text,
      identity jsonb
    )
    ON CONFLICT (partition, agent_id, container_id)
    DO UPDATE SET
      observed_at = EXCLUDED.observed_at,
      updated_at = EXCLUDED.updated_at,
      gateway_id = EXCLUDED.gateway_id,
      pod_uid = EXCLUDED.pod_uid,
      pod_namespace = EXCLUDED.pod_namespace,
      pod_name = EXCLUDED.pod_name,
      container_name = EXCLUDED.container_name,
      image = EXCLUDED.image,
      runtime_source = EXCLUDED.runtime_source,
      confidence = EXCLUDED.confidence,
      degradation_reason = EXCLUDED.degradation_reason,
      identity = EXCLUDED.identity
    """

    case Repo.query(sql, [rows]) do
      {:ok, _result} ->
        backfill_flow_attribution(rows)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp backfill_flow_attribution(encoded_rows) do
    with {:ok, rows} <- Jason.decode(encoded_rows),
         {:ok, _count} <- FlowAttribution.backfill_current_workload_identity(rows) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("WorkloadIdentity flow attribution backfill failed: #{inspect(reason)}")
        :ok
    end
  end

  defp observed_at(snapshot) do
    case Map.get(snapshot, "observed_at_unix_nano") do
      value when is_integer(value) and value > 0 ->
        value
        |> System.convert_time_unit(:nanosecond, :microsecond)
        |> DateTime.from_unix!(:microsecond)

      value when is_binary(value) ->
        case Integer.parse(value) do
          {int, ""} when int > 0 ->
            int
            |> System.convert_time_unit(:nanosecond, :microsecond)
            |> DateTime.from_unix!(:microsecond)

          _ ->
            DateTime.utc_now()
        end

      _ ->
        DateTime.utc_now()
    end
  end

  defp runtime_source(%{"runtime_source" => value}) when is_binary(value), do: value

  defp runtime_source(%{"runtime_source" => value}) when is_map(value) do
    value
    |> Map.values()
    |> List.first()
    |> normalize_string()
  end

  defp runtime_source(_identity), do: nil

  defp cluster_identity_from_snapshot(snapshot) do
    %{
      "cluster_id" => normalize_string(Map.get(snapshot, "cluster_id")),
      "cluster_name" => normalize_string(Map.get(snapshot, "cluster_name"))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp put_snapshot_cluster_identity(identity, cluster) when map_size(cluster) == 0 do
    identity
  end

  defp put_snapshot_cluster_identity(identity, cluster) do
    Enum.reduce(cluster, identity, fn {key, value}, acc ->
      Map.put_new(acc, key, value)
    end)
  end

  defp normalize_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_string(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_string()

  defp normalize_string(_value), do: nil
end
