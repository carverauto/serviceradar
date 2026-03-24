defmodule ServiceRadarCoreElx.CameraMediaSessionTracker do
  @moduledoc """
  Tracks authoritative camera relay sessions at the core-elx ingress boundary.
  """

  use GenServer

  alias ServiceRadar.Camera.RelayPlayback
  alias ServiceRadar.Camera.RelayPubSub
  alias ServiceRadar.Camera.RelaySessionLifecycle
  alias ServiceRadar.Camera.RelayTermination
  alias ServiceRadar.Telemetry
  alias ServiceRadarCoreElx.CameraRelay.PipelineManager
  alias ServiceRadarCoreElx.CameraRelay.ViewerRegistry

  require Logger

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

  def mark_closing(relay_session_id, attrs \\ %{}) when is_binary(relay_session_id) and is_map(attrs) do
    GenServer.cast(__MODULE__, {:mark_closing, relay_session_id, attrs})
  end

  def sync_viewer_count(relay_session_id, viewer_count) when is_binary(relay_session_id) do
    GenServer.cast(__MODULE__, {:sync_viewer_count, relay_session_id, viewer_count})
  end

  def fetch_session(relay_session_id) when is_binary(relay_session_id) do
    GenServer.call(__MODULE__, {:fetch_session, relay_session_id})
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
         ),
       pipeline_manager:
         Keyword.get(
           opts,
           :pipeline_manager,
           Application.get_env(:serviceradar_core_elx, :camera_relay_pipeline_manager, PipelineManager)
         ),
       viewer_registry:
         Keyword.get(
           opts,
           :viewer_registry,
           Application.get_env(:serviceradar_core_elx, :camera_relay_viewer_registry, ViewerRegistry)
         )
     }}
  end

  @impl true
  def handle_call({:open_session, attrs}, _from, state) do
    relay_session_id = required_string!(attrs, :relay_session_id)

    case Map.get(state.sessions, relay_session_id) do
      nil ->
        session =
          build_session(Map.put(attrs, :viewer_count, current_viewer_count(state, relay_session_id)))

        with {:ok, _pipeline} <- pipeline_manager(state).open_session(session),
             {:ok, _persisted_session} <-
               sync_module(state).activate_session(
                 session.relay_session_id,
                 session.media_ingest_id,
                 %{
                   lease_expires_at_unix: session.lease_expires_at_unix,
                   viewer_count: session.viewer_count
                 },
                 sync_opts(state)
               ) do
          log_session(:info, "Core camera relay opened", session)
          emit_session_event(:opened, session)
          :ok = RelayPubSub.broadcast_state(relay_session_id, relay_state_payload(session))
          {:reply, {:ok, session}, put_in(state, [:sessions, relay_session_id], session)}
        else
          {:error, reason} ->
            _ = pipeline_manager(state).close_session(session.relay_session_id)
            log_session(:warning, "Core camera relay open failed", session, %{reason: inspect(reason)})
            emit_session_event(:failed, session, %{reason: inspect(reason), stage: "open"})
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
            lease_expires_at_unix: lease_expiry_unix(),
            viewer_count: current_viewer_count(state, relay_session_id)
          })

        if closing_session?(session) do
          :ok = RelayPubSub.broadcast_state(relay_session_id, relay_state_payload(updated))
          {:reply, {:ok, updated}, put_in(state, [:sessions, relay_session_id], updated)}
        else
          case sync_module(state).heartbeat_session(
                 relay_session_id,
                 media_ingest_id,
                 %{
                   lease_expires_at_unix: updated.lease_expires_at_unix,
                   viewer_count: updated.viewer_count
                 },
                 sync_opts(state)
               ) do
            {:ok, _persisted_session} ->
              :ok = RelayPubSub.broadcast_state(relay_session_id, relay_state_payload(updated))
              {:reply, {:ok, updated}, put_in(state, [:sessions, relay_session_id], updated)}

            {:error, reason} ->
              log_session(:warning, "Core camera relay heartbeat failed", updated, %{reason: inspect(reason)})
              emit_session_event(:failed, updated, %{reason: inspect(reason), stage: "heartbeat"})
              {:reply, {:error, reason}, state}
          end
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
            updated_at_unix: now_unix(),
            viewer_count: current_viewer_count(state, relay_session_id)
          })

        if closing_session?(session) do
          {:reply, {:ok, updated}, put_in(state, [:sessions, relay_session_id], updated)}
        else
          case pipeline_manager(state).record_chunk(relay_session_id, %{
                 media_ingest_id: media_ingest_id,
                 sequence: updated.last_sequence,
                 pts: Map.get(attrs, :pts),
                 dts: Map.get(attrs, :dts),
                 codec: optional_string(attrs, :codec),
                 payload_format: optional_string(attrs, :payload_format),
                 track_id: optional_string(attrs, :track_id),
                 keyframe: Map.get(attrs, :keyframe, false) == true,
                 payload: payload
               }) do
            :ok ->
              {:reply, {:ok, updated}, put_in(state, [:sessions, relay_session_id], updated)}

            {:error, reason} ->
              log_session(:warning, "Core camera relay chunk forward failed", updated, %{reason: inspect(reason)})
              emit_session_event(:failed, updated, %{reason: inspect(reason), stage: "record_chunk"})
              {:reply, {:error, reason}, state}
          end
        end

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
               %{
                 close_reason: Map.get(attrs, :reason) || Map.get(attrs, :close_reason),
                 viewer_count: 0
               },
               sync_opts(state)
             ) do
          {:ok, persisted_session} ->
            _ = pipeline_manager(state).close_session(relay_session_id)

            close_reason =
              persisted_value(
                persisted_session,
                :close_reason,
                Map.get(attrs, :reason) || Map.get(attrs, :close_reason)
              )

            failure_reason = persisted_value(persisted_session, :failure_reason)
            updated_at_unix = now_unix()

            closed_session =
              session
              |> Map.put(:status, "closed")
              |> Map.put(:media_ingest_id, media_ingest_id)
              |> Map.put(:viewer_count, 0)
              |> Map.put(:close_reason, close_reason)
              |> Map.put(:failure_reason, failure_reason)
              |> Map.put(:updated_at_unix, updated_at_unix)

            log_session(:info, "Core camera relay closed", closed_session)
            emit_session_event(:closed, closed_session)

            :ok =
              RelayPubSub.broadcast_state(relay_session_id, relay_state_payload(closed_session))

            {:reply, :ok, update_in(state, [:sessions], &Map.delete(&1, relay_session_id))}

          {:error, reason} ->
            log_session(:warning, "Core camera relay close failed", session, %{reason: inspect(reason)})
            emit_session_event(:failed, session, %{reason: inspect(reason), stage: "close"})
            {:reply, {:error, reason}, state}
        end

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:fetch_session, relay_session_id}, _from, state) do
    {:reply, Map.get(state.sessions, relay_session_id), state}
  end

  @impl true
  def handle_cast({:sync_viewer_count, relay_session_id, viewer_count}, state) do
    case Map.get(state.sessions, relay_session_id) do
      nil ->
        {:noreply, state}

      session ->
        normalized_viewer_count = normalize_uint(viewer_count)

        updated =
          Map.merge(session, %{
            viewer_count: normalized_viewer_count,
            updated_at_unix: now_unix()
          })

        if normalized_viewer_count != session.viewer_count do
          emit_session_event(
            :viewer_count_changed,
            updated,
            %{previous_viewer_count: session.viewer_count},
            %{viewer_count: normalized_viewer_count}
          )
        end

        _ =
          sync_module(state).heartbeat_session(
            relay_session_id,
            session.media_ingest_id,
            %{
              lease_expires_at_unix: session.lease_expires_at_unix,
              viewer_count: normalized_viewer_count
            },
            sync_opts(state)
          )

        :ok = RelayPubSub.broadcast_state(relay_session_id, relay_state_payload(updated))

        {:noreply, put_in(state, [:sessions, relay_session_id], updated)}
    end
  end

  def handle_cast({:mark_closing, relay_session_id, attrs}, state) do
    case Map.get(state.sessions, relay_session_id) do
      nil ->
        {:noreply, state}

      session ->
        updated =
          session
          |> Map.put(:status, "closing")
          |> Map.put(:updated_at_unix, now_unix())
          |> put_optional_reason(:close_reason, Map.get(attrs, :close_reason))
          |> Map.put(:viewer_count, normalize_uint(Map.get(attrs, :viewer_count, session.viewer_count)))

        log_session(:info, "Core camera relay closing", updated)
        emit_session_event(:closing, updated)
        :ok = RelayPubSub.broadcast_state(relay_session_id, relay_state_payload(updated))

        {:noreply, put_in(state, [:sessions, relay_session_id], updated)}
    end
  end

  defp build_session(attrs) do
    now = now_unix()

    %{
      relay_session_id: required_string!(attrs, :relay_session_id),
      media_ingest_id: optional_string(attrs, :media_ingest_id) || random_id("core-media"),
      agent_id: required_string!(attrs, :agent_id),
      gateway_id: required_string!(attrs, :gateway_id),
      camera_source_id: required_string!(attrs, :camera_source_id),
      stream_profile_id: required_string!(attrs, :stream_profile_id),
      codec_hint: optional_string(attrs, :codec_hint),
      container_hint: optional_string(attrs, :container_hint),
      status: "active",
      close_reason: nil,
      failure_reason: nil,
      viewer_count: normalize_uint(Map.get(attrs, :viewer_count)),
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
  defp pipeline_manager(state), do: state.pipeline_manager
  defp viewer_registry(state), do: state.viewer_registry

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

  defp closing_session?(%{status: status}), do: status in [:closing, "closing"]
  defp closing_session?(_session), do: false

  defp put_optional_reason(session, _key, nil), do: session

  defp put_optional_reason(session, key, value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: session, else: Map.put(session, key, trimmed)
  end

  defp put_optional_reason(session, key, value), do: Map.put(session, key, to_string(value))

  defp persisted_value(session, key, default \\ nil)

  defp persisted_value(%{} = session, key, default) do
    Map.get(session, key, default)
  end

  defp persisted_value(_session, _key, default), do: default

  defp emit_session_event(event, session, extra_metadata \\ %{}, measurements \\ %{}) do
    Telemetry.emit_camera_relay_session_event(
      event,
      Map.merge(session_metadata(session), extra_metadata),
      Map.merge(
        %{
          sent_bytes: Map.get(session, :sent_bytes, 0),
          last_sequence: Map.get(session, :last_sequence, 0),
          viewer_count: Map.get(session, :viewer_count, 0)
        },
        measurements
      )
    )
  end

  defp session_metadata(session) do
    %{
      relay_boundary: "core_elx",
      relay_session_id: session.relay_session_id,
      media_ingest_id: Map.get(session, :media_ingest_id),
      agent_id: Map.get(session, :agent_id),
      gateway_id: Map.get(session, :gateway_id),
      camera_source_id: Map.get(session, :camera_source_id),
      stream_profile_id: Map.get(session, :stream_profile_id),
      relay_status: relay_status(session),
      playback_state: playback_state(session),
      termination_kind: RelayTermination.kind_string(session),
      viewer_count: Map.get(session, :viewer_count, 0),
      close_reason: Map.get(session, :close_reason),
      failure_reason: Map.get(session, :failure_reason)
    }
  end

  defp log_session(level, message, session, extra \\ %{}) do
    details =
      extra
      |> Map.merge(%{
        relay_session_id: session.relay_session_id,
        media_ingest_id: Map.get(session, :media_ingest_id),
        agent_id: Map.get(session, :agent_id),
        gateway_id: Map.get(session, :gateway_id),
        camera_source_id: Map.get(session, :camera_source_id),
        stream_profile_id: Map.get(session, :stream_profile_id),
        status: relay_status(session),
        termination_kind: RelayTermination.kind_string(session),
        viewer_count: Map.get(session, :viewer_count, 0),
        close_reason: Map.get(session, :close_reason),
        failure_reason: Map.get(session, :failure_reason)
      })
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{value}" end)

    case level do
      :warning -> Logger.warning("#{message}: #{details}")
      _ -> Logger.info("#{message}: #{details}")
    end
  end

  defp relay_state_payload(session) do
    session
    |> RelayPlayback.browser_metadata()
    |> Map.merge(%{
      relay_session_id: session.relay_session_id,
      camera_source_id: session.camera_source_id,
      stream_profile_id: session.stream_profile_id,
      status: relay_status(session),
      playback_state: playback_state(session),
      media_ingest_id: session.media_ingest_id,
      viewer_count: session.viewer_count,
      termination_kind: RelayTermination.kind_string(session),
      close_reason: Map.get(session, :close_reason),
      failure_reason: Map.get(session, :failure_reason),
      lease_expires_at_unix: session.lease_expires_at_unix,
      sent_bytes: session.sent_bytes,
      last_sequence: session.last_sequence,
      updated_at_unix: session.updated_at_unix
    })
  end

  defp relay_status(%{status: status}) when status in ["active", "closing", "closed", "failed"], do: status

  defp relay_status(%{media_ingest_id: media_ingest_id}) when is_binary(media_ingest_id) and media_ingest_id != "",
    do: "active"

  defp relay_status(_session), do: "opening"

  defp playback_state(%{status: "closing"}), do: "closing"
  defp playback_state(%{status: "closed"}), do: "closed"
  defp playback_state(%{status: "failed"}), do: "failed"

  defp playback_state(%{media_ingest_id: media_ingest_id}) when is_binary(media_ingest_id) and media_ingest_id != "" do
    "ready"
  end

  defp playback_state(_session), do: "pending"

  defp current_viewer_count(state, relay_session_id) do
    viewer_registry(state).viewer_count(relay_session_id)
  rescue
    _error -> 0
  end
end
