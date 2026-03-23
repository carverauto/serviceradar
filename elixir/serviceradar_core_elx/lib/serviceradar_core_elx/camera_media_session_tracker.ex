defmodule ServiceRadarCoreElx.CameraMediaSessionTracker do
  @moduledoc """
  Tracks authoritative camera relay sessions at the core-elx ingress boundary.
  """

  use GenServer

  alias ServiceRadar.Camera.RelayPubSub
  alias ServiceRadar.Camera.RelaySessionLifecycle

  @default_lease_seconds 30

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def open_session(attrs) when is_map(attrs) do
    GenServer.call(__MODULE__, {:open_session, attrs})
  end

  def heartbeat(relay_session_id, media_ingest_id, attrs \\ %{}) do
    GenServer.call(__MODULE__, {:heartbeat, relay_session_id, media_ingest_id, attrs})
  end

  def record_chunk(relay_session_id, media_ingest_id, attrs) when is_map(attrs) do
    GenServer.call(__MODULE__, {:record_chunk, relay_session_id, media_ingest_id, attrs})
  end

  def close_session(relay_session_id, media_ingest_id, attrs \\ %{}) do
    GenServer.call(__MODULE__, {:close_session, relay_session_id, media_ingest_id, attrs})
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       sessions: %{},
       sync_module:
         Keyword.get(
           opts,
           :sync_module,
           Application.get_env(
             :serviceradar_core_elx,
             :camera_relay_session_lifecycle,
             RelaySessionLifecycle
           )
         ),
       sync_opts:
         Keyword.get(
           opts,
           :sync_opts,
           Application.get_env(:serviceradar_core_elx, :camera_relay_session_lifecycle_opts, [])
         )
     }}
  end

  @impl true
  def handle_call({:open_session, attrs}, _from, state) do
    relay_session_id = required_string!(attrs, :relay_session_id)

    case Map.get(state.sessions, relay_session_id) do
      nil ->
        session = build_session(attrs)

        case sync_module(state).activate_session(
               session.relay_session_id,
               session.media_ingest_id,
               %{lease_expires_at_unix: session.lease_expires_at_unix},
               sync_opts(state)
             ) do
          {:ok, _persisted_session} ->
            :ok = RelayPubSub.broadcast_state(relay_session_id, relay_state_payload(session))
            {:reply, {:ok, session}, put_in(state, [:sessions, relay_session_id], session)}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      _existing ->
        {:reply, {:error, :already_exists}, state}
    end
  end

  def handle_call({:heartbeat, relay_session_id, media_ingest_id, attrs}, _from, state) do
    case fetch_and_verify_session(state, relay_session_id, media_ingest_id) do
      {:ok, session} ->
        updated =
          Map.merge(session, %{
            last_sequence: normalize_uint(Map.get(attrs, :last_sequence, session.last_sequence)),
            sent_bytes: normalize_uint(Map.get(attrs, :sent_bytes, session.sent_bytes)),
            updated_at_unix: now_unix(),
            lease_expires_at_unix: lease_expiry_unix()
          })

        case sync_module(state).heartbeat_session(
               relay_session_id,
               media_ingest_id,
               %{lease_expires_at_unix: updated.lease_expires_at_unix},
               sync_opts(state)
             ) do
          {:ok, _persisted_session} ->
            :ok = RelayPubSub.broadcast_state(relay_session_id, relay_state_payload(updated))
            {:reply, {:ok, updated}, put_in(state, [:sessions, relay_session_id], updated)}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:record_chunk, relay_session_id, media_ingest_id, attrs}, _from, state) do
    case fetch_and_verify_session(state, relay_session_id, media_ingest_id) do
      {:ok, session} ->
        payload = Map.get(attrs, :payload, <<>>)

        updated =
          Map.merge(session, %{
            last_sequence: normalize_uint(Map.get(attrs, :sequence, session.last_sequence)),
            sent_bytes: session.sent_bytes + byte_size(payload),
            updated_at_unix: now_unix()
          })

        :ok =
          RelayPubSub.broadcast_chunk(relay_session_id, %{
            relay_session_id: relay_session_id,
            media_ingest_id: media_ingest_id,
            sequence: updated.last_sequence,
            pts: Map.get(attrs, :pts),
            dts: Map.get(attrs, :dts),
            codec: optional_string(attrs, :codec),
            payload_format: optional_string(attrs, :payload_format),
            track_id: optional_string(attrs, :track_id),
            keyframe: Map.get(attrs, :keyframe, false) == true,
            payload: payload
          })

        {:reply, {:ok, updated}, put_in(state, [:sessions, relay_session_id], updated)}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:close_session, relay_session_id, media_ingest_id, attrs}, _from, state) do
    case fetch_and_verify_session(state, relay_session_id, media_ingest_id) do
      {:ok, session} ->
        case sync_module(state).close_session(
               relay_session_id,
               media_ingest_id,
               %{close_reason: Map.get(attrs, :reason) || Map.get(attrs, :close_reason)},
               sync_opts(state)
             ) do
          {:ok, _persisted_session} ->
            :ok =
              RelayPubSub.broadcast_state(relay_session_id, %{
                relay_session_id: relay_session_id,
                camera_source_id: session.camera_source_id,
                stream_profile_id: session.stream_profile_id,
                status: "closed",
                playback_state: "closed",
                media_ingest_id: media_ingest_id,
                close_reason: Map.get(attrs, :reason) || Map.get(attrs, :close_reason),
                updated_at_unix: now_unix()
              })

            {:reply, :ok, update_in(state, [:sessions], &Map.delete(&1, relay_session_id))}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      error ->
        {:reply, error, state}
    end
  end

  defp build_session(attrs) do
    now = now_unix()

    %{
      relay_session_id: required_string!(attrs, :relay_session_id),
      media_ingest_id: random_id("core-media"),
      agent_id: required_string!(attrs, :agent_id),
      gateway_id: required_string!(attrs, :gateway_id),
      camera_source_id: required_string!(attrs, :camera_source_id),
      stream_profile_id: required_string!(attrs, :stream_profile_id),
      codec_hint: optional_string(attrs, :codec_hint),
      container_hint: optional_string(attrs, :container_hint),
      last_sequence: 0,
      sent_bytes: 0,
      created_at_unix: now,
      updated_at_unix: now,
      lease_expires_at_unix: lease_expiry_unix()
    }
  end

  defp fetch_and_verify_session(state, relay_session_id, media_ingest_id) do
    case Map.get(state.sessions, relay_session_id) do
      nil ->
        {:error, :not_found}

      %{media_ingest_id: ^media_ingest_id} = session ->
        {:ok, session}

      _session ->
        {:error, :media_ingest_mismatch}
    end
  end

  defp sync_module(state), do: state.sync_module
  defp sync_opts(state), do: state.sync_opts

  defp now_unix, do: System.os_time(:second)
  defp lease_expiry_unix, do: now_unix() + @default_lease_seconds

  defp random_id(prefix) do
    suffix =
      8
      |> :crypto.strong_rand_bytes()
      |> Base.encode16(case: :lower)

    "#{prefix}-#{suffix}"
  end

  defp required_string!(attrs, key) do
    case optional_string(attrs, key) do
      "" -> raise ArgumentError, "#{key} is required"
      value -> value
    end
  end

  defp optional_string(attrs, key) do
    attrs
    |> Map.get(key, "")
    |> to_string()
    |> String.trim()
  end

  defp normalize_uint(value) when is_integer(value) and value >= 0, do: value
  defp normalize_uint(_value), do: 0

  defp relay_state_payload(session) do
    %{
      relay_session_id: session.relay_session_id,
      camera_source_id: session.camera_source_id,
      stream_profile_id: session.stream_profile_id,
      status: relay_status(session),
      playback_state: playback_state(session),
      media_ingest_id: session.media_ingest_id,
      lease_expires_at_unix: session.lease_expires_at_unix,
      sent_bytes: session.sent_bytes,
      last_sequence: session.last_sequence,
      updated_at_unix: session.updated_at_unix
    }
  end

  defp relay_status(%{media_ingest_id: media_ingest_id}) when is_binary(media_ingest_id) and media_ingest_id != "",
    do: "active"

  defp relay_status(_session), do: "opening"

  defp playback_state(%{media_ingest_id: media_ingest_id}) when is_binary(media_ingest_id) and media_ingest_id != "" do
    "ready"
  end

  defp playback_state(_session), do: "pending"
end
