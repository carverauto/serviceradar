defmodule ServiceRadarNVRClient.Wire do
  @moduledoc false
  alias ServiceRadarRecordingMetadata.CanonicalJSON
  alias ServiceRadarRecordingMetadata.Descriptor

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @max_ticks 9_223_372_036_854_775_807

  def header(
        %{
          "version" => 1,
          "storage_id" => storage,
          "recovery_generation" => generation,
          "identity" => identity,
          "clock_epoch" => epoch
        } = header
      ) do
    clock = %{
      "clock_epoch" => epoch,
      "timebase" => 90_000,
      "dts_source" => "pts_no_reordering",
      "utc_mapping" => "unknown"
    }

    with true <- map_size(header) == 5 and uuid?(storage) and uuid?(generation),
         true <- is_map(identity) and not Map.has_key?(identity, "clock"),
         true <- Descriptor.valid_identity?(Map.put(identity, "clock", clock)),
         {:ok, json} <- CanonicalJSON.encode(header),
         true <- byte_size(json) in 1..1024 do
      {:ok, <<byte_size(json)::32, json::binary>>}
    else
      _ -> {:error, :invalid_ingest_header}
    end
  end

  def header(_), do: {:error, :invalid_ingest_header}

  def unit(%{payload: bytes, sequence: sequence, pts: pts, dts: dts})
      when is_binary(bytes) and byte_size(bytes) in 1..1_048_576 and sequence in 0..18_446_744_073_709_551_615 and
             pts in 0..@max_ticks and dts in 0..@max_ticks,
      do: {:ok, <<byte_size(bytes)::32, sequence::64, pts::64, dts::64, bytes::binary>>}

  def unit(_), do: {:error, :invalid_ingest_unit}

  def receipt(bytes, %{"storage_id" => storage, "identity" => identity}) do
    with {:ok, %{"version" => 1, "status" => "sealed_local", "storage_id" => ^storage, "block_ids" => ids} = value} <-
           Jason.decode(bytes),
         true <- map_size(value) == 4 and is_list(ids) and length(ids) in 1..256,
         true <- identity["block_sequence"] + length(ids) - 1 <= @max_ticks,
         expected =
           Enum.map(0..(length(ids) - 1), fn index ->
             Descriptor.block_key(Map.put(identity, "block_sequence", identity["block_sequence"] + index))
           end),
         true <- ids == expected do
      {:ok, %{storage_id: storage, block_ids: ids, status: :sealed_local}}
    else
      _ -> {:error, :outcome_unknown}
    end
  end

  defp uuid?(value), do: is_binary(value) and Regex.match?(@uuid, value)
end
