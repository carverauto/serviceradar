defmodule ServiceRadarNVR.Config do
  @moduledoc "Boot-time resource envelope. Storage is opened read-only on each admission."

  # A block's publication intent embeds one descriptor entry (at most 232 bytes)
  # per fragment and is capped at 64 KiB, so 256 fragments always fit. Reads use
  # this ceiling too, so a block written under any accepted value stays readable
  # after the setting is lowered.
  @block_fragments_ceiling 256
  # A flat volume root is listed whole; beyond this a sharded layout is needed.
  @max_blocks_ceiling 262_144
  @keyframe_limit_min_ms 1_000
  @keyframe_limit_max_ms 60_000

  defstruct [
    :root,
    :storage_id,
    :max_sessions,
    :max_duration_ms,
    :max_block_fragments,
    :max_keyframe_interval_ms,
    :max_keyframe_wait_ms,
    :max_blocks,
    :health_port,
    :max_spool_bytes,
    :reserve_bytes,
    :recovery_gate,
    :delivery,
    :ingest,
    :read,
    :analysis_read,
    :playback_read_slots,
    :analysis_read_slots,
    :auto_delivery
  ]

  def load(env) do
    with {:ok, port} <- integer(env, "SERVICERADAR_NVR_HEALTH_PORT", 8095, 65_535),
         {:ok, sessions} <- integer(env, "SERVICERADAR_NVR_MAX_SESSIONS", 1, 16),
         {:ok, duration} <- integer(env, "SERVICERADAR_NVR_MAX_DURATION_MS", 30_000, 300_000),
         {:ok, fragments} <- integer(env, "SERVICERADAR_NVR_MAX_BLOCK_FRAGMENTS", 150, 8, @block_fragments_ceiling),
         {:ok, max_keyframe_interval_ms} <-
           integer(
             env,
             "SERVICERADAR_NVR_MAX_KEYFRAME_INTERVAL_MS",
             15_000,
             @keyframe_limit_min_ms,
             @keyframe_limit_max_ms
           ),
         {:ok, max_keyframe_wait_ms} <-
           integer(
             env,
             "SERVICERADAR_NVR_MAX_KEYFRAME_WAIT_MS",
             35_000,
             @keyframe_limit_min_ms,
             @keyframe_limit_max_ms
           ),
         {:ok, max_blocks} <- integer(env, "SERVICERADAR_NVR_MAX_BLOCKS", 131_072, @max_blocks_ceiling),
         {:ok, spool} <- integer(env, "SERVICERADAR_NVR_MAX_SPOOL_BYTES", 1_073_741_824, 1_099_511_627_776),
         {:ok, reserve} <- integer(env, "SERVICERADAR_NVR_RESERVE_BYTES", 67_108_864, 1_125_899_906_842_624),
         {:ok, root, id} <- storage(env),
         {:ok, recovery_gate} <- ServiceRadarRecordingControl.RecoveryGate.load(env, root),
         {:ok, delivery} <- ServiceRadarNVR.DeliveryConfig.load(env),
         {:ok, ingest} <- ServiceRadarNVR.IngestListener.load(env),
         {:ok, read} <- ServiceRadarNVR.ReadListener.load(env),
         {:ok, analysis_read} <- ServiceRadarNVR.AnalysisReadListener.load(env),
         :ok <- distinct_listeners(ingest, read, :invalid_nvr_read_config),
         :ok <- distinct_listeners(ingest, analysis_read, :invalid_nvr_analysis_read_config),
         :ok <- distinct_listeners(read, analysis_read, :invalid_nvr_analysis_read_config),
         {:ok, playback_read_slots} <- integer(env, "SERVICERADAR_NVR_PLAYBACK_READ_SLOTS", 8, 64),
         {:ok, analysis_read_slots} <- integer(env, "SERVICERADAR_NVR_ANALYSIS_READ_SLOTS", 4, 64),
         {:ok, auto_delivery} <- auto_delivery(env, root, delivery) do
      config = %__MODULE__{
        root: root,
        storage_id: id,
        max_sessions: sessions,
        max_duration_ms: duration,
        max_block_fragments: fragments,
        max_keyframe_interval_ms: max_keyframe_interval_ms,
        max_keyframe_wait_ms: max_keyframe_wait_ms,
        max_blocks: max_blocks,
        health_port: port,
        max_spool_bytes: spool,
        reserve_bytes: reserve,
        recovery_gate: recovery_gate,
        delivery: delivery,
        ingest: ingest,
        read: read,
        analysis_read: analysis_read,
        playback_read_slots: playback_read_slots,
        analysis_read_slots: analysis_read_slots,
        auto_delivery: auto_delivery
      }

      {:ok, config}
    end
  end

  @doc "Largest accepted `SERVICERADAR_NVR_MAX_BLOCK_FRAGMENTS`, so also the fragment bound for reading a retained block."
  def block_fragments_ceiling, do: @block_fragments_ceiling

  # Each listener is a separate trust boundary: ingest, playback read, and
  # media-worker analysis read must never share a port, client pin, or token.
  defp distinct_listeners(%{} = first, %{} = second, error) do
    if first.port != second.port and first.client_sha256 != second.client_sha256 and
         first.token_sha256 != second.token_sha256,
       do: :ok,
       else: {:error, error}
  end

  defp distinct_listeners(_first, _second, _error), do: :ok

  defp auto_delivery(env, root, delivery) do
    case Map.get(env, "SERVICERADAR_NVR_PUBLICATION_AUTO_DELIVERY", "false") do
      "false" -> {:ok, false}
      "true" when not is_nil(root) and not is_nil(delivery) -> {:ok, true}
      _ -> {:error, :invalid_nvr_auto_delivery_config}
    end
  end

  defp integer(env, key, default, ceiling), do: integer(env, key, default, 1, ceiling)

  defp integer(env, key, default, minimum, ceiling) do
    case Integer.parse(Map.get(env, key, Integer.to_string(default))) do
      {n, ""} when n >= minimum and n <= ceiling -> {:ok, n}
      _ -> {:error, {:invalid_nvr_limit, key}}
    end
  end

  defp storage(env) do
    with {:ok, id} <- storage_id(env) do
      storage_root(Map.get(env, "SERVICERADAR_NVR_SPOOL_ROOT"), id)
    end
  end

  defp storage_id(%{"SERVICERADAR_NVR_STORAGE_IDS" => ids} = env) do
    with false <- Map.has_key?(env, "SERVICERADAR_NVR_STORAGE_ID"),
         {:ok, members} when is_map(members) <- Jason.decode(ids),
         {:ok, id} when is_binary(id) <- Map.fetch(members, Map.get(env, "SERVICERADAR_NVR_MEMBER_NAME")) do
      {:ok, id}
    else
      _ -> {:error, :invalid_nvr_storage_member}
    end
  end

  defp storage_id(env), do: {:ok, Map.get(env, "SERVICERADAR_NVR_STORAGE_ID")}

  defp storage_root(root, id) do
    case {root, id} do
      {nil, nil} ->
        {:ok, nil, nil}

      {root, id} when is_binary(root) and is_binary(id) ->
        with true <- Path.type(root) == :absolute and root != "/",
             {:ok, canonical} <- Ecto.UUID.cast(id),
             true <- canonical == id do
          {:ok, root, id}
        else
          _ -> {:error, :invalid_nvr_storage}
        end

      _ ->
        {:error, :invalid_nvr_storage}
    end
  end
end
