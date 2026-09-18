defmodule ServiceRadar.Analytics.StarRocks.Identity do
  @moduledoc """
  Stable StarRocks record identities for EventWriter rows.

  Identity is derived from observation fields, not delivery attempt or batch
  boundaries. A flow five-tuple alone is not an identity: distinct observations
  of the same conversation are distinct records.
  """

  @type dataset :: :flows | :flow_attribution | :metrics | :logs | :events

  @spec record_id(dataset(), map()) :: String.t()
  def record_id(_dataset, row) when is_map(row) do
    case field(row, :id) do
      id when is_integer(id) ->
        Integer.to_string(id)

      id when is_binary(id) and byte_size(id) == 16 ->
        # EventWriter log/event rows store raw UUID bytes for CNPG. Those are
        # not valid UTF-8; Jason.encode! of that id crashes Stream Load and
        # the batch never reaches StarRocks.
        case Ecto.UUID.load(id) do
          {:ok, uuid} -> uuid
          :error -> hash_observation(row)
        end

      id when is_binary(id) and id != "" ->
        if String.valid?(id), do: id, else: hash_observation(row)

      _ ->
        hash_observation(row)
    end
  end

  @spec metric_identity(map()) :: {term(), term(), term()}
  def metric_identity(row) when is_map(row) do
    {field(row, :timestamp), field(row, :gateway_id), field(row, :series_key)}
  end

  defp hash_observation(row) do
    parts =
      Enum.map_join(
        [
          field(row, :time) || field(row, :timestamp) || field(row, :event_timestamp),
          payload_field(row, "observed_timestamp", :observed_timestamp),
          field(row, :src_endpoint_ip),
          field(row, :src_endpoint_port),
          field(row, :dst_endpoint_ip),
          field(row, :dst_endpoint_port),
          field(row, :protocol_num),
          field(row, :sampler_address),
          field(row, :bytes_total) || field(row, :bytes_in),
          field(row, :packets_total) || field(row, :packets_in),
          field(row, :bytes_out),
          field(row, :packets_out),
          field(row, :start_time),
          field(row, :end_time),
          field(row, :device_uid) || field(row, :device_id),
          field(row, :partition),
          field(row, :tcp_flags),
          connection_info(row, "input_snmp", :input_snmp),
          connection_info(row, "output_snmp", :output_snmp),
          field(row, :src_as_number),
          field(row, :dst_as_number),
          field(row, :gateway_id),
          field(row, :series_key),
          field(row, :ingest_identity)
        ],
        "|",
        &to_string/1
      )

    digest =
      :sha256
      |> :crypto.hash(parts)
      |> Base.encode16(case: :lower)
      |> String.slice(0, 32)

    "obs-" <> digest
  end

  defp connection_info(row, string_key, atom_key) do
    case payload_field(row, "connection_info", :connection_info) do
      %{} = info -> Map.get(info, string_key) || Map.get(info, atom_key)
      _ -> nil
    end
  end

  defp payload_field(row, string_key, atom_key) do
    case field(row, :ocsf_payload) do
      %{} = payload -> Map.get(payload, string_key) || Map.get(payload, atom_key)
      _ -> nil
    end
  end

  defp field(row, key) when is_atom(key) do
    Map.get(row, key) || Map.get(row, Atom.to_string(key))
  end
end
