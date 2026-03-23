defmodule ServiceRadar.Camera.RelayPlayback do
  @moduledoc """
  Shared browser playback transport contract for relay sessions and live snapshots.
  """

  @websocket_webcodecs_h264_annexb "websocket_h264_annexb_webcodecs"
  @websocket_mse_h264_annexb "websocket_h264_annexb_jmuxer_mse"

  @transport_requirements %{
    @websocket_webcodecs_h264_annexb => ["websocket", "webcodecs", "video_decoder"],
    @websocket_mse_h264_annexb => ["websocket", "media_source", "mse_h264"]
  }

  def browser_metadata(session_or_payload) when is_map(session_or_payload) do
    codec_hint =
      explicit_string(session_or_payload, :playback_codec_hint) ||
        infer_codec_hint(session_or_payload)

    container_hint =
      explicit_string(session_or_payload, :playback_container_hint) ||
        infer_container_hint(session_or_payload)

    available_playback_transports =
      session_or_payload
      |> explicit_list(:available_playback_transports)
      |> case do
        [] -> infer_transports(codec_hint, container_hint)
        transports -> transports
      end

    preferred_playback_transport =
      explicit_string(session_or_payload, :preferred_playback_transport) ||
        List.first(available_playback_transports)

    playback_transport_requirements =
      session_or_payload
      |> explicit_requirements()
      |> case do
        %{} = requirements when map_size(requirements) > 0 ->
          requirements

        _other ->
          Map.take(@transport_requirements, available_playback_transports)
      end

    %{
      preferred_playback_transport: preferred_playback_transport,
      available_playback_transports: available_playback_transports,
      playback_codec_hint: codec_hint,
      playback_container_hint: container_hint,
      playback_transport_requirements: playback_transport_requirements
    }
  end

  def browser_metadata(_other) do
    browser_metadata(%{})
  end

  defp infer_transports("h264", "annexb"),
    do: [@websocket_webcodecs_h264_annexb, @websocket_mse_h264_annexb]

  defp infer_transports(_codec_hint, _container_hint), do: []

  defp infer_codec_hint(session_or_payload) do
    explicit_string(session_or_payload, :codec_hint) ||
      explicit_string(session_or_payload, :codec) ||
      "h264"
  end

  defp infer_container_hint(session_or_payload) do
    explicit_string(session_or_payload, :container_hint) ||
      explicit_string(session_or_payload, :payload_format) ||
      "annexb"
  end

  defp explicit_requirements(session_or_payload) do
    requirements =
      Map.get(session_or_payload, :playback_transport_requirements) ||
        Map.get(session_or_payload, "playback_transport_requirements")

    if is_map(requirements) do
      Map.new(requirements, fn {transport, values} ->
        {to_string(transport), normalize_requirements(values)}
      end)
    else
      %{}
    end
  end

  defp normalize_requirements(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_requirements(_other), do: []

  defp explicit_list(session_or_payload, key) do
    case Map.get(session_or_payload, key) || Map.get(session_or_payload, Atom.to_string(key)) do
      values when is_list(values) ->
        values
        |> Enum.map(&to_string/1)
        |> Enum.reject(&(&1 == ""))

      _other ->
        []
    end
  end

  defp explicit_string(session_or_payload, key) do
    case Map.get(session_or_payload, key) || Map.get(session_or_payload, Atom.to_string(key)) do
      nil ->
        nil

      false ->
        nil

      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: trimmed

      value when is_atom(value) ->
        value
        |> Atom.to_string()
        |> explicit_string_value()

      _other ->
        nil
    end
  end

  defp explicit_string_value(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end
end
