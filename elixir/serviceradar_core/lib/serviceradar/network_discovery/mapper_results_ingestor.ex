defmodule ServiceRadar.NetworkDiscovery.MapperResultsIngestor do
  @moduledoc """
  Ingests mapper interface and topology results into CNPG and projects topology into AGE.
  """

  require Logger

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Interface
  alias ServiceRadar.NetworkDiscovery.{MapperJob, TopologyGraph, TopologyLink}

  @spec ingest_interfaces(binary() | nil, map()) :: :ok | {:error, term()}
  def ingest_interfaces(message, _status) do
    actor = SystemActor.system(:mapper_interface_ingestor)

    with {:ok, updates} <- decode_payload(message),
         records <- build_interface_records(updates) do
      record_job_runs(updates)

      case insert_bulk(records, Interface, actor, "interfaces") do
        :ok ->
          TopologyGraph.upsert_interfaces(records)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, reason} ->
        Logger.warning("Mapper interface ingestion failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @spec ingest_topology(binary() | nil, map()) :: :ok | {:error, term()}
  def ingest_topology(message, _status) do
    actor = SystemActor.system(:mapper_topology_ingestor)

    with {:ok, updates} <- decode_payload(message),
         records <- build_topology_records(updates) do
      record_job_runs(updates)

      case insert_bulk(records, TopologyLink, actor, "topology") do
        :ok ->
          TopologyGraph.upsert_links(records)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, reason} ->
        Logger.warning("Mapper topology ingestion failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def record_runs_from_payload(message) do
    case decode_payload(message) do
      {:ok, updates} ->
        record_job_runs(updates)

      {:error, reason} ->
        Logger.debug("Mapper job run decode failed: #{inspect(reason)}")
        :ok
    end
  end

  defp decode_payload(nil), do: {:ok, []}

  defp decode_payload(message) when is_binary(message) do
    case Jason.decode(message) do
      {:ok, updates} when is_list(updates) -> {:ok, updates}
      {:ok, _} -> {:error, :unexpected_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_payload(_message), do: {:error, :unsupported_payload}

  defp build_interface_records(updates) do
    Enum.reduce(updates, [], fn update, acc ->
      case normalize_interface(update) do
        nil -> acc
        record -> [record | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp build_topology_records(updates) do
    Enum.reduce(updates, [], fn update, acc ->
      case normalize_topology(update) do
        nil -> acc
        record -> [record | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp normalize_interface(update) when is_map(update) do
    record = %{
      timestamp: parse_timestamp(get_value(update, ["timestamp", :timestamp])),
      device_id: get_string(update, ["device_id", :device_id]),
      agent_id: get_string(update, ["agent_id", :agent_id]),
      gateway_id: get_string(update, ["gateway_id", :gateway_id]),
      device_ip: get_string(update, ["device_ip", :device_ip]),
      if_index: get_integer(update, ["if_index", :if_index]),
      if_name: get_string(update, ["if_name", :if_name]),
      if_descr: get_string(update, ["if_descr", :if_descr]),
      if_alias: get_string(update, ["if_alias", :if_alias]),
      if_speed: get_integer(update, ["if_speed", :if_speed]),
      if_phys_address: get_string(update, ["if_phys_address", :if_phys_address]),
      ip_addresses: get_list(update, ["ip_addresses", :ip_addresses]),
      if_admin_status: get_integer(update, ["if_admin_status", :if_admin_status]),
      if_oper_status: get_integer(update, ["if_oper_status", :if_oper_status]),
      metadata: get_map(update, ["metadata", :metadata]),
      created_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }

    if record.device_id && record.if_index do
      record
    else
      nil
    end
  end

  defp normalize_interface(_update), do: nil

  defp normalize_topology(update) when is_map(update) do
    %{
      timestamp: parse_timestamp(get_value(update, ["timestamp", :timestamp])),
      agent_id: get_string(update, ["agent_id", :agent_id]),
      gateway_id: get_string(update, ["gateway_id", :gateway_id]),
      partition: get_string(update, ["partition", :partition]) || "default",
      protocol: get_string(update, ["protocol", :protocol]),
      local_device_ip: get_string(update, ["local_device_ip", :local_device_ip]),
      local_device_id: get_string(update, ["local_device_id", :local_device_id]),
      local_if_index: get_integer(update, ["local_if_index", :local_if_index]),
      local_if_name: get_string(update, ["local_if_name", :local_if_name]),
      neighbor_device_id: get_string(update, ["neighbor_device_id", :neighbor_device_id]),
      neighbor_chassis_id: get_string(update, ["neighbor_chassis_id", :neighbor_chassis_id]),
      neighbor_port_id: get_string(update, ["neighbor_port_id", :neighbor_port_id]),
      neighbor_port_descr: get_string(update, ["neighbor_port_descr", :neighbor_port_descr]),
      neighbor_system_name: get_string(update, ["neighbor_system_name", :neighbor_system_name]),
      neighbor_mgmt_addr: get_string(update, ["neighbor_mgmt_addr", :neighbor_mgmt_addr]),
      metadata: get_map(update, ["metadata", :metadata]),
      created_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }
  end

  defp normalize_topology(_update), do: nil

  defp insert_bulk([], _resource, _actor, _label), do: :ok

  defp insert_bulk(records, resource, actor, label) do
    case Ash.bulk_create(records, resource, :create,
           actor: actor,
           return_errors?: true,
           stop_on_error?: false
         ) do
      %Ash.BulkResult{status: :success} ->
        :ok

      %Ash.BulkResult{status: :error, errors: errors} ->
        Logger.warning("Mapper #{label} ingestion failed: #{inspect(errors)}")
        {:error, errors}

      {:error, reason} ->
        Logger.warning("Mapper #{label} ingestion failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp record_job_runs(updates) do
    job_ids = extract_job_ids(updates)

    if job_ids == [] do
      :ok
    else
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      actor = SystemActor.system(:mapper_job_status)

      Enum.each(job_ids, &record_job_run(&1, now, actor))
    end
  rescue
    error ->
      Logger.warning("Mapper run status update failed: #{inspect(error)}")
      :ok
  end

  defp record_job_run(job_id, now, actor) do
    case Ash.get(MapperJob, job_id, actor: actor) do
      {:ok, job} ->
        job
        |> Ash.Changeset.for_update(:record_run, %{last_run_at: now})
        |> Ash.update(actor: actor)
        |> case do
          {:ok, _} -> :ok
          {:error, reason} ->
            Logger.warning("Failed to record mapper run: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.debug("Mapper job not found for run update: #{inspect(reason)}")
    end
  end

  defp extract_job_ids(updates) do
    updates
    |> Enum.reduce(MapSet.new(), fn update, acc ->
      meta = get_map(update, ["metadata", :metadata])
      case get_string(meta, ["mapper_job_id", :mapper_job_id]) do
        nil -> acc
        job_id -> MapSet.put(acc, job_id)
      end
    end)
    |> MapSet.to_list()
  end

  defp get_value(update, keys) do
    Enum.find_value(keys, fn key -> Map.get(update, key) end)
  end

  defp get_string(update, keys) do
    case get_value(update, keys) do
      value when is_binary(value) -> value
      value when is_atom(value) -> Atom.to_string(value)
      _ -> nil
    end
  end

  defp get_integer(update, keys) do
    case get_value(update, keys) do
      value when is_integer(value) -> value
      value when is_float(value) -> trunc(value)
      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, _} -> parsed
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp get_list(update, keys) do
    case get_value(update, keys) do
      value when is_list(value) -> value
      _ -> []
    end
  end

  defp get_map(update, keys) do
    case get_value(update, keys) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp parse_timestamp(nil), do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp parse_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> DateTime.truncate(dt, :microsecond)
      _ -> DateTime.utc_now() |> DateTime.truncate(:microsecond)
    end
  end

  defp parse_timestamp(%DateTime{} = timestamp) do
    DateTime.truncate(timestamp, :microsecond)
  end
end
