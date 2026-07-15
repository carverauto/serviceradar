defmodule ServiceRadarCoreElx.RemoteDesktop.MediaSessionManager do
  @moduledoc """
  Core-owned desktop media session manager.

  This process keeps viewer attachment and frame accounting state for desktop
  media without retaining screen payloads. A separate offer provider is still
  required before WebRTC viewers can be admitted. The default runtime provider
  owns the WebRTC DataChannels that carry SRDP media and browser control
  acknowledgements.
  """

  use GenServer

  alias ServiceRadarCoreElx.RemoteDesktop.DataChannelProvider

  @default_unavailable "desktop media plane is not available"
  @default_max_browser_ack_credit_bytes 2 * 1_048_576
  @default_offer_provider DataChannelProvider

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def add_webrtc_viewer(session_id, viewer_session_id, signaling, opts \\ [])
      when is_binary(session_id) and is_binary(viewer_session_id) do
    GenServer.call(
      server_name(opts),
      {:add_webrtc_viewer, session_id, viewer_session_id, signaling, opts}
    )
  end

  def remove_webrtc_viewer(session_id, viewer_session_id, opts \\ [])
      when is_binary(session_id) and is_binary(viewer_session_id) do
    GenServer.call(server_name(opts), {:remove_webrtc_viewer, session_id, viewer_session_id})
  end

  def close_session(session_id, opts \\ []) when is_binary(session_id) do
    GenServer.call(server_name(opts), {:close_session, session_id})
  end

  def prune_session(session_id, opts \\ []) when is_binary(session_id) do
    GenServer.call(server_name(opts), {:prune_session, session_id})
  end

  def forward_frame(session_id, %Desktopmedia.DesktopMediaFrameChunk{} = frame, opts \\ []) when is_binary(session_id) do
    GenServer.call(
      server_name(opts),
      {:forward_frame, session_id, frame, opts},
      Keyword.get(opts, :timeout, 15_000)
    )
  end

  def apply_browser_ack(session_id, viewer_session_id, ack, opts \\ [])
      when is_binary(session_id) and is_binary(viewer_session_id) and is_map(ack) do
    GenServer.call(server_name(opts), {:apply_browser_ack, session_id, viewer_session_id, ack})
  end

  def apply_browser_control(session_id, viewer_session_id, frame, opts \\ [])
      when is_binary(session_id) and is_binary(viewer_session_id) and is_map(frame) do
    GenServer.call(
      server_name(opts),
      {:apply_browser_control, session_id, viewer_session_id, frame}
    )
  end

  def fetch_session(session_id, opts \\ []) when is_binary(session_id) do
    GenServer.call(server_name(opts), {:fetch_session, session_id})
  end

  def reset(opts \\ []) do
    GenServer.call(server_name(opts), :reset)
  end

  @impl true
  def init(opts) do
    control_forwarder =
      Keyword.get(
        opts,
        :control_forwarder,
        Application.get_env(:serviceradar_core_elx, :remote_desktop_control_forwarder)
      )

    {:ok,
     %{
       sessions: %{},
       control_forwarder: control_forwarder,
       control_forwarder_opts: Keyword.get(opts, :control_forwarder_opts, [])
     }}
  end

  @impl true
  def handle_call({:add_webrtc_viewer, session_id, viewer_session_id, signaling, opts}, _from, state) do
    with {:ok, provider} <- resolve_offer_provider(opts),
         :ok <- provider.add_webrtc_viewer(session_id, viewer_session_id, signaling, opts) do
      session = Map.get(state.sessions, session_id, new_session(session_id))

      viewer = %{
        offer_provider: provider,
        offer_provider_opts: provider_runtime_opts(opts),
        viewer_session_id: viewer_session_id,
        signaling_pid: signaling_pid(signaling),
        transport: Keyword.get(opts, :transport),
        attached_at_unix: now_unix()
      }

      updated =
        session
        |> put_in([:viewers, viewer_session_id], viewer)
        |> Map.put(:updated_at_unix, now_unix())

      emit_viewer_event(:attached, updated, viewer)
      {:reply, :ok, put_in(state, [:sessions, session_id], updated)}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:remove_webrtc_viewer, session_id, viewer_session_id}, _from, state) do
    case Map.get(state.sessions, session_id) do
      nil ->
        {:reply, :ok, state}

      session ->
        {viewer, viewers} = Map.pop(session.viewers, viewer_session_id)
        if viewer, do: remove_provider_viewer(viewer, session_id)

        updated =
          session
          |> Map.put(:viewers, viewers)
          |> Map.put(:updated_at_unix, now_unix())

        if viewer, do: emit_viewer_event(:removed, updated, viewer)

        next_state =
          if map_size(viewers) == 0 do
            update_in(state, [:sessions], &Map.delete(&1, session_id))
          else
            put_in(state, [:sessions, session_id], updated)
          end

        {:reply, :ok, next_state}
    end
  end

  def handle_call({:close_session, session_id}, _from, state) do
    case Map.get(state.sessions, session_id) do
      nil ->
        {:reply, :ok, state}

      session ->
        empty_session =
          session
          |> Map.put(:viewers, %{})
          |> Map.put(:updated_at_unix, now_unix())

        Enum.each(session.viewers, fn {_viewer_session_id, viewer} ->
          remove_provider_viewer(viewer, session_id)
          emit_viewer_event(:removed, empty_session, viewer)
        end)

        {:reply, :ok, update_in(state, [:sessions], &Map.delete(&1, session_id))}
    end
  end

  def handle_call({:prune_session, session_id}, _from, state) do
    next_state =
      case Map.get(state.sessions, session_id) do
        %{viewers: viewers} when map_size(viewers) == 0 ->
          update_in(state, [:sessions], &Map.delete(&1, session_id))

        _active_or_missing ->
          state
      end

    {:reply, :ok, next_state}
  end

  def handle_call({:forward_frame, session_id, frame, opts}, _from, state) do
    session =
      state.sessions
      |> Map.get(session_id, new_session(session_id))
      |> merge_frame_session_metadata(Keyword.get(opts, :session, %{}))

    case forward_frame_to_viewers(session.viewers, session_id, frame) do
      :ok ->
        frame_cost = frame_byte_count(frame)
        viewer_count = map_size(session.viewers)
        credit_bytes = next_credit_grant(session)

        updated =
          session
          |> Map.put(:last_sequence, max(session.last_sequence, normalize_uint(frame.sequence)))
          |> Map.update!(:forwarded_bytes, &(&1 + frame_cost))
          |> Map.update!(:forwarded_frames, &(&1 + 1))
          |> Map.update!(:pending_credit_bytes, &max(&1 - credit_bytes, 0))
          |> maybe_pause_for_viewers(viewer_count)
          |> Map.put(:updated_at_unix, now_unix())
          |> put_last_frame_metadata(frame, frame_cost, viewer_count)

        emit_frame_event(updated, frame, frame_cost, viewer_count)

        {:reply, {:ok, ack_for(updated, frame, credit_bytes, viewer_count)},
         put_in(state, [:sessions, session_id], updated)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:apply_browser_ack, session_id, viewer_session_id, ack}, _from, state) do
    case Map.get(state.sessions, session_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{viewers: viewers} = session ->
        if Map.has_key?(viewers, viewer_session_id) do
          apply_bound_browser_ack(state, session, viewer_session_id, ack)
        else
          {:reply, {:error, :viewer_session_not_found}, state}
        end
    end
  end

  def handle_call({:apply_browser_control, session_id, viewer_session_id, frame}, _from, state) do
    case Map.get(state.sessions, session_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{viewers: viewers} = session ->
        cond do
          not Map.has_key?(viewers, viewer_session_id) ->
            {:reply, {:error, :viewer_session_not_found}, state}

          not valid_control_frame?(session_id, frame) ->
            {:reply, {:error, :invalid_control_frame}, state}

          true ->
            apply_bound_browser_control(state, session, viewer_session_id, frame)
        end
    end
  end

  def handle_call({:fetch_session, session_id}, _from, state) do
    {:reply, sanitize_session(Map.get(state.sessions, session_id)), state}
  end

  def handle_call(:reset, _from, state) do
    Enum.each(state.sessions, fn {session_id, session} ->
      Enum.each(session.viewers, fn {_viewer_session_id, viewer} ->
        remove_provider_viewer(viewer, session_id)
      end)
    end)

    {:reply, :ok, %{state | sessions: %{}}}
  end

  defp resolve_offer_provider(opts) do
    provider =
      cond do
        Keyword.has_key?(opts, :offer_provider) ->
          Keyword.fetch!(opts, :offer_provider)

        configured =
            Application.get_env(:serviceradar_core_elx, :remote_desktop_media_offer_provider) ->
          configured

        true ->
          @default_offer_provider
      end

    cond do
      provider in [nil, false] ->
        {:error, @default_unavailable}

      Code.ensure_loaded?(provider) and function_exported?(provider, :add_webrtc_viewer, 4) ->
        {:ok, provider}

      true ->
        {:error, {:invalid_offer_provider, provider}}
    end
  end

  defp new_session(session_id) do
    now = now_unix()

    %{
      session_id: session_id,
      desktop_session_id: session_id,
      media_session_id: nil,
      media_ingest_id: nil,
      agent_id: nil,
      gateway_id: nil,
      viewers: %{},
      last_sequence: 0,
      last_accepted_sequence: 0,
      forwarded_bytes: 0,
      forwarded_frames: 0,
      pending_credit_bytes: 0,
      paused: false,
      quality_level: nil,
      close_reason: nil,
      last_frame: nil,
      last_control_frame: nil,
      control_frame_count: 0,
      created_at_unix: now,
      updated_at_unix: now
    }
  end

  defp merge_frame_session_metadata(session, attrs) when is_map(attrs) do
    session
    |> maybe_put(:desktop_session_id, Map.get(attrs, :desktop_session_id))
    |> maybe_put(:media_session_id, Map.get(attrs, :media_session_id))
    |> maybe_put(:media_ingest_id, Map.get(attrs, :media_ingest_id))
    |> maybe_put(:agent_id, Map.get(attrs, :agent_id))
    |> maybe_put(:gateway_id, Map.get(attrs, :gateway_id))
  end

  defp put_last_frame_metadata(session, frame, frame_cost, viewer_count) do
    Map.put(session, :last_frame, %{
      sequence: frame.sequence,
      bytes: frame_cost,
      payload_family: frame.payload_family,
      encoding: frame.encoding,
      width: frame.width,
      height: frame.height,
      flags: frame.flags,
      viewer_count: viewer_count
    })
  end

  defp apply_bound_browser_ack(state, session, viewer_session_id, ack) do
    accepted_sequence = ack_sequence(ack)

    cond do
      ack_media_session_id(ack) not in [nil, "", session.media_session_id] ->
        {:reply, {:error, :media_session_mismatch}, state}

      accepted_sequence < session.last_accepted_sequence ->
        {:reply, {:error, :replayed_ack}, state}

      accepted_sequence == session.last_accepted_sequence and ack_credit_bytes(ack) > 0 ->
        {:reply, {:error, :duplicate_credit_ack}, state}

      true ->
        credit_bytes = min(ack_credit_bytes(ack), max_browser_ack_credit_bytes())

        updated =
          session
          |> Map.put(
            :last_accepted_sequence,
            max(session.last_accepted_sequence, accepted_sequence)
          )
          |> Map.update!(:pending_credit_bytes, &(&1 + credit_bytes))
          |> maybe_put(:quality_level, ack_quality_level(ack))
          |> maybe_put(:close_reason, ack_close_reason(ack))
          |> maybe_pause_from_ack(ack)
          |> Map.put(:updated_at_unix, now_unix())

        emit_browser_ack_event(updated, viewer_session_id, ack, credit_bytes)

        {:reply, {:ok, sanitize_session(updated)}, put_in(state, [:sessions, session.session_id], updated)}
    end
  end

  defp apply_bound_browser_control(state, session, viewer_session_id, frame) do
    case forward_browser_control(state, session, viewer_session_id, frame) do
      :ok ->
        updated =
          session
          |> Map.update!(:control_frame_count, &(&1 + 1))
          |> Map.put(:last_control_frame, safe_control_frame(frame))
          |> Map.put(:updated_at_unix, now_unix())

        emit_browser_control_event(updated, viewer_session_id, frame)

        {:reply, {:ok, sanitize_session(updated)}, put_in(state, [:sessions, session.session_id], updated)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp next_credit_grant(%{pending_credit_bytes: pending_credit_bytes}) do
    min(normalize_uint(pending_credit_bytes), max_browser_ack_credit_bytes())
  end

  defp ack_for(session, frame, credit_bytes, viewer_count) do
    %Desktopmedia.DesktopMediaAck{
      desktop_session_id: frame.desktop_session_id,
      media_session_id: frame.media_session_id,
      media_ingest_id: session.media_ingest_id || frame.media_ingest_id,
      gateway_id: session.gateway_id || "",
      last_accepted_sequence: frame.sequence,
      credit_bytes: credit_bytes,
      quality_level: session.quality_level || 0,
      pause: viewer_count == 0 or session.paused,
      close_reason: session.close_reason || ""
    }
  end

  defp sanitize_session(nil), do: nil

  defp sanitize_session(session) do
    %{
      session_id: session.session_id,
      desktop_session_id: session.desktop_session_id,
      media_session_id: session.media_session_id,
      media_ingest_id: session.media_ingest_id,
      agent_id: session.agent_id,
      gateway_id: session.gateway_id,
      viewer_count: map_size(session.viewers),
      last_sequence: session.last_sequence,
      last_accepted_sequence: session.last_accepted_sequence,
      forwarded_bytes: session.forwarded_bytes,
      forwarded_frames: session.forwarded_frames,
      pending_credit_bytes: session.pending_credit_bytes,
      paused: session.paused,
      quality_level: session.quality_level,
      close_reason: session.close_reason,
      last_frame: session.last_frame,
      last_control_frame: session.last_control_frame,
      control_frame_count: session.control_frame_count,
      created_at_unix: session.created_at_unix,
      updated_at_unix: session.updated_at_unix
    }
  end

  defp emit_viewer_event(event, session, viewer) do
    :telemetry.execute(
      [:serviceradar, :desktop_media, :viewer, event],
      %{viewer_count: map_size(session.viewers)},
      %{
        session_id: session.session_id,
        viewer_session_id: viewer.viewer_session_id,
        transport: viewer.transport
      }
    )
  end

  defp emit_frame_event(session, frame, frame_cost, viewer_count) do
    :telemetry.execute(
      [:serviceradar, :desktop_media, :manager, :frame],
      %{bytes: frame_cost, sequence: frame.sequence, viewer_count: viewer_count},
      %{
        session_id: session.session_id,
        desktop_session_id: frame.desktop_session_id,
        media_session_id: frame.media_session_id,
        media_ingest_id: session.media_ingest_id || frame.media_ingest_id,
        agent_id: session.agent_id,
        gateway_id: session.gateway_id,
        payload_family: frame.payload_family,
        encoding: frame.encoding
      }
    )
  end

  defp emit_browser_ack_event(session, viewer_session_id, ack, credit_bytes) do
    :telemetry.execute(
      [:serviceradar, :desktop_media, :browser, :ack],
      %{
        credit_bytes: credit_bytes,
        last_accepted_sequence: session.last_accepted_sequence,
        pending_credit_bytes: session.pending_credit_bytes
      },
      %{
        session_id: session.session_id,
        viewer_session_id: viewer_session_id,
        media_session_id: session.media_session_id,
        pause: ack_bool(ack, :pause, "pause"),
        resume: ack_bool(ack, :resume, "resume"),
        close_reason_present: ack_close_reason(ack) not in [nil, ""]
      }
    )
  end

  defp emit_browser_control_event(session, viewer_session_id, frame) do
    :telemetry.execute(
      [:serviceradar, :desktop_media, :browser, :control],
      %{control_frame_count: session.control_frame_count},
      %{
        session_id: session.session_id,
        viewer_session_id: viewer_session_id,
        frame_type: string_value(frame, "frame_type"),
        input_kind: input_kind(frame)
      }
    )
  end

  defp valid_control_frame?(session_id, frame) do
    string_value(frame, "session_id") == session_id and
      string_value(frame, "protocol") in ["rdp", "desktop"] and
      valid_control_frame_type?(string_value(frame, "frame_type"), frame)
  end

  defp valid_control_frame_type?("desktop.input", frame), do: input_kind(frame) in ["key", "pointer", "focus"]

  defp valid_control_frame_type?("desktop.resize", frame) do
    uint_value(frame, "width") > 0 and uint_value(frame, "height") > 0
  end

  defp valid_control_frame_type?("desktop.quality", frame), do: is_map(Map.get(frame, "quality"))
  defp valid_control_frame_type?("desktop.disconnect", _frame), do: true
  defp valid_control_frame_type?(_frame_type, _frame), do: false

  defp forward_browser_control(
         %{control_forwarder: forwarder, control_forwarder_opts: opts},
         session,
         viewer_session_id,
         frame
       ) do
    case resolve_control_forwarder(forwarder) do
      {:ok, nil} ->
        :ok

      {:ok, module} ->
        session
        |> sanitize_session()
        |> module.forward_browser_control(viewer_session_id, frame, opts)
        |> normalize_control_forward_result()

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_control_forwarder(forwarder) when forwarder in [nil, false], do: {:ok, nil}

  defp resolve_control_forwarder(forwarder) when is_atom(forwarder) do
    if Code.ensure_loaded?(forwarder) and
         function_exported?(forwarder, :forward_browser_control, 4) do
      {:ok, forwarder}
    else
      {:error, {:invalid_control_forwarder, forwarder}}
    end
  end

  defp resolve_control_forwarder(forwarder), do: {:error, {:invalid_control_forwarder, forwarder}}

  defp normalize_control_forward_result(:ok), do: :ok
  defp normalize_control_forward_result({:ok, _result}), do: :ok
  defp normalize_control_forward_result({:error, reason}), do: {:error, reason}

  defp normalize_control_forward_result(other), do: {:error, {:invalid_control_forward_result, other}}

  defp safe_control_frame(frame) do
    frame
    |> Map.take([
      "session_id",
      "protocol",
      "frame_type",
      "width",
      "height",
      "input",
      "quality",
      "reason"
    ])
    |> drop_sensitive_control_fields()
  end

  defp drop_sensitive_control_fields(%{"input" => input} = frame) when is_map(input) do
    Map.put(frame, "input", Map.take(input, ["kind", "down", "x", "y", "focused"]))
  end

  defp drop_sensitive_control_fields(frame), do: frame

  defp input_kind(%{"input" => input}) when is_map(input), do: string_value(input, "kind")
  defp input_kind(_frame), do: nil

  defp forward_frame_to_viewers(viewers, _session_id, _frame) when map_size(viewers) == 0, do: :ok

  defp forward_frame_to_viewers(viewers, session_id, frame) do
    Enum.reduce_while(viewers, :ok, fn {viewer_session_id, viewer}, :ok ->
      case forward_frame_to_viewer(viewer, session_id, viewer_session_id, frame) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp forward_frame_to_viewer(
         %{offer_provider: provider, offer_provider_opts: opts},
         session_id,
         viewer_session_id,
         frame
       ) do
    if function_exported?(provider, :forward_frame, 4) do
      provider.forward_frame(session_id, viewer_session_id, frame, opts)
    else
      :ok
    end
  end

  defp remove_provider_viewer(
         %{offer_provider: provider, offer_provider_opts: opts, viewer_session_id: viewer_session_id},
         session_id
       ) do
    if function_exported?(provider, :remove_webrtc_viewer, 3) do
      _ = provider.remove_webrtc_viewer(session_id, viewer_session_id, opts)
    end

    :ok
  end

  defp provider_runtime_opts(opts) do
    Keyword.take(opts, [:registry, :supervisor, :timeout])
  end

  defp maybe_pause_for_viewers(session, 0), do: Map.put(session, :paused, true)
  defp maybe_pause_for_viewers(session, _viewer_count), do: session

  defp maybe_pause_from_ack(session, ack) do
    cond do
      ack_bool(ack, :pause, "pause") -> Map.put(session, :paused, true)
      ack_bool(ack, :resume, "resume") -> Map.put(session, :paused, false)
      true -> session
    end
  end

  defp ack_media_session_id(ack), do: string_ack_value(ack, :media_session_id, "media_session_id")

  defp ack_sequence(ack) do
    ack
    |> int_ack_value(:last_accepted_sequence, "last_accepted_sequence", "last_accepted_seq")
    |> normalize_uint()
  end

  defp ack_credit_bytes(ack) do
    ack
    |> int_ack_value(:credit_bytes, "credit_bytes")
    |> normalize_uint()
  end

  defp ack_quality_level(ack) do
    case int_ack_value(ack, :quality_level, "quality_level") do
      value when is_integer(value) and value > 0 -> value
      _other -> nil
    end
  end

  defp ack_close_reason(ack) do
    case string_ack_value(ack, :close_reason, "close_reason") do
      "" -> nil
      value -> value
    end
  end

  defp ack_bool(ack, atom_key, string_key) do
    Map.get(ack, atom_key, Map.get(ack, string_key, false)) == true
  end

  defp int_ack_value(ack, atom_key, string_key) do
    Map.get(ack, atom_key, Map.get(ack, string_key, 0))
  end

  defp int_ack_value(ack, atom_key, string_key, legacy_string_key) do
    Map.get(ack, atom_key, Map.get(ack, string_key, Map.get(ack, legacy_string_key, 0)))
  end

  defp string_ack_value(ack, atom_key, string_key) do
    ack
    |> Map.get(atom_key, Map.get(ack, string_key, ""))
    |> to_string()
    |> String.trim()
  end

  defp string_value(map, key) when is_map(map) do
    map
    |> Map.get(key, "")
    |> to_string()
    |> String.trim()
  end

  defp uint_value(map, key) when is_map(map) do
    case Map.get(map, key, 0) do
      value when is_integer(value) and value > 0 -> value
      _other -> 0
    end
  end

  defp max_browser_ack_credit_bytes do
    case Application.get_env(
           :serviceradar_core_elx,
           :remote_desktop_media_max_browser_ack_credit_bytes
         ) do
      value when is_integer(value) and value > 0 -> value
      _other -> @default_max_browser_ack_credit_bytes
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp signaling_pid(%{pid: pid}) when is_pid(pid), do: pid
  defp signaling_pid(_signaling), do: nil

  defp frame_byte_count(frame), do: byte_size(frame.metadata || <<>>) + byte_size(frame.payload || <<>>)

  defp normalize_uint(value) when is_integer(value) and value >= 0, do: value
  defp normalize_uint(_value), do: 0

  defp now_unix, do: System.os_time(:second)

  defp server_name(opts), do: Keyword.get(opts, :server, __MODULE__)
end
