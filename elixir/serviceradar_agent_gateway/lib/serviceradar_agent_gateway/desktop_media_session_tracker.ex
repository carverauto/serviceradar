defmodule ServiceRadarAgentGateway.DesktopMediaSessionTracker do
  @moduledoc """
  Tracks active desktop media sessions at the gateway boundary.

  The tracker owns gateway-local admission state only. It does not retain screen
  content, input payloads, or credentials.
  """

  use GenServer

  alias ServiceRadarAgentGateway.MediaSessionHelpers

  require Logger

  @default_lease_seconds 30
  @default_initial_credit_bytes 4 * 1_048_576
  @default_max_chunk_bytes 1_048_576
  @default_max_ack_credit_bytes 2 * 1_048_576
  @default_max_sessions_per_agent 8
  @default_max_sessions_per_gateway 16
  @default_sweep_interval_ms 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def open_session(attrs) when is_map(attrs) do
    GenServer.call(__MODULE__, {:open_session, attrs})
  end

  def fetch_session(desktop_session_id) do
    GenServer.call(__MODULE__, {:fetch_session, desktop_session_id})
  end

  def fetch_session(desktop_session_id, agent_id) when is_binary(agent_id) do
    GenServer.call(__MODULE__, {:fetch_session_owned, desktop_session_id, agent_id})
  end

  def record_frame(desktop_session_id, media_session_id, agent_id, attrs) when is_binary(agent_id) and is_map(attrs) do
    GenServer.call(__MODULE__, {:record_frame_owned, desktop_session_id, media_session_id, agent_id, attrs})
  end

  def apply_ack(desktop_session_id, media_session_id, attrs) when is_map(attrs) do
    GenServer.call(__MODULE__, {:apply_ack, desktop_session_id, media_session_id, attrs})
  end

  def heartbeat(desktop_session_id, media_session_id, agent_id, attrs) when is_binary(agent_id) and is_map(attrs) do
    GenServer.call(__MODULE__, {:heartbeat_owned, desktop_session_id, media_session_id, agent_id, attrs})
  end

  def mark_closing(desktop_session_id, media_session_id, agent_id, attrs) when is_binary(agent_id) and is_map(attrs) do
    GenServer.call(__MODULE__, {:mark_closing_owned, desktop_session_id, media_session_id, agent_id, attrs})
  end

  def close_session(desktop_session_id, media_session_id, agent_id, attrs) when is_binary(agent_id) and is_map(attrs) do
    GenServer.call(__MODULE__, {:close_session_owned, desktop_session_id, media_session_id, agent_id, attrs})
  end

  def pending_core_cleanups do
    GenServer.call(__MODULE__, :pending_core_cleanups)
  end

  def complete_pending_core_cleanup(desktop_session_id, media_session_id, agent_id, attrs)
      when is_binary(agent_id) and is_map(attrs) do
    GenServer.call(
      __MODULE__,
      {:complete_pending_core_cleanup, desktop_session_id, media_session_id, agent_id, attrs}
    )
  end

  def sweep_expired_sessions do
    GenServer.call(__MODULE__, :sweep_expired_sessions)
  end

  @impl true
  def init(opts) do
    sweep_interval_ms =
      opts
      |> Keyword.get(
        :sweep_interval_ms,
        Application.get_env(:serviceradar_agent_gateway, :desktop_media_sweep_interval_ms)
      )
      |> normalize_sweep_interval_ms()

    schedule_sweep(sweep_interval_ms)

    {:ok, %{sessions: %{}, sweep_interval_ms: sweep_interval_ms}}
  end

  @impl true
  def handle_call({:open_session, attrs}, _from, state) do
    state = sweep_expired_sessions(state)
    session = build_session(attrs)

    cond do
      Map.has_key?(state.sessions, session.desktop_session_id) ->
        {:reply, {:error, :already_exists}, state}

      agent_limit_exceeded?(state, session) ->
        limit = max_sessions_per_agent()

        log_session(:warning, "Gateway desktop media denied: per-agent session limit exceeded", session, %{
          limit_kind: "agent",
          limit: limit
        })

        emit_session_event(:saturation_denied, session, %{limit_kind: "agent", limit: limit})

        {:reply, {:error, {:limit_exceeded, :agent, limit}}, state}

      gateway_limit_exceeded?(state) ->
        limit = max_sessions_per_gateway()

        log_session(:warning, "Gateway desktop media denied: per-gateway session limit exceeded", session, %{
          limit_kind: "gateway",
          limit: limit
        })

        emit_session_event(:saturation_denied, session, %{limit_kind: "gateway", limit: limit})

        {:reply, {:error, {:limit_exceeded, :gateway, limit}}, state}

      true ->
        log_session(:info, "Gateway desktop media opened", session)
        emit_session_event(:opened, session)
        {:reply, {:ok, session}, put_in(state, [:sessions, session.desktop_session_id], session)}
    end
  end

  def handle_call({:fetch_session, desktop_session_id}, _from, state) do
    {:reply, Map.get(state.sessions, desktop_session_id), state}
  end

  def handle_call({:fetch_session_owned, desktop_session_id, agent_id}, _from, state) do
    {:reply, fetch_session_for_owner(state, desktop_session_id, agent_id), state}
  end

  def handle_call(:sweep_expired_sessions, _from, state) do
    updated = sweep_expired_sessions(state)
    removed = map_size(state.sessions) - map_size(updated.sessions)

    {:reply, {:ok, removed}, updated}
  end

  def handle_call(:pending_core_cleanups, _from, state) do
    pending =
      state.sessions
      |> Map.values()
      |> Enum.filter(&Map.get(&1, :pending_core_cleanup, false))

    {:reply, pending, state}
  end

  def handle_call({:record_frame_owned, desktop_session_id, media_session_id, agent_id, attrs}, _from, state) do
    case fetch_and_verify_active_owned_session(state, desktop_session_id, media_session_id, agent_id, attrs) do
      {:ok, session} ->
        cost = normalize_uint(Map.get(attrs, :credit_cost, Map.get(attrs, :payload_bytes, 0)))

        updated =
          Map.merge(session, %{
            last_sequence: max(session.last_sequence, normalize_uint(Map.get(attrs, :sequence, 0))),
            sent_bytes: session.sent_bytes + cost,
            updated_at_unix: now_unix()
          })

        {:reply, {:ok, updated}, put_in(state, [:sessions, desktop_session_id], updated)}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:apply_ack, desktop_session_id, media_session_id, attrs}, _from, state) do
    case fetch_and_verify_active_session_with_ingest(state, desktop_session_id, media_session_id, attrs) do
      {:ok, session} ->
        accepted_sequence = normalize_uint(Map.get(attrs, :last_accepted_sequence, session.last_accepted_sequence))

        updated =
          session
          |> Map.merge(%{
            last_accepted_sequence: max(session.last_accepted_sequence, accepted_sequence),
            received_credit_bytes: session.received_credit_bytes + ack_credit_grant(session, attrs),
            updated_at_unix: now_unix()
          })
          |> maybe_put(:quality_level, normalize_optional_quality(Map.get(attrs, :quality_level)))
          |> maybe_put(:paused, Map.get(attrs, :pause))
          |> maybe_put(:paused, maybe_resume(Map.get(attrs, :resume)))
          |> put_optional_reason(:close_reason, Map.get(attrs, :close_reason))
          |> maybe_mark_closing_for_close_reason()

        {:reply, {:ok, updated}, put_in(state, [:sessions, desktop_session_id], updated)}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:heartbeat_owned, desktop_session_id, media_session_id, agent_id, attrs}, _from, state) do
    case fetch_and_verify_active_owned_session(state, desktop_session_id, media_session_id, agent_id, attrs) do
      {:ok, session} ->
        updated =
          Map.merge(session, %{
            last_sequence: max(session.last_sequence, normalize_uint(Map.get(attrs, :last_sequence, 0))),
            sent_bytes: normalize_uint(Map.get(attrs, :sent_bytes, session.sent_bytes)),
            received_credit_bytes: normalize_uint(Map.get(attrs, :received_credit_bytes, session.received_credit_bytes)),
            viewer_count: normalize_uint(Map.get(attrs, :viewer_count, session.viewer_count)),
            updated_at_unix: now_unix(),
            lease_expires_at_unix: normalize_uint(Map.get(attrs, :lease_expires_at_unix, lease_expiry_unix()))
          })

        {:reply, {:ok, updated}, put_in(state, [:sessions, desktop_session_id], updated)}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:mark_closing_owned, desktop_session_id, media_session_id, agent_id, attrs}, _from, state) do
    case fetch_and_verify_owned_session(state, desktop_session_id, media_session_id, agent_id, attrs) do
      {:ok, session} ->
        updated =
          session
          |> Map.put(:status, "closing")
          |> Map.put(:updated_at_unix, now_unix())
          |> Map.put(
            :pending_core_cleanup,
            Map.get(session, :pending_core_cleanup, false) or
              Map.get(attrs, :pending_core_cleanup, false)
          )
          |> put_optional_reason(:close_reason, Map.get(attrs, :reason) || Map.get(attrs, :close_reason))

        log_session(:info, "Gateway desktop media closing", updated)
        emit_session_event(:closing, updated)
        {:reply, {:ok, updated}, put_in(state, [:sessions, desktop_session_id], updated)}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:close_session_owned, desktop_session_id, media_session_id, agent_id, attrs}, _from, state) do
    case fetch_and_verify_owned_session(state, desktop_session_id, media_session_id, agent_id, attrs) do
      {:ok, session} ->
        log_session(:info, "Gateway desktop media closed", session)
        emit_session_event(:closed, session)
        {:reply, :ok, update_in(state, [:sessions], &Map.delete(&1, desktop_session_id))}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:complete_pending_core_cleanup, desktop_session_id, media_session_id, agent_id, attrs}, _from, state) do
    case fetch_and_verify_owned_session(state, desktop_session_id, media_session_id, agent_id, attrs) do
      {:ok, %{pending_core_cleanup: true} = session} ->
        log_session(:info, "Gateway desktop media pending core cleanup reconciled", session)
        emit_session_event(:closed, session, %{reconciled: true})
        {:reply, :ok, update_in(state, [:sessions], &Map.delete(&1, desktop_session_id))}

      {:ok, _session} ->
        {:reply, {:error, :cleanup_not_pending}, state}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_info(:sweep_expired_sessions, state) do
    updated = sweep_expired_sessions(state)
    schedule_sweep(Map.get(updated, :sweep_interval_ms, @default_sweep_interval_ms))

    {:noreply, updated}
  end

  defp build_session(attrs) do
    desktop_session_id = required_string!(attrs, :desktop_session_id)
    media_session_id = optional_string(attrs, :media_session_id)
    media_ingest_id = optional_string(attrs, :media_ingest_id)
    now = now_unix()

    %{
      desktop_session_id: desktop_session_id,
      media_session_id:
        if(media_session_id == "", do: MediaSessionHelpers.random_id("desktop-media"), else: media_session_id),
      media_ingest_id: if(media_ingest_id == "", do: MediaSessionHelpers.random_id("media"), else: media_ingest_id),
      agent_id: required_string!(attrs, :agent_id),
      gateway_id: required_string!(attrs, :gateway_id),
      partition_id: required_string!(attrs, :partition_id),
      target_id: required_string!(attrs, :target_id),
      route_id: required_string!(attrs, :route_id),
      lease_token: required_string!(attrs, :lease_token),
      encoding_hint: optional_string(attrs, :encoding_hint),
      status: "active",
      paused: false,
      quality_level: normalize_quality(Map.get(attrs, :quality_level)),
      close_reason: nil,
      pending_core_cleanup: false,
      last_sequence: 0,
      last_accepted_sequence: 0,
      sent_bytes: 0,
      received_credit_bytes: 0,
      viewer_count: 0,
      initial_credit_bytes: configured_uint(:desktop_media_initial_credit_bytes, @default_initial_credit_bytes, attrs),
      max_chunk_bytes: configured_uint(:desktop_media_max_chunk_bytes, @default_max_chunk_bytes, attrs),
      max_ack_credit_bytes: configured_uint(:desktop_media_max_ack_credit_bytes, @default_max_ack_credit_bytes, attrs),
      created_at_unix: now,
      updated_at_unix: now,
      lease_expires_at_unix: normalize_uint(Map.get(attrs, :lease_expires_at_unix, lease_expiry_unix()))
    }
  end

  defp fetch_and_verify_session(state, desktop_session_id, media_session_id) do
    case Map.get(state.sessions, desktop_session_id) do
      nil ->
        {:error, :not_found}

      %{media_session_id: ^media_session_id} = session ->
        {:ok, session}

      _session ->
        {:error, :media_session_mismatch}
    end
  end

  defp fetch_and_verify_session_with_ingest(state, desktop_session_id, media_session_id, attrs) do
    case fetch_and_verify_session(state, desktop_session_id, media_session_id) do
      {:ok, session} -> verify_optional_media_ingest(session, Map.get(attrs, :media_ingest_id))
      error -> error
    end
  end

  defp fetch_and_verify_active_session_with_ingest(state, desktop_session_id, media_session_id, attrs) do
    case fetch_and_verify_session_with_ingest(state, desktop_session_id, media_session_id, attrs) do
      {:ok, session} -> verify_active_session(session)
      error -> error
    end
  end

  defp fetch_and_verify_owned_session(state, desktop_session_id, media_session_id, agent_id) do
    case fetch_and_verify_session(state, desktop_session_id, media_session_id) do
      {:ok, %{agent_id: ^agent_id} = session} -> {:ok, session}
      {:ok, _session} -> {:error, :agent_id_mismatch}
      error -> error
    end
  end

  defp fetch_and_verify_owned_session(state, desktop_session_id, media_session_id, agent_id, attrs) do
    case fetch_and_verify_owned_session(state, desktop_session_id, media_session_id, agent_id) do
      {:ok, session} -> verify_optional_media_ingest(session, Map.get(attrs, :media_ingest_id))
      error -> error
    end
  end

  defp fetch_and_verify_active_owned_session(state, desktop_session_id, media_session_id, agent_id, attrs) do
    case fetch_and_verify_owned_session(state, desktop_session_id, media_session_id, agent_id, attrs) do
      {:ok, session} -> verify_active_session(session)
      error -> error
    end
  end

  defp verify_active_session(%{status: "active"} = session) do
    if session_expired?(session, now_unix()) do
      {:error, :session_expired}
    else
      {:ok, session}
    end
  end

  defp verify_active_session(_session), do: {:error, :session_closing}

  defp session_expired?(session, now) do
    normalize_uint(Map.get(session, :lease_expires_at_unix, 0)) <= now
  end

  defp verify_optional_media_ingest(session, media_ingest_id) do
    case optional_string(%{media_ingest_id: media_ingest_id}, :media_ingest_id) do
      "" -> {:ok, session}
      media_ingest_id when media_ingest_id == session.media_ingest_id -> {:ok, session}
      _other -> {:error, :media_ingest_mismatch}
    end
  end

  defp fetch_session_for_owner(state, desktop_session_id, agent_id) do
    case Map.get(state.sessions, desktop_session_id) do
      %{agent_id: ^agent_id} = session -> {:ok, session}
      nil -> {:error, :not_found}
      _session -> {:error, :agent_id_mismatch}
    end
  end

  defp agent_limit_exceeded?(state, session) do
    limit = max_sessions_per_agent()
    MediaSessionHelpers.agent_limit_exceeded?(state.sessions, session.agent_id, limit)
  end

  defp gateway_limit_exceeded?(state) do
    limit = max_sessions_per_gateway()
    MediaSessionHelpers.gateway_limit_exceeded?(state.sessions, limit)
  end

  defp max_sessions_per_agent do
    MediaSessionHelpers.configured_limit(:desktop_media_max_sessions_per_agent, @default_max_sessions_per_agent)
  end

  defp max_sessions_per_gateway do
    MediaSessionHelpers.configured_limit(:desktop_media_max_sessions_per_gateway, @default_max_sessions_per_gateway)
  end

  defp configured_uint(config_key, default, attrs) do
    case Map.get(attrs, config_attr(config_key)) do
      value when is_integer(value) and value > 0 ->
        value

      _other ->
        case Application.get_env(:serviceradar_agent_gateway, config_key, default) do
          value when is_integer(value) and value > 0 -> value
          _other -> default
        end
    end
  end

  defp config_attr(:desktop_media_initial_credit_bytes), do: :initial_credit_bytes
  defp config_attr(:desktop_media_max_chunk_bytes), do: :max_chunk_bytes
  defp config_attr(:desktop_media_max_ack_credit_bytes), do: :max_ack_credit_bytes

  defp emit_session_event(event, session, extra_metadata \\ %{}, measurements \\ %{}) do
    :telemetry.execute(
      [:serviceradar, :desktop_media, :session, event],
      Map.merge(
        %{
          sent_bytes: Map.get(session, :sent_bytes, 0),
          last_sequence: Map.get(session, :last_sequence, 0),
          received_credit_bytes: Map.get(session, :received_credit_bytes, 0),
          last_accepted_sequence: Map.get(session, :last_accepted_sequence, 0)
        },
        measurements
      ),
      Map.merge(
        %{
          relay_boundary: "agent_gateway",
          desktop_session_id: session.desktop_session_id,
          media_session_id: session.media_session_id,
          media_ingest_id: session.media_ingest_id,
          agent_id: session.agent_id,
          gateway_id: session.gateway_id,
          partition_id: session.partition_id,
          target_id: session.target_id,
          route_id: session.route_id,
          status: session.status,
          close_reason: Map.get(session, :close_reason)
        },
        extra_metadata
      )
    )
  end

  defp log_session(level, message, session, extra \\ %{}) do
    details =
      extra
      |> Map.merge(%{
        desktop_session_id: session.desktop_session_id,
        media_session_id: session.media_session_id,
        media_ingest_id: session.media_ingest_id,
        agent_id: session.agent_id,
        gateway_id: session.gateway_id,
        partition_id: session.partition_id,
        target_id: session.target_id,
        route_id: session.route_id,
        status: session.status,
        close_reason: Map.get(session, :close_reason)
      })
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{value}" end)

    case level do
      :warning -> Logger.warning("#{message}: #{details}")
      _other -> Logger.info("#{message}: #{details}")
    end
  end

  defp now_unix, do: System.os_time(:second)
  defp lease_expiry_unix, do: now_unix() + @default_lease_seconds

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

  defp normalize_quality(value) when is_integer(value) and value > 0, do: value
  defp normalize_quality(_value), do: 100

  defp normalize_optional_quality(value) when is_integer(value) and value > 0, do: value
  defp normalize_optional_quality(_value), do: :skip

  defp ack_credit_grant(session, attrs) do
    min(normalize_uint(Map.get(attrs, :credit_bytes, 0)), session.max_ack_credit_bytes)
  end

  defp maybe_put(session, _key, nil), do: session
  defp maybe_put(session, _key, :skip), do: session
  defp maybe_put(session, key, value), do: Map.put(session, key, value)

  defp maybe_resume(true), do: false
  defp maybe_resume(_value), do: :skip

  defp put_optional_reason(session, _key, nil), do: session

  defp put_optional_reason(session, key, value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: session, else: Map.put(session, key, trimmed)
  end

  defp put_optional_reason(session, key, value), do: Map.put(session, key, to_string(value))

  defp maybe_mark_closing_for_close_reason(%{close_reason: reason} = session) when is_binary(reason) and reason != "" do
    Map.put(session, :status, "closing")
  end

  defp maybe_mark_closing_for_close_reason(session), do: session

  defp sweep_expired_sessions(state) do
    now = now_unix()

    {expired, active} =
      Enum.split_with(state.sessions, fn {_desktop_session_id, session} ->
        stale_session?(session, now)
      end)

    Enum.each(expired, fn {_desktop_session_id, session} ->
      log_session(:info, "Gateway desktop media expired", session)
      emit_session_event(:expired, session, %{reason: expiry_reason(session, now)})
    end)

    Map.put(state, :sessions, Map.new(active))
  end

  defp stale_session?(%{pending_core_cleanup: true}, _now), do: false
  defp stale_session?(session, now), do: session_expired?(session, now) or owner_pid_dead?(session)

  defp owner_pid_dead?(%{owner_pid: owner_pid}) when is_pid(owner_pid), do: not Process.alive?(owner_pid)
  defp owner_pid_dead?(_session), do: false

  defp expiry_reason(session, now) do
    if session_expired?(session, now), do: "lease_expired", else: "owner_pid_dead"
  end

  defp schedule_sweep(:disabled), do: :ok

  defp schedule_sweep(interval_ms) do
    Process.send_after(self(), :sweep_expired_sessions, interval_ms)
    :ok
  end

  defp normalize_sweep_interval_ms(:disabled), do: :disabled
  defp normalize_sweep_interval_ms(value) when is_integer(value) and value > 0, do: value
  defp normalize_sweep_interval_ms(_value), do: @default_sweep_interval_ms
end
