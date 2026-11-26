defmodule ServiceRadar.Camera.VantageWorkerHeartbeat do
  @moduledoc """
  NATS consumer and pure validator for `vantage.heartbeat.v1` worker
  registrations on `media.workers.heartbeat.v1`.

  Workers publish ephemeral capability heartbeats on core NATS; this module
  validates every envelope field and upserts `VantageWorkerRegistration` with
  a bounded `expires_at` TTL (`30s` default) without exposing CNPG or
  object-store credentials to workers.
  """

  use GenServer

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.VantagePubSub
  alias ServiceRadar.Camera.VantageWorkerRegistration

  require Logger

  @subject "media.workers.heartbeat.v1"
  @queue_group "serviceradar-vantage-worker-heartbeat"
  @connection_name :serviceradar_nats
  @default_ttl_us 30_000_000
  @max_payload_bytes 16_384
  @resubscribe_ms 5_000

  @capability_regex ~r/\A[a-z0-9][a-z0-9._-]*\z/
  @allowed_worker_kinds %{
    "camera_vlm" => :camera_vlm,
    "external_rust" => :external_rust,
    "external_python" => :external_python
  }
  @allowed_health_states %{
    "ready" => :ready,
    "degraded" => :degraded,
    "draining" => :draining,
    "unhealthy" => :unhealthy
  }
  @allowed_source_modes ["recorded_block", "live_keyframe_tap"]
  @allowed_backends ["onnx", "candle", "vlm", "custom"]
  @allowed_architectures ["arm64", "amd64"]

  @system_actor SystemActor.system(:camera_vantage_worker_heartbeat)

  @doc "Core NATS subject carrying worker capability heartbeats."
  @spec subject() :: String.t()
  def subject, do: @subject

  @doc "Default heartbeat registration TTL in microseconds (`30_000_000`)."
  @spec default_ttl_us() :: pos_integer()
  def default_ttl_us, do: @default_ttl_us

  @doc """
  Starts the supervised `VantageWorkerHeartbeat` subscriber.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Validates and ingests a `vantage.heartbeat.v1` payload (binary JSON or map),
  upserting the corresponding `VantageWorkerRegistration` record with a bounded
  `expires_at` TTL.

  Supports `:upsert_fn`, `:now`, `:ttl_us`, and `:broadcast?` options for
  deterministic unit testing without CNPG or NATS.
  """
  @spec ingest_heartbeat(binary() | map(), keyword()) ::
          {:ok, VantageWorkerRegistration.t() | map()} | {:error, term()}
  def ingest_heartbeat(payload, opts \\ [])

  def ingest_heartbeat(raw, opts) when is_binary(raw) and is_list(opts) do
    if byte_size(raw) > @max_payload_bytes do
      {:error, :heartbeat_too_large}
    else
      case Jason.decode(raw) do
        {:ok, %{} = map} -> ingest_heartbeat(map, opts)
        {:ok, _} -> {:error, :invalid_heartbeat_payload}
        {:error, _} -> {:error, :invalid_json}
      end
    end
  end

  def ingest_heartbeat(%{} = payload, opts) when is_list(opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    ttl_us = validate_ttl(Keyword.get(opts, :ttl_us, @default_ttl_us))

    with {:ok, attrs} <- validate_and_build_attrs(payload, now, ttl_us),
         {:ok, record} <- persist_registration(attrs, opts) do
      if Keyword.get(opts, :broadcast?, true) do
        VantagePubSub.broadcast_worker_health(%{
          worker_id: attrs.worker_id,
          worker_kind: attrs.worker_kind,
          capabilities: attrs.capabilities,
          health: attrs.health,
          active_jobs: attrs.active_jobs,
          max_concurrency: attrs.max_concurrency,
          expires_at: attrs.expires_at
        })
      end

      {:ok, record}
    end
  end

  def ingest_heartbeat(_, _), do: {:error, :invalid_heartbeat_payload}

  # ---------------------------------------------------------------------------
  # GenServer lifecycle & NATS subscription
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    connection_name = Keyword.get(opts, :connection_name, @connection_name)
    send(self(), :ensure_subscription)
    {:ok, %{connection_name: connection_name, subscription: nil, monitor_ref: nil}}
  end

  @impl true
  def handle_info(:ensure_subscription, state) do
    next_state = ensure_subscribed(state)
    Process.send_after(self(), :ensure_subscription, @resubscribe_ms)
    {:noreply, next_state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor_ref: ref} = state) do
    {:noreply, %{state | subscription: nil, monitor_ref: nil}}
  end

  def handle_info({:msg, %{topic: @subject, body: body}}, state) do
    case ingest_heartbeat(body) do
      {:ok, _record} ->
        :ok

      {:error, reason} ->
        Logger.warning("Rejected invalid Vantage worker heartbeat", reason: inspect(reason))
    end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp ensure_subscribed(%{subscription: {pid, _sid}} = state) when is_pid(pid) do
    if Process.alive?(pid) do
      state
    else
      ensure_subscribed(%{state | subscription: nil, monitor_ref: nil})
    end
  end

  defp ensure_subscribed(state) do
    case Process.whereis(state.connection_name) do
      pid when is_pid(pid) ->
        ref = Process.monitor(pid)

        case Gnat.sub(pid, self(), @subject, queue_group: @queue_group) do
          {:ok, sid} ->
            %{state | subscription: {pid, sid}, monitor_ref: ref}

          {:error, reason} ->
            Process.demonitor(ref, [:flush])

            Logger.debug("Vantage worker heartbeat subscription pending",
              reason: inspect(reason)
            )

            %{state | subscription: nil, monitor_ref: nil}
        end

      nil ->
        %{state | subscription: nil, monitor_ref: nil}
    end
  catch
    :exit, _ -> %{state | subscription: nil, monitor_ref: nil}
  end

  # ---------------------------------------------------------------------------
  # Validation & Persistence
  # ---------------------------------------------------------------------------

  defp validate_and_build_attrs(payload, now, ttl_us) do
    with :ok <-
           require_exact(
             fetch_val(payload, :schema_version),
             "vantage.heartbeat.v1",
             :invalid_schema_version
           ),
         :ok <-
           require_exact(
             fetch_val(payload, :protocol_version),
             "vantage.worker.v1",
             :invalid_protocol_version
           ),
         {:ok, worker_id} <-
           require_string(fetch_val(payload, :worker_id), 128, :invalid_worker_id),
         {:ok, worker_kind} <-
           require_mapped_enum(
             fetch_val(payload, :worker_kind),
             @allowed_worker_kinds,
             :invalid_worker_kind
           ),
         {:ok, capabilities} <- validate_capabilities(fetch_val(payload, :capabilities)),
         {:ok, source_modes} <- validate_source_modes(fetch_val(payload, :supported_source_modes)),
         {:ok, execution_backend} <-
           require_enum_string(
             fetch_val(payload, :execution_backend),
             @allowed_backends,
             :invalid_execution_backend
           ),
         {:ok, architecture} <-
           require_enum_string(
             fetch_val(payload, :architecture),
             @allowed_architectures,
             :invalid_architecture
           ),
         {:ok, model_id} <- require_string(fetch_val(payload, :model_id), 128, :invalid_model_id),
         {:ok, model_version} <-
           require_string(fetch_val(payload, :model_version), 64, :invalid_model_version),
         {:ok, max_concurrency} <-
           require_int_range(
             fetch_val(payload, :max_concurrency),
             1,
             1024,
             :invalid_max_concurrency
           ),
         {:ok, active_jobs} <-
           require_int_range(
             fetch_val(payload, :active_jobs),
             0,
             max_concurrency,
             :invalid_active_jobs
           ),
         {:ok, health} <-
           require_mapped_enum(
             fetch_val(payload, :health),
             @allowed_health_states,
             :invalid_health
           ),
         {:ok, sent_at_us} <-
           require_int_min(fetch_val(payload, :sent_at_us), 0, :invalid_sent_at_us) do
      metadata =
        payload
        |> fetch_val(:metadata)
        |> ensure_map()
        |> Map.put("sent_at_us", sent_at_us)

      expires_at = DateTime.add(now, ttl_us, :microsecond)

      {:ok,
       %{
         worker_id: worker_id,
         worker_kind: worker_kind,
         protocol_version: "vantage.worker.v1",
         capabilities: capabilities,
         supported_source_modes: source_modes,
         execution_backend: execution_backend,
         architecture: architecture,
         model_id: model_id,
         model_version: model_version,
         max_concurrency: max_concurrency,
         active_jobs: active_jobs,
         health: health,
         metadata: metadata,
         last_heartbeat_at: now,
         expires_at: expires_at
       }}
    end
  end

  defp persist_registration(attrs, opts) do
    case Keyword.get(opts, :upsert_fn) do
      fun when is_function(fun, 1) ->
        fun.(attrs)

      _ ->
        VantageWorkerRegistration
        |> Ash.Changeset.for_create(:upsert_heartbeat, attrs, actor: @system_actor)
        |> Ash.create(actor: @system_actor)
    end
  end

  defp validate_ttl(ttl) when is_integer(ttl) and ttl >= 1_000_000 and ttl <= 300_000_000, do: ttl

  defp validate_ttl(_), do: @default_ttl_us

  defp require_exact(val, expected, error) when is_binary(val) do
    if val == expected, do: :ok, else: {:error, error}
  end

  defp require_exact(_, _, error), do: {:error, error}

  defp require_string(val, max_len, error) when is_binary(val) do
    trimmed = String.trim(val)

    if trimmed != "" and String.length(trimmed) <= max_len do
      {:ok, trimmed}
    else
      {:error, error}
    end
  end

  defp require_string(_, _, error), do: {:error, error}

  defp require_mapped_enum(val, mapping, error) when is_atom(val) do
    require_mapped_enum(Atom.to_string(val), mapping, error)
  end

  defp require_mapped_enum(val, mapping, error) when is_binary(val) do
    case Map.fetch(mapping, val) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, error}
    end
  end

  defp require_mapped_enum(_, _, error), do: {:error, error}

  defp require_enum_string(val, allowed, error) when is_binary(val) do
    if val in allowed, do: {:ok, val}, else: {:error, error}
  end

  defp require_enum_string(_, _, error), do: {:error, error}

  defp validate_capabilities(caps) when is_list(caps) and caps != [] do
    normalized =
      Enum.reduce_while(caps, [], fn
        cap, acc when is_binary(cap) ->
          trimmed = String.trim(cap)

          if trimmed != "" and byte_size(trimmed) <= 128 and
               Regex.match?(@capability_regex, trimmed) do
            {:cont, [trimmed | acc]}
          else
            {:halt, :error}
          end

        _, _acc ->
          {:halt, :error}
      end)

    case normalized do
      :error -> {:error, :invalid_capabilities}
      list -> {:ok, list |> Enum.reverse() |> Enum.uniq()}
    end
  end

  defp validate_capabilities(_), do: {:error, :invalid_capabilities}

  defp validate_source_modes(modes) when is_list(modes) and modes != [] do
    normalized =
      Enum.reduce_while(modes, [], fn mode, acc ->
        s = if is_atom(mode), do: Atom.to_string(mode), else: mode

        if is_binary(s) and s in @allowed_source_modes do
          {:cont, [s | acc]}
        else
          {:halt, :error}
        end
      end)

    case normalized do
      :error -> {:error, :invalid_supported_source_modes}
      list -> {:ok, list |> Enum.reverse() |> Enum.uniq()}
    end
  end

  defp validate_source_modes(_), do: {:error, :invalid_supported_source_modes}

  defp require_int_range(val, min_v, max_v, _error)
       when is_integer(val) and val >= min_v and val <= max_v, do: {:ok, val}

  defp require_int_range(_, _, _, error), do: {:error, error}

  defp require_int_min(val, min_v, _error) when is_integer(val) and val >= min_v, do: {:ok, val}
  defp require_int_min(_, _, error), do: {:error, error}

  defp ensure_map(val) when is_map(val), do: val
  defp ensure_map(_), do: %{}

  defp fetch_val(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, val} -> val
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
