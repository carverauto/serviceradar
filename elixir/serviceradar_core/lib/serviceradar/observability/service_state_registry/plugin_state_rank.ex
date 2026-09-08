defmodule ServiceRadar.Observability.ServiceStateRegistry.PluginStateRank do
  @moduledoc false

  alias ServiceRadar.Observability.PluginResultReportedMarker
  alias ServiceRadar.Observability.ServiceState

  @pending_message "plugin assignment pending result"
  @streaming_ready_message "streaming plugin ready"

  @doc false
  def state_rank(%ServiceState{} = state) do
    snapshot_rank(%{
      agent_id: state.agent_id,
      gateway_id: state.gateway_id,
      partition: state.partition,
      service_type: state.service_type,
      service_name: state.service_name,
      message: state.message,
      details: state.details,
      timestamp: state.last_observed_at,
      available: state.available
    })
  end

  @doc false
  def snapshot_rank(snapshot) when is_map(snapshot) do
    details = snapshot |> fetch(:details) |> decode_details()

    {
      snapshot |> fetch(:message) |> real_result_rank(),
      snapshot |> logical_observed_at(details, fetch(snapshot, :timestamp)) |> timestamp_rank(),
      snapshot |> fetch(:available) |> unavailable_rank(),
      fetch(snapshot, :gateway_id) || "",
      payload_order_key(snapshot, details, fetch(snapshot, :message))
    }
  end

  @doc false
  def compare_snapshots(left, right) when is_map(left) and is_map(right) do
    left_details = left |> fetch(:details) |> decode_details()
    right_details = right |> fetch(:details) |> decode_details()

    {left_rank, right_rank} =
      if same_payload_lineage?(left, left_details, right, right_details) do
        {history_payload_rank(left, left_details), history_payload_rank(right, right_details)}
      else
        {snapshot_rank(left), snapshot_rank(right)}
      end

    compare(left_rank, right_rank)
  end

  @doc false
  def same_logical_observation?(left, right) when is_map(left) and is_map(right) do
    left_details = left |> fetch(:details) |> decode_details()
    right_details = right |> fetch(:details) |> decode_details()

    logical_observed_at(left, left_details, fetch(left, :timestamp)) ==
      logical_observed_at(right, right_details, fetch(right, :timestamp))
  end

  def same_logical_observation?(_left, _right), do: false

  @doc false
  def placeholder_state?(%ServiceState{} = state), do: placeholder_message?(state.message)

  @doc false
  def snapshot_payload_digest(snapshot) when is_map(snapshot) do
    details = snapshot |> fetch(:details) |> decode_details()
    payload_digest(snapshot, details)
  end

  @doc false
  def details_payload_digest(details), do: snapshot_payload_digest(%{details: details})

  @doc false
  def snapshot_logical_observed_at(snapshot) when is_map(snapshot) do
    details = snapshot |> fetch(:details) |> decode_details()
    logical_observed_at(snapshot, details, fetch(snapshot, :timestamp))
  end

  @doc false
  def details_logical_observed_at(details, fallback) do
    snapshot_logical_observed_at(%{details: details, timestamp: fallback})
  end

  defp compare(left, right) when left > right, do: :gt
  defp compare(left, right) when left < right, do: :lt
  defp compare(_left, _right), do: :eq

  defp same_payload_lineage?(left, left_details, right, right_details) do
    left_digest = payload_digest(left, left_details)

    left_digest != "" and left_digest == payload_digest(right, right_details) and
      fetch(left, :gateway_id) == fetch(right, :gateway_id) and
      logical_observed_at(left, left_details, fetch(left, :timestamp)) ==
        logical_observed_at(right, right_details, fetch(right, :timestamp))
  end

  defp history_payload_rank(snapshot, details) do
    record_kind_rank = history_record_kind_rank(snapshot, details)

    {
      record_kind_rank,
      history_handler_generation(details),
      if(record_kind_rank < 2 and fetch(snapshot, :available) == false, do: 1, else: 0),
      timestamp_rank(fetch(snapshot, :timestamp))
    }
  end

  defp history_record_kind_rank(snapshot, details) do
    cond do
      server_reported_details?(snapshot) -> 1
      server_downstream_details?(details) -> 2
      true -> 0
    end
  end

  defp history_handler_generation(details) do
    if server_downstream_details?(details) do
      get_in(details, ["downstream_ingest", "generation"])
    else
      0
    end
  end

  defp logical_observed_at(snapshot, details, fallback) do
    value =
      cond do
        server_reported_details?(snapshot) ->
          snapshot
          |> PluginResultReportedMarker.parse()
          |> Map.fetch!(:observation_timestamp)

        server_downstream_details?(details) ->
          get_in(details, ["downstream_ingest", "observation_timestamp"])

        true ->
          nil
      end

    parse_datetime(value, fallback)
  end

  defp payload_digest(snapshot, details) do
    cond do
      server_reported_details?(snapshot) ->
        snapshot
        |> PluginResultReportedMarker.parse()
        |> Map.fetch!(:payload_digest)

      server_downstream_details?(details) ->
        explicit_or_legacy_digest(
          get_in(details, ["downstream_ingest", "payload_digest"]),
          Map.get(details, "reported_result")
        )

      true ->
        ""
    end
  end

  defp payload_order_key(snapshot, details, message) do
    case explicit_payload_digest(snapshot, details) do
      digest when is_binary(digest) and digest != "" -> "1:" <> digest
      _ -> "0:" <> normalize_order_message(message)
    end
  end

  defp explicit_payload_digest(snapshot, details) do
    cond do
      server_reported_details?(snapshot) ->
        snapshot
        |> PluginResultReportedMarker.parse()
        |> Map.fetch!(:payload_digest)

      server_downstream_details?(details) ->
        get_in(details, ["downstream_ingest", "payload_digest"])

      true ->
        nil
    end
  end

  defp normalize_order_message(message) when is_binary(message), do: message
  defp normalize_order_message(_message), do: ""

  defp explicit_or_legacy_digest(digest, _payload) when is_binary(digest) and digest != "",
    do: digest

  defp explicit_or_legacy_digest(_digest, payload) when is_map(payload) or is_list(payload) do
    payload
    |> canonical_json_term()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp explicit_or_legacy_digest(_digest, _payload), do: ""

  defp canonical_json_term(payload) do
    with {:ok, encoded} <- Jason.encode(payload),
         {:ok, decoded} <- Jason.decode(encoded) do
      decoded
    else
      _ -> payload
    end
  end

  defp server_reported_details?(snapshot), do: PluginResultReportedMarker.trusted?(snapshot)

  defp server_downstream_details?(details) do
    match?(
      %{
        "status" => status,
        "generation" => generation,
        "handler_set" => %{"id" => id, "version" => 1},
        "observation_timestamp" => timestamp
      }
      when status in ["failed", "succeeded"] and generation in 1..128 and is_binary(id) and
             id != "" and is_binary(timestamp),
      Map.get(details, "downstream_ingest")
    ) and Map.has_key?(details, "reported_result")
  end

  defp parse_datetime(nil, fallback), do: fallback

  defp parse_datetime(value, fallback) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> timestamp
      _ -> fallback
    end
  end

  defp timestamp_rank(%DateTime{} = timestamp), do: DateTime.to_unix(timestamp, :nanosecond)

  defp timestamp_rank(%NaiveDateTime{} = timestamp) do
    timestamp
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix(:nanosecond)
  end

  defp timestamp_rank(_timestamp), do: 0

  defp decode_details(details) when is_map(details), do: details

  defp decode_details(details) when is_binary(details) do
    case Jason.decode(details) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_details(_details), do: %{}

  defp placeholder_message?(@pending_message), do: true
  defp placeholder_message?(@streaming_ready_message), do: true
  defp placeholder_message?(_message), do: false

  defp real_result_rank(message), do: if(placeholder_message?(message), do: 0, else: 1)
  defp unavailable_rank(false), do: 1
  defp unavailable_rank(_available), do: 0

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
