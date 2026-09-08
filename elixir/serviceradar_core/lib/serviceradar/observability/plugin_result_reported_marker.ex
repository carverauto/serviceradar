defmodule ServiceRadar.Observability.PluginResultReportedMarker do
  @moduledoc false

  alias ServiceRadar.Observability.ServiceIdentity

  @marker_key "_serviceradar_plugin_result"
  @marker_version 1
  @slot_version 1
  @block_width_microseconds 257
  @allocation_block_count 16_384
  @allocation_window_microseconds @block_width_microseconds * @allocation_block_count + 255

  @doc false
  def marker_key, do: @marker_key

  @doc false
  def block_width_microseconds, do: @block_width_microseconds

  @doc false
  def allocation_window_microseconds, do: @allocation_window_microseconds

  @doc false
  def parse(row) when is_map(row) do
    details = row |> fetch(:details) |> decode_details()
    physical_timestamp = fetch(row, :timestamp)
    expected_service_id = ServiceIdentity.service_id(row)

    with %DateTime{} <- physical_timestamp,
         %{
           "kind" => "reported",
           "observation_timestamp" => observation_timestamp,
           "payload_digest" => marker_payload_digest,
           "service_id" => marker_service_id,
           "slot" => slot,
           "version" => @marker_version
         } <- Map.get(details, @marker_key),
         true <- is_binary(observation_timestamp),
         true <- is_binary(marker_payload_digest),
         true <- marker_service_id == expected_service_id,
         true <- stored_service_id_matches?(row, expected_service_id),
         payload_digest = details |> Map.delete(@marker_key) |> payload_digest(),
         true <- marker_payload_digest == payload_digest,
         {:ok, observed_at, 0} <- DateTime.from_iso8601(observation_timestamp),
         true <- valid_slot?(slot, physical_timestamp, observed_at) do
      %{
        observation_timestamp: observation_timestamp,
        observed_at: observed_at,
        payload_digest: payload_digest,
        service_id: marker_service_id
      }
    else
      _ -> nil
    end
  end

  def parse(_row), do: nil

  @doc false
  def trusted?(row), do: not is_nil(parse(row))

  @doc false
  def logical_observed_at(row) when is_map(row) do
    case parse(row) do
      %{observed_at: observed_at} -> observed_at
      nil -> fetch(row, :timestamp)
    end
  end

  @doc false
  def payload_digest_without_marker(details) do
    details
    |> decode_details()
    |> Map.delete(@marker_key)
    |> payload_digest()
  end

  @doc false
  def payload_digest(payload) do
    canonical_payload =
      case Jason.encode(payload) do
        {:ok, encoded} ->
          case Jason.decode(encoded) do
            {:ok, decoded} -> decoded
            _ -> payload
          end

        _ ->
          payload
      end

    canonical_payload
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc false
  def trusted_sql(
        details \\ "service_status.details",
        physical_timestamp \\ "service_status.timestamp",
        service_id \\ "service_status.service_id"
      ) do
    width = @block_width_microseconds
    marker = @marker_key
    observation_text = "#{details}::jsonb #>> '{#{marker},observation_timestamp}'"
    base_text = "#{details}::jsonb #>> '{#{marker},slot,base_timestamp}'"

    observed_at =
      "CASE WHEN pg_input_is_valid(#{observation_text}, 'timestamp with time zone') " <>
        "THEN (#{observation_text})::timestamptz END"

    slot_base =
      "CASE WHEN pg_input_is_valid(#{base_text}, 'timestamp with time zone') " <>
        "THEN (#{base_text})::timestamptz END"

    """
    (
      #{details} IS JSON
      AND #{service_id} IS NOT NULL
      AND #{details}::jsonb #>> '{#{marker},kind}' = 'reported'
      AND #{details}::jsonb #>> '{#{marker},version}' = '#{@marker_version}'
      AND #{details}::jsonb #>> '{#{marker},service_id}' = (#{service_id})::text
      -- PostgreSQL cannot reproduce the BEAM canonical term digest. The SQL path
      -- validates its shape after the slot and service identity prove server origin;
      -- parse/1 recomputes the digest before ingestion trusts the marker.
      AND #{details}::jsonb #>> '{#{marker},payload_digest}' ~ '^[0-9a-f]{64}$'
      AND pg_input_is_valid(#{observation_text}, 'timestamp with time zone')
      AND pg_input_is_valid(#{base_text}, 'timestamp with time zone')
      AND #{details}::jsonb #>> '{#{marker},slot,version}' = '#{@slot_version}'
      AND #{details}::jsonb #>> '{#{marker},slot,width_microseconds}' = '#{width}'
      AND (#{slot_base}) = #{physical_timestamp}
      AND mod(
        (extract(epoch FROM #{physical_timestamp}) * 1000000)::bigint,
        #{width}
      ) = 0
      AND #{physical_timestamp} <= (#{observed_at})
      AND #{physical_timestamp} >=
        (#{observed_at}) - INTERVAL '#{@allocation_window_microseconds} microseconds'
      AND #{physical_timestamp} + INTERVAL '#{width - 1} microseconds' <= (#{observed_at})
    )
    """
  end

  defp valid_slot?(
         %{
           "base_timestamp" => base_timestamp,
           "version" => @slot_version,
           "width_microseconds" => @block_width_microseconds
         },
         physical_timestamp,
         observed_at
       )
       when is_binary(base_timestamp) do
    with {:ok, slot_base, 0} <- DateTime.from_iso8601(base_timestamp),
         :eq <- DateTime.compare(slot_base, physical_timestamp),
         0 <- rem(DateTime.to_unix(physical_timestamp, :microsecond), @block_width_microseconds),
         true <- within_allocation_window?(physical_timestamp, observed_at),
         comparison =
           physical_timestamp
           |> DateTime.add(@block_width_microseconds - 1, :microsecond)
           |> DateTime.compare(observed_at),
         true <- comparison in [:lt, :eq] do
      true
    else
      _ -> false
    end
  end

  defp valid_slot?(_slot, _physical_timestamp, _observed_at), do: false

  defp within_allocation_window?(physical_timestamp, observed_at) do
    offset = DateTime.diff(physical_timestamp, observed_at, :microsecond)
    offset >= -@allocation_window_microseconds and offset <= 0
  end

  defp stored_service_id_matches?(row, expected_service_id) do
    case fetch_present(row, :service_id) do
      :missing -> true
      {:present, nil} -> false
      {:present, service_id} -> to_string(service_id) == expected_service_id
    end
  end

  defp decode_details(details) when is_map(details), do: details

  defp decode_details(details) when is_binary(details) do
    case Jason.decode(details) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_details(_details), do: %{}

  defp fetch(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp fetch_present(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        {:present, value}

      :error ->
        case Map.fetch(map, Atom.to_string(key)) do
          {:ok, value} -> {:present, value}
          :error -> :missing
        end
    end
  end
end
