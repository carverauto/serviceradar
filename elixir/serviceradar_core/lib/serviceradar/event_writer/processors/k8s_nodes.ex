defmodule ServiceRadar.EventWriter.Processors.K8sNodes do
  @moduledoc """
  Ingests Kubernetes Node snapshots from `serviceradar-k8s-inventory`
  (NATS subject `inventory.k8s.nodes`).

  Rows are upserted into `platform.k8s_nodes_current`. Ready-condition
  flips emit internal logs (`node.not_ready` / `node.ready`) for the
  seeded StatefulAlertRule. This processor never delivers notifications.
  """

  @behaviour ServiceRadar.EventWriter.Processor

  alias ServiceRadar.Events.InternalLogPublisher
  alias ServiceRadar.EventWriter.BulkInsert
  alias ServiceRadar.EventWriter.Processors.Logs
  alias ServiceRadar.Repo

  require Logger

  @table "k8s_nodes_current"
  @prefix "platform"

  @replace_fields [
    :cluster_id,
    :name,
    :uid,
    :role,
    :ready,
    :ready_reason,
    :ready_message,
    :unschedulable,
    :internal_ip,
    :external_ip,
    :kubelet_version,
    :os_image,
    :observed_at,
    :snapshot_at,
    :deleted_at,
    :updated_at
  ]

  @impl true
  def table_name, do: @table

  @impl true
  def process_batch(messages) when is_list(messages) do
    snapshots =
      messages
      |> Enum.map(&parse_snapshot/1)
      |> Enum.reject(&is_nil/1)

    if snapshots == [] do
      {:ok, 0}
    else
      Enum.reduce_while(snapshots, {:ok, 0}, fn snap, {:ok, acc} ->
        case apply_snapshot(snap) do
          {:ok, n} -> {:cont, {:ok, acc + n}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  rescue
    e ->
      Logger.error("k8s nodes batch failed: #{Exception.message(e)}")
      {:error, e}
  end

  @impl true
  def parse_message(message), do: parse_snapshot(message)

  @doc false
  def readiness_transitions(previous, nodes) when is_map(previous) and is_list(nodes) do
    Enum.flat_map(nodes, fn node ->
      name = node.name
      new_ready = node.ready
      prev = previous_ready(previous, name)

      cond do
        prev == true and new_ready == false -> [{:not_ready, node}]
        prev == false and new_ready == true -> [{:ready, node}]
        true -> []
      end
    end)
  end

  @doc false
  def disappeared_not_ready(previous, nodes) when is_map(previous) and is_list(nodes) do
    present = MapSet.new(Enum.map(nodes, & &1.name))

    Enum.flat_map(previous, fn {name, value} ->
      if previous_ready(previous, name) == false and not MapSet.member?(present, name) do
        [{:ready, previous_node(name, value)}]
      else
        []
      end
    end)
  end

  defp parse_snapshot(%{data: data}) do
    with {:ok, payload} <- decode_json(data),
         {:ok, cluster_id} <- required_string(payload, "cluster_id"),
         {:ok, snapshot_at} <- parse_time(payload["generated_at"]),
         nodes when is_list(nodes) <- Map.get(payload, "nodes", []) do
      %{
        cluster_id: cluster_id,
        snapshot_at: snapshot_at,
        nodes: Enum.map(nodes, &normalize_node(&1, cluster_id, snapshot_at))
      }
    else
      _ ->
        Logger.warning("k8s nodes: dropped malformed snapshot")
        nil
    end
  end

  defp parse_snapshot(_), do: nil

  defp apply_snapshot(%{cluster_id: cluster_id, snapshot_at: snapshot_at, nodes: rows}) do
    rows = Enum.reject(rows, &is_nil/1)
    keys = Enum.map(rows, & &1.node_key)

    fn ->
      if advance_snapshot?(cluster_id, snapshot_at) do
        previous = load_previous_ready(cluster_id)

        if rows != [] do
          BulkInsert.insert_all(@table, rows,
            prefix: @prefix,
            on_conflict: {:replace, @replace_fields},
            conflict_target: [:node_key]
          )
        end

        soft_delete_missing!(cluster_id, snapshot_at, keys)
        emit_transitions(previous, rows)
        length(rows)
      else
        0
      end
    end
    |> Repo.transaction()
    |> case do
      {:ok, count} ->
        :telemetry.execute(
          [:serviceradar, :event_writer, :k8s_nodes, :processed],
          %{count: count},
          %{cluster_id: cluster_id}
        )

        {:ok, count}

      {:error, reason} ->
        Logger.error("k8s nodes apply failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp advance_snapshot?(cluster_id, snapshot_at) do
    sql = """
    INSERT INTO #{@prefix}.k8s_node_snapshots AS current (cluster_id, snapshot_at)
    VALUES ($1, $2)
    ON CONFLICT (cluster_id) DO UPDATE
    SET snapshot_at = EXCLUDED.snapshot_at
    WHERE current.snapshot_at < EXCLUDED.snapshot_at
    RETURNING snapshot_at
    """

    %{num_rows: count} = Repo.query!(sql, [cluster_id, snapshot_at])
    count == 1
  end

  defp load_previous_ready(cluster_id) do
    sql = """
    SELECT name, ready, role
    FROM #{@prefix}.#{@table}
    WHERE cluster_id = $1 AND deleted_at IS NULL
    """

    %{rows: rows} = Repo.query!(sql, [cluster_id])

    Map.new(rows, fn [name, ready, role] ->
      {name, %{ready: ready, role: role, cluster_id: cluster_id}}
    end)
  end

  defp emit_transitions(previous, rows) do
    transitions = readiness_transitions(previous, rows) ++ disappeared_not_ready(previous, rows)

    Enum.each(transitions, fn {kind, node} ->
      case InternalLogPublisher.publish("k8s", transition_payload(kind, node),
             log_processor: {Logs, :process_batch, [[stateful_evaluation: :sync]]}
           ) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error("k8s node readiness event publish failed",
            node: node.name,
            kind: kind,
            reason: inspect(reason)
          )

          Repo.rollback({:readiness_publish_failed, node.name, kind, reason})
      end
    end)
  end

  defp transition_payload(kind, node) do
    event_type = event_type(kind)
    label = node.name

    %{
      "event_type" => event_type,
      "severity" => severity(kind),
      "message" => message(kind, node),
      "device_uid" => lookup_device_uid(label),
      "attributes" => %{
        "event_type" => event_type,
        "cluster_id" => node.cluster_id,
        "node" => label,
        "node.role" => node.role,
        "ready_reason" => node.ready_reason,
        "hostname" => label
      }
    }
  end

  defp event_type(:not_ready), do: "node.not_ready"
  defp event_type(:ready), do: "node.ready"
  defp severity(:not_ready), do: "critical"
  defp severity(:ready), do: "info"

  defp message(:not_ready, node) do
    "Kubernetes #{node.role} node #{node.name} is NotReady"
  end

  defp message(:ready, %{ready_reason: "NodeDeleted"} = node) do
    "Kubernetes #{node.role} node #{node.name} was removed from the cluster while NotReady"
  end

  defp message(:ready, node) do
    "Kubernetes #{node.role} node #{node.name} is Ready"
  end

  defp soft_delete_missing!(cluster_id, snapshot_at, present_keys) do
    sql = """
    UPDATE #{@prefix}.#{@table}
    SET deleted_at = $1,
        updated_at = $1
    WHERE cluster_id = $2
      AND deleted_at IS NULL
      AND (
        cardinality($3::text[]) = 0
        OR node_key <> ALL($3::text[])
      )
    """

    Repo.query!(sql, [snapshot_at, cluster_id, present_keys])
  end

  defp normalize_node(node, cluster_id, snapshot_at) when is_map(node) do
    name = blank_to_nil(node["name"])

    if is_nil(name) do
      nil
    else
      observed_at =
        case parse_time(node["observed_at"]) do
          {:ok, t} -> t
          _ -> snapshot_at
        end

      role =
        case string_or(node["role"], "worker") do
          "control-plane" -> "control-plane"
          _ -> "worker"
        end

      %{
        node_key: node_key(cluster_id, name),
        cluster_id: cluster_id,
        name: name,
        uid: blank_to_nil(node["uid"]),
        role: role,
        ready: truthy?(node["ready"]),
        ready_reason: blank_to_nil(node["ready_reason"]),
        ready_message: blank_to_nil(node["ready_message"]),
        unschedulable: truthy?(node["unschedulable"]),
        internal_ip: blank_to_nil(node["internal_ip"]),
        external_ip: blank_to_nil(node["external_ip"]),
        kubelet_version: blank_to_nil(node["kubelet_version"]),
        os_image: blank_to_nil(node["os_image"]),
        observed_at: observed_at,
        snapshot_at: snapshot_at,
        deleted_at: nil,
        inserted_at: snapshot_at,
        updated_at: snapshot_at
      }
    end
  end

  defp normalize_node(_, _, _), do: nil

  defp previous_ready(previous, name) do
    case Map.get(previous, name) do
      %{ready: ready} -> ready
      _ -> nil
    end
  end

  defp previous_node(name, %{role: role, cluster_id: cluster_id}) do
    %{name: name, role: role, cluster_id: cluster_id, ready: true, ready_reason: "NodeDeleted"}
  end

  defp lookup_device_uid(hostname) when is_binary(hostname) and hostname != "" do
    sql = """
    SELECT uid
    FROM platform.ocsf_devices
    WHERE hostname = $1 AND deleted_at IS NULL
    ORDER BY uid
    LIMIT 1
    """

    case Repo.query(sql, [hostname]) do
      {:ok, %{rows: [[uid]]}} when is_binary(uid) and uid != "" -> uid
      _ -> nil
    end
  end

  defp lookup_device_uid(_), do: nil

  defp node_key(cluster_id, name) do
    :sha256
    |> :crypto.hash(cluster_id <> "|" <> name)
    |> Base.encode16(case: :lower)
  end

  defp decode_json(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, :invalid_json}
    end
  end

  defp decode_json(data) when is_map(data), do: {:ok, data}
  defp decode_json(_), do: {:error, :invalid_json}

  defp required_string(map, key) do
    case Map.get(map, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, :missing}
    end
  end

  defp parse_time(%DateTime{} = dt), do: {:ok, DateTime.truncate(dt, :microsecond)}

  defp parse_time(v) when is_binary(v) do
    case DateTime.from_iso8601(v) do
      {:ok, dt, _} -> {:ok, DateTime.truncate(dt, :microsecond)}
      _ -> {:error, :bad_time}
    end
  end

  defp parse_time(_), do: {:error, :bad_time}

  defp string_or(v, _default) when is_binary(v), do: v
  defp string_or(_, default), do: default

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v) when is_binary(v), do: v
  defp blank_to_nil(v), do: to_string(v)

  defp truthy?(true), do: true
  defp truthy?(false), do: false
  defp truthy?("true"), do: true
  defp truthy?("false"), do: false
  defp truthy?(_), do: false
end
