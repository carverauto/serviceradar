defmodule ServiceRadarWebNGWeb.Channels.CameraRelayStreamHandler do
  @moduledoc """
  Browser-facing websocket that streams camera relay session state snapshots.

  This is the session-backed browser contract for camera viewers until the
  Membrane media fan-out path is attached to the same relay session.
  """

  @behaviour WebSock

  alias ServiceRadar.Camera.RelayPlayback
  alias ServiceRadar.Camera.RelayPubSub
  alias ServiceRadar.Camera.RelaySession
  alias ServiceRadarWebNG.CameraRelayWebRTC

  require Logger

  @default_poll_interval_ms 1_000
  @media_frame_magic "SRCM"
  @media_frame_version 1
  @media_frame_keyframe_flag 0x01

  @impl true
  def init(options) do
    relay_session_id = Keyword.fetch!(options, :relay_session_id)
    scope = Keyword.fetch!(options, :scope)
    viewer_id = Keyword.get_lazy(options, :viewer_id, &Ecto.UUID.generate/0)

    state = %{
      relay_session_id: relay_session_id,
      viewer_id: viewer_id,
      scope: scope,
      last_snapshot: nil,
      fetcher:
        Keyword.get(
          options,
          :fetcher,
          fn session_id, ash_opts -> RelaySession.get_by_id(session_id, ash_opts) end
        ),
      poll_interval_ms:
        Keyword.get(
          options,
          :poll_interval_ms,
          Application.get_env(
            :serviceradar_web_ng,
            :camera_relay_browser_stream_poll_interval_ms,
            @default_poll_interval_ms
          )
        )
    }

    case current_snapshot(state) do
      {:ok, snapshot} ->
        :ok = subscribe(relay_session_id)
        :ok = subscribe_viewer(relay_session_id, viewer_id)
        :ok = RelayPubSub.viewer_join(relay_session_id, viewer_id)
        schedule_poll(state.poll_interval_ms)
        {:push, {:text, Jason.encode!(snapshot)}, %{state | last_snapshot: snapshot}}

      {:error, :not_found} ->
        {:stop, :normal, {1008, "relay session not found"}, state}

      {:error, reason} ->
        Logger.warning("Camera relay websocket init failed",
          relay_session_id: relay_session_id,
          reason: inspect(reason)
        )

        {:stop, :normal, {1011, "failed to load relay session"}, state}
    end
  end

  @impl true
  def handle_in({_data, [opcode: :binary]}, state), do: {:ok, state}

  def handle_in({data, [opcode: :text]}, state) do
    case String.trim(data) do
      "ping" ->
        {:push, {:text, Jason.encode!(%{type: "camera_relay_pong", relay_session_id: state.relay_session_id})}, state}

      _other ->
        {:ok, state}
    end
  end

  @impl true
  def handle_info(:poll, state) do
    case current_snapshot(state) do
      {:ok, snapshot} ->
        snapshot = prefer_snapshot(state.last_snapshot, snapshot)
        schedule_poll(state.poll_interval_ms)

        cond do
          snapshot == state.last_snapshot ->
            {:ok, state}

          terminal_snapshot?(snapshot) ->
            {:stop, :normal, 1000, [{:text, Jason.encode!(snapshot)}], %{state | last_snapshot: snapshot}}

          true ->
            {:push, {:text, Jason.encode!(snapshot)}, %{state | last_snapshot: snapshot}}
        end

      {:error, :not_found} ->
        {:stop, :normal, {1008, "relay session not found"}, state}

      {:error, reason} ->
        Logger.warning("Camera relay websocket refresh failed",
          relay_session_id: state.relay_session_id,
          reason: inspect(reason)
        )

        {:stop, :normal, {1011, "failed to refresh relay session"}, state}
    end
  end

  def handle_info({:camera_relay_state, payload}, state) when is_map(payload) do
    snapshot =
      payload
      |> normalize_snapshot(state)
      |> prefer_snapshot(state.last_snapshot)

    cond do
      is_nil(snapshot) ->
        {:ok, state}

      snapshot == state.last_snapshot ->
        {:ok, state}

      terminal_snapshot?(snapshot) ->
        {:stop, :normal, 1000, [{:text, Jason.encode!(snapshot)}], %{state | last_snapshot: snapshot}}

      true ->
        {:push, {:text, Jason.encode!(snapshot)}, %{state | last_snapshot: snapshot}}
    end
  end

  def handle_info({:camera_relay_chunk, payload}, state) when is_map(payload) do
    cond do
      Map.get(payload, :relay_session_id) != state.relay_session_id ->
        {:ok, state}

      Map.get(payload, :payload) in [nil, <<>>] ->
        {:ok, state}

      true ->
        {:push, {:binary, encode_media_frame(payload)}, state}
    end
  end

  def handle_info({:camera_relay_viewer_chunk, payload}, state) when is_map(payload) do
    cond do
      Map.get(payload, :relay_session_id) != state.relay_session_id ->
        {:ok, state}

      Map.get(payload, :viewer_id) != state.viewer_id ->
        {:ok, state}

      Map.get(payload, :payload) in [nil, <<>>] ->
        {:ok, state}

      true ->
        {:push, {:binary, encode_media_frame(payload)}, state}
    end
  end

  @impl true
  def terminate(reason, state) do
    :ok = RelayPubSub.viewer_leave(state.relay_session_id, state.viewer_id)

    Logger.info("Camera relay websocket closed",
      relay_session_id: state.relay_session_id,
      viewer_id: state.viewer_id,
      reason: inspect(reason)
    )

    :ok
  end

  defp current_snapshot(state) do
    case state.fetcher.(state.relay_session_id, scope: state.scope) do
      {:ok, nil} ->
        {:error, :not_found}

      {:ok, session} ->
        {:ok, snapshot(session)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp snapshot(session) do
    session
    |> RelayPlayback.browser_metadata()
    |> Map.merge(CameraRelayWebRTC.metadata(session))
    |> Map.merge(%{
      type: "camera_relay_snapshot",
      relay_session_id: session.id,
      camera_source_id: session.camera_source_id,
      stream_profile_id: session.stream_profile_id,
      status: stringify(session.status),
      playback_state: playback_state(session),
      media_ingest_id: session.media_ingest_id,
      viewer_count: Map.get(session, :viewer_count, 0),
      lease_expires_at: iso8601(session.lease_expires_at),
      termination_kind: relay_termination_kind(session),
      close_reason: session.close_reason,
      failure_reason: session.failure_reason,
      updated_at: iso8601(session.updated_at)
    })
  end

  defp playback_state(%{status: status, media_ingest_id: media_ingest_id})
       when status in [:active, "active"] and is_binary(media_ingest_id) and media_ingest_id != "" do
    "ready"
  end

  defp playback_state(%{status: status}) when status in [:requested, :opening, "requested", "opening"], do: "pending"

  defp playback_state(%{status: status}) when status in [:closing, "closing"], do: "closing"
  defp playback_state(%{status: status}) when status in [:closed, "closed"], do: "closed"
  defp playback_state(%{status: status}) when status in [:failed, "failed"], do: "failed"
  defp playback_state(_session), do: "pending"

  defp terminal_snapshot?(%{playback_state: state}), do: state in ["closed", "failed"]

  defp prefer_snapshot(nil, snapshot), do: snapshot
  defp prefer_snapshot(snapshot, nil), do: snapshot

  defp prefer_snapshot(%{relay_session_id: relay_session_id} = current, %{relay_session_id: relay_session_id} = candidate) do
    if snapshot_regresses?(current, candidate) do
      current
    else
      candidate
    end
  end

  defp prefer_snapshot(_current, candidate), do: candidate

  defp snapshot_regresses?(current, candidate) do
    snapshot_state_rank(candidate) < snapshot_state_rank(current)
  end

  defp snapshot_state_rank(%{status: status}) do
    case status do
      value when value in [:requested, "requested"] -> 0
      value when value in [:opening, "opening"] -> 1
      value when value in [:active, "active"] -> 2
      value when value in [:closing, "closing"] -> 3
      value when value in [:closed, "closed"] -> 4
      value when value in [:failed, "failed"] -> 4
      _other -> 0
    end
  end

  defp subscribe(relay_session_id) do
    case RelayPubSub.subscribe(relay_session_id) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp subscribe_viewer(relay_session_id, viewer_id) do
    case RelayPubSub.subscribe_viewer(relay_session_id, viewer_id) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp schedule_poll(interval_ms) when is_integer(interval_ms) and interval_ms >= 0 do
    Process.send_after(self(), :poll, interval_ms)
  end

  defp schedule_poll(_interval_ms), do: schedule_poll(@default_poll_interval_ms)

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(_value), do: nil

  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value) when is_binary(value), do: value
  defp stringify(_value), do: "requested"

  defp normalize_snapshot(%{relay_session_id: relay_session_id} = payload, state)
       when relay_session_id == state.relay_session_id do
    payload
    |> RelayPlayback.browser_metadata()
    |> Map.merge(%{
      type: "camera_relay_snapshot",
      relay_session_id: relay_session_id,
      camera_source_id: Map.get(payload, :camera_source_id),
      stream_profile_id: Map.get(payload, :stream_profile_id),
      status: stringify(Map.get(payload, :status)),
      playback_state: stringify(Map.get(payload, :playback_state)),
      media_ingest_id: Map.get(payload, :media_ingest_id),
      viewer_count: Map.get(payload, :viewer_count, 0),
      lease_expires_at: iso8601_from_unix(Map.get(payload, :lease_expires_at_unix)),
      termination_kind: Map.get(payload, :termination_kind),
      close_reason: Map.get(payload, :close_reason),
      failure_reason: Map.get(payload, :failure_reason),
      updated_at: iso8601_from_unix(Map.get(payload, :updated_at_unix))
    })
  end

  defp normalize_snapshot(%{"relay_session_id" => relay_session_id} = payload, state)
       when relay_session_id == state.relay_session_id do
    payload
    |> RelayPlayback.browser_metadata()
    |> Map.merge(%{
      type: "camera_relay_snapshot",
      relay_session_id: relay_session_id,
      camera_source_id: Map.get(payload, "camera_source_id"),
      stream_profile_id: Map.get(payload, "stream_profile_id"),
      status: stringify(Map.get(payload, "status")),
      playback_state: stringify(Map.get(payload, "playback_state")),
      media_ingest_id: Map.get(payload, "media_ingest_id"),
      viewer_count: Map.get(payload, "viewer_count", 0),
      lease_expires_at: iso8601_from_unix(Map.get(payload, "lease_expires_at_unix")),
      termination_kind: Map.get(payload, "termination_kind"),
      close_reason: Map.get(payload, "close_reason"),
      failure_reason: Map.get(payload, "failure_reason"),
      updated_at: iso8601_from_unix(Map.get(payload, "updated_at_unix"))
    })
  end

  defp normalize_snapshot(_payload, _state), do: nil

  defp relay_termination_kind(session) when is_map(session) do
    Map.get(session, :termination_kind) || Map.get(session, "termination_kind")
  end

  defp iso8601_from_unix(value) when is_integer(value), do: value |> DateTime.from_unix!(:second) |> DateTime.to_iso8601()
  defp iso8601_from_unix(_value), do: nil

  defp encode_media_frame(payload) do
    codec = stringify_optional(Map.get(payload, :codec))
    payload_format = stringify_optional(Map.get(payload, :payload_format))
    track_id = stringify_optional(Map.get(payload, :track_id))
    media_payload = Map.get(payload, :payload, <<>>)

    flags =
      if Map.get(payload, :keyframe, false) == true do
        @media_frame_keyframe_flag
      else
        0
      end

    <<
      @media_frame_magic::binary,
      @media_frame_version,
      flags,
      normalize_uint64(Map.get(payload, :sequence))::unsigned-big-64,
      normalize_int64(Map.get(payload, :pts))::signed-big-64,
      normalize_int64(Map.get(payload, :dts))::signed-big-64,
      byte_size(codec)::unsigned-big-16,
      byte_size(payload_format)::unsigned-big-16,
      byte_size(track_id)::unsigned-big-16,
      codec::binary,
      payload_format::binary,
      track_id::binary,
      media_payload::binary
    >>
  end

  defp stringify_optional(nil), do: ""
  defp stringify_optional(value), do: to_string(value)

  defp normalize_uint64(value) when is_integer(value) and value >= 0, do: value
  defp normalize_uint64(_value), do: 0

  defp normalize_int64(value) when is_integer(value), do: value
  defp normalize_int64(_value), do: 0
end
