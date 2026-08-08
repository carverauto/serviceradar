defmodule ServiceRadar.EventWriter.Processors.K8sPublicEndpoints do
  @moduledoc """
  Ingests full-cluster public endpoint inventory snapshots from
  `serviceradar-k8s-inventory` (NATS subject `inventory.k8s.public_endpoints`).

  Each message is a JSON snapshot:

      {
        "cluster_id": "demo",
        "generated_at": "...",
        "endpoints": [ ... ],
        "correlation_hints": [ ... ]
      }

  Rows are upserted into `platform.public_endpoints_current`. Endpoints for the
  same cluster that are absent from the snapshot are soft-deleted
  (`deleted_at` set) so reassigned MetalLB IPs do not linger.
  """

  @behaviour ServiceRadar.EventWriter.Processor

  alias ServiceRadar.EventWriter.BulkInsert
  alias ServiceRadar.Repo

  require Logger

  @table "public_endpoints_current"
  @prefix "platform"

  @replace_fields [
    :cluster_id,
    :ip,
    :hostname,
    :port,
    :protocol,
    :exposure_class,
    :external_traffic_policy,
    :metallb_pool,
    :load_balancer_ip_mode,
    :namespace,
    :service_name,
    :service_uid,
    :gateway_name,
    :gateway_class,
    :listener_name,
    :route_kind,
    :route_name,
    :service_target_port,
    :service_target_name,
    :backend_refs,
    :endpoint_targets,
    :annotations,
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
      # Process each snapshot independently (batch_size is usually 1).
      total =
        Enum.reduce(snapshots, 0, fn snap, acc ->
          case apply_snapshot(snap) do
            {:ok, n} -> acc + n
            {:error, _} -> acc
          end
        end)

      {:ok, total}
    end
  rescue
    e ->
      Logger.error("k8s public endpoints batch failed: #{Exception.message(e)}")
      {:error, e}
  end

  @impl true
  def parse_message(message), do: parse_snapshot(message)

  defp parse_snapshot(%{data: data}) do
    with {:ok, payload} <- decode_json(data),
         {:ok, cluster_id} <- required_string(payload, "cluster_id"),
         {:ok, snapshot_at} <- parse_time(payload["generated_at"] || payload["snapshot_at"]),
         endpoints when is_list(endpoints) <- Map.get(payload, "endpoints", []) do
      %{
        cluster_id: cluster_id,
        snapshot_at: snapshot_at,
        endpoints: Enum.map(endpoints, &normalize_endpoint(&1, cluster_id, snapshot_at))
      }
    else
      _ ->
        Logger.warning("k8s public endpoints: dropped malformed snapshot")
        nil
    end
  end

  defp parse_snapshot(_), do: nil

  defp apply_snapshot(%{cluster_id: cluster_id, snapshot_at: snapshot_at, endpoints: rows}) do
    rows = Enum.reject(rows, &is_nil/1)
    keys = Enum.map(rows, & &1.endpoint_key)

    fn ->
      if rows != [] do
        BulkInsert.insert_all(@table, rows,
          prefix: @prefix,
          on_conflict: {:replace, @replace_fields},
          conflict_target: [:endpoint_key]
        )
      end

      soft_delete_missing!(cluster_id, snapshot_at, keys)
      length(rows)
    end
    |> Repo.transaction()
    |> case do
      {:ok, count} ->
        :telemetry.execute(
          [:serviceradar, :event_writer, :k8s_public_endpoints, :processed],
          %{count: count},
          %{cluster_id: cluster_id}
        )

        {:ok, count}

      {:error, reason} ->
        Logger.error("k8s public endpoints apply failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp soft_delete_missing!(cluster_id, snapshot_at, present_keys) do
    # Soft-delete active rows for this cluster not present in the latest snapshot.
    sql = """
    UPDATE #{@prefix}.#{@table}
    SET deleted_at = $1,
        updated_at = $1
    WHERE cluster_id = $2
      AND deleted_at IS NULL
      AND (
        cardinality($3::text[]) = 0
        OR endpoint_key <> ALL($3::text[])
      )
    """

    Repo.query!(sql, [snapshot_at, cluster_id, present_keys])
  end

  defp normalize_endpoint(ep, default_cluster, snapshot_at) when is_map(ep) do
    cluster_id = string_or(ep["cluster_id"], default_cluster)
    ip = blank_to_nil(ep["ip"])
    hostname = blank_to_nil(ep["hostname"])
    port = to_int(ep["port"], 0)
    protocol = ep["protocol"] |> string_or("TCP") |> String.upcase()
    exposure = string_or(ep["exposure_class"], "LoadBalancer")
    namespace = string_or(ep["namespace"], "")
    service_name = string_or(ep["service_name"], "")
    gateway_name = string_or(ep["gateway_name"], "")
    listener_name = string_or(ep["listener_name"], "")
    route_kind = string_or(ep["route_kind"], "")
    route_name = string_or(ep["route_name"], "")

    observed_at =
      case parse_time(ep["observed_at"]) do
        {:ok, t} -> t
        _ -> snapshot_at
      end

    endpoint_key =
      build_endpoint_key(
        cluster_id,
        ip,
        hostname,
        port,
        protocol,
        exposure,
        namespace,
        service_name,
        gateway_name,
        listener_name,
        route_kind,
        route_name
      )

    %{
      endpoint_key: endpoint_key,
      cluster_id: cluster_id,
      ip: ip,
      hostname: hostname,
      port: port,
      protocol: protocol,
      exposure_class: exposure,
      external_traffic_policy: blank_to_nil(ep["external_traffic_policy"]),
      metallb_pool: blank_to_nil(ep["metallb_pool"]),
      load_balancer_ip_mode: blank_to_nil(ep["load_balancer_ip_mode"]),
      namespace: namespace,
      service_name: service_name,
      service_uid: blank_to_nil(ep["service_uid"]),
      gateway_name: gateway_name,
      gateway_class: blank_to_nil(ep["gateway_class"]),
      listener_name: listener_name,
      route_kind: route_kind,
      route_name: route_name,
      service_target_port: to_int_or_nil(ep["service_target_port"]),
      service_target_name: blank_to_nil(ep["service_target_name"]),
      backend_refs: ep["backend_refs"] || [],
      endpoint_targets: ep["endpoint_targets"] || [],
      annotations: ep["annotations"] || %{},
      observed_at: observed_at,
      snapshot_at: snapshot_at,
      deleted_at: nil,
      inserted_at: snapshot_at,
      updated_at: snapshot_at
    }
  end

  defp normalize_endpoint(_, _, _), do: nil

  defp build_endpoint_key(
         cluster_id,
         ip,
         hostname,
         port,
         protocol,
         exposure,
         namespace,
         service_name,
         gateway_name,
         listener_name,
         route_kind,
         route_name
       ) do
    [
      cluster_id,
      ip || "",
      hostname || "",
      Integer.to_string(port),
      protocol,
      exposure,
      namespace,
      service_name,
      gateway_name,
      listener_name,
      route_kind,
      route_name
    ]
    |> Enum.join("|")
    |> then(&:crypto.hash(:sha256, &1))
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

  defp parse_time(%DateTime{} = dt), do: {:ok, DateTime.truncate(dt, :second)}

  defp parse_time(v) when is_binary(v) do
    case DateTime.from_iso8601(v) do
      {:ok, dt, _} -> {:ok, DateTime.truncate(dt, :second)}
      _ -> {:error, :bad_time}
    end
  end

  defp parse_time(_), do: {:ok, DateTime.truncate(DateTime.utc_now(), :second)}

  defp string_or(v, _default) when is_binary(v), do: v
  defp string_or(_, default), do: default

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v) when is_binary(v), do: v
  defp blank_to_nil(v), do: to_string(v)

  defp to_int(v, _default) when is_integer(v), do: v
  defp to_int(v, _default) when is_float(v), do: trunc(v)

  defp to_int(v, default) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> default
    end
  end

  defp to_int(_, default), do: default

  defp to_int_or_nil(nil), do: nil
  defp to_int_or_nil(0), do: nil
  defp to_int_or_nil(v), do: to_int(v, nil)
end
