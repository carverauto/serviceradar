defmodule ServiceRadarAgentGateway.CameraMediaSessionTracker do
  @moduledoc """
  Tracks active camera media relay sessions at the gateway boundary.

  This is intentionally lightweight for the initial media path: the gateway
  authenticates edge sessions, tracks lease/activity, and forwards media
  onward. It does not own fan-out or transcoding.
  """

  use GenServer

  alias ServiceRadar.Telemetry

  require Logger

  @default_lease_seconds 30

  @type session :: %{
          relay_session_id: String.t(),
          media_ingest_id: String.t(),
          agent_id: String.t(),
          gateway_id: String.t(),
          partition_id: String.t(),
          camera_source_id: String.t(),
          stream_profile_id: String.t(),
          codec_hint: String.t(),
          container_hint: String.t(),
          lease_token: String.t(),
          status: String.t(),
          close_reason: String.t() | nil,
          last_sequence: non_neg_integer(),
          sent_bytes: non_neg_integer(),
          created_at_unix: integer(),
          updated_at_unix: integer(),
          lease_expires_at_unix: integer()
        }

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

  def mark_closing(relay_session_id, media_ingest_id, attrs \\ %{}) do
    GenServer.call(__MODULE__, {:mark_closing, relay_session_id, media_ingest_id, attrs})
  end

  def close_session(relay_session_id, media_ingest_id, attrs \\ %{}) do
    GenServer.call(__MODULE__, {:close_session, relay_session_id, media_ingest_id, attrs})
  end

  def fetch_session(relay_session_id) do
    GenServer.call(__MODULE__, {:fetch_session, relay_session_id})
  end

  @impl true
  def init(_opts) do
    {:ok, %{sessions: %{}}}
  end

  @impl true
  def handle_call({:open_session, attrs}, _from, state) do
    session = build_session(attrs)
    log_session(:info, "Gateway camera relay opened", session)
    emit_session_event(:opened, session)

    {:reply, {:ok, session}, put_in(state, [:sessions, session.relay_session_id], session)}
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

        {:reply, {:ok, updated}, put_in(state, [:sessions, relay_session_id], updated)}

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

        {:reply, {:ok, updated}, put_in(state, [:sessions, relay_session_id], updated)}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:mark_closing, relay_session_id, media_ingest_id, attrs}, _from, state) do
    case fetch_and_verify_session(state, relay_session_id, media_ingest_id) do
      {:ok, session} ->
        updated =
          session
          |> Map.put(:status, "closing")
          |> Map.put(:updated_at_unix, now_unix())
          |> put_optional_reason(:close_reason, Map.get(attrs, :reason) || Map.get(attrs, :close_reason))

        log_session(:info, "Gateway camera relay closing", updated)
        emit_session_event(:closing, updated)
        {:reply, {:ok, updated}, put_in(state, [:sessions, relay_session_id], updated)}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:close_session, relay_session_id, media_ingest_id, _attrs}, _from, state) do
    case fetch_and_verify_session(state, relay_session_id, media_ingest_id) do
      {:ok, session} ->
        log_session(:info, "Gateway camera relay closed", session)
        emit_session_event(:closed, session)
        {:reply, :ok, update_in(state, [:sessions], &Map.delete(&1, relay_session_id))}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:fetch_session, relay_session_id}, _from, state) do
    {:reply, Map.get(state.sessions, relay_session_id), state}
  end

  defp build_session(attrs) do
    relay_session_id = required_string!(attrs, :relay_session_id)
    media_ingest_id = optional_string(attrs, :media_ingest_id)
    now = now_unix()

    %{
      relay_session_id: relay_session_id,
      media_ingest_id: if(media_ingest_id == "", do: random_id("media"), else: media_ingest_id),
      agent_id: required_string!(attrs, :agent_id),
      gateway_id: required_string!(attrs, :gateway_id),
      partition_id: required_string!(attrs, :partition_id),
      camera_source_id: required_string!(attrs, :camera_source_id),
      stream_profile_id: required_string!(attrs, :stream_profile_id),
      codec_hint: optional_string(attrs, :codec_hint),
      container_hint: optional_string(attrs, :container_hint),
      lease_token: required_string!(attrs, :lease_token),
      status: "active",
      close_reason: nil,
      last_sequence: 0,
      sent_bytes: 0,
      created_at_unix: now,
      updated_at_unix: now,
      lease_expires_at_unix: normalize_uint(Map.get(attrs, :lease_expires_at_unix, lease_expiry_unix()))
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

  defp put_optional_reason(session, _key, nil), do: session

  defp put_optional_reason(session, key, value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: session, else: Map.put(session, key, trimmed)
  end

  defp put_optional_reason(session, key, value), do: Map.put(session, key, to_string(value))

  defp emit_session_event(event, session, extra_metadata \\ %{}, measurements \\ %{}) do
    Telemetry.emit_camera_relay_session_event(
      event,
      Map.merge(
        %{
          relay_boundary: "agent_gateway",
          relay_session_id: session.relay_session_id,
          media_ingest_id: session.media_ingest_id,
          agent_id: session.agent_id,
          gateway_id: session.gateway_id,
          partition_id: session.partition_id,
          camera_source_id: session.camera_source_id,
          stream_profile_id: session.stream_profile_id,
          relay_status: session.status,
          close_reason: Map.get(session, :close_reason)
        },
        extra_metadata
      ),
      Map.merge(
        %{
          sent_bytes: Map.get(session, :sent_bytes, 0),
          last_sequence: Map.get(session, :last_sequence, 0)
        },
        measurements
      )
    )
  end

  defp log_session(level, message, session, extra \\ %{}) do
    details =
      extra
      |> Map.merge(%{
        relay_session_id: session.relay_session_id,
        media_ingest_id: session.media_ingest_id,
        agent_id: session.agent_id,
        gateway_id: session.gateway_id,
        partition_id: session.partition_id,
        camera_source_id: session.camera_source_id,
        stream_profile_id: session.stream_profile_id,
        status: session.status,
        close_reason: Map.get(session, :close_reason)
      })
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{value}" end)

    case level do
      :warning -> Logger.warning("#{message}: #{details}")
      _ -> Logger.info("#{message}: #{details}")
    end
  end

  defp normalize_uint(value) when is_integer(value) and value >= 0, do: value
  defp normalize_uint(_value), do: 0
end
