defmodule ServiceRadar.EventWriter.Processors.AnomalyEpisodeRegistry do
  @moduledoc """
  Folds anomaly evaluation rows into bounded episode state.

  `platform.ocsf_events` is kept as a transition log. When the registry is
  enabled, unchanged anomaly evaluations update `platform.anomaly_episodes` and
  are withheld from the event log; opens, severity escalations, and clears still
  pass through as OCSF transition rows.

  The registry is enabled by default. `EVENT_WRITER_ANOMALY_EPISODES` is a kill
  switch: set it to `false`/`0`/`no`/`off` to disable episode folding and write
  every anomaly row through to `ocsf_events`. The `:anomaly_episodes_enabled`
  app env wins over the env var when set to a boolean.
  """

  alias ServiceRadar.Events.InternalLogPublisher

  require Logger

  @feature_flag_env "EVENT_WRITER_ANOMALY_EPISODES"
  @event_type_anomaly ["anomaly", "anomaly_detection"]
  @open_states ["anomalous", "anomaly_open", "anomaly_drift", "anomaly_drift_open", "open"]
  @clear_states [
    "anomaly_clear",
    "anomaly_drift_clear",
    "clear",
    "cleared",
    "inactive",
    "resolved",
    "closed"
  ]
  @rate_guard_table :serviceradar_anomaly_episode_rate_guard
  @tripwire_table :serviceradar_anomaly_episode_tripwire
  @default_rate_limit_per_hour 12
  @default_flood_threshold_per_minute 100
  @default_flap_window_seconds 300
  @default_producer_stale_seconds 900

  @upsert_sql """
  WITH existing AS MATERIALIZED (
    SELECT episode_uid, status, peak_severity_id, last_payload
    FROM platform.anomaly_episodes
    WHERE episode_uid = $1::text
       OR (finding_uid = $2::text AND status = 'open')
       OR (
         finding_uid = $2::text
         AND status <> 'open'
         AND last_seen_at >= $15::timestamp(6) - make_interval(secs => $23::integer)
       )
    ORDER BY
      CASE
        -- Never resurrect an exact-but-cleared row while another producer has
        -- the finding open. The edge flap window is intentionally longer than
        -- this registry's fold window, so exact-id priority created dual opens
        -- in that gap.
        WHEN status = 'open' THEN 0
        WHEN episode_uid = $1::text THEN 1
        ELSE 2
      END,
      last_seen_at DESC
    LIMIT 1
  ),
  resolved AS (
    SELECT
      COALESCE((SELECT episode_uid FROM existing), $1::text) AS episode_uid,
      COALESCE((SELECT status FROM existing), '') AS previous_status,
      COALESCE((SELECT peak_severity_id FROM existing), -1) AS previous_peak_severity_id,
      CASE jsonb_typeof((SELECT last_payload FROM existing))
        WHEN 'object' THEN (SELECT last_payload FROM existing)
        ELSE '{}'::jsonb
      END AS previous_payload
  ),
  producer_state AS (
    SELECT
      resolved.*,
      COALESCE((
        SELECT jsonb_object_agg(key, state)
        FROM jsonb_each(
          COALESCE(previous_payload #> '{episode_registry,producer_states}', '{}'::jsonb)
        ) AS producer(key, state)
        WHERE COALESCE(
            NULLIF(state ->> 'last_seen_at', '')::timestamp(6),
            '-infinity'::timestamp
          ) >= $15::timestamp(6) - make_interval(secs => $24::integer)
      ), '{}'::jsonb) ||
        jsonb_build_object(
          $22::text,
          jsonb_build_object(
            'status', CASE WHEN $9::text = 'open' THEN 'open' ELSE 'cleared' END,
            'last_seen_at', $15::timestamp(6)
          )
        ) AS producer_states
    FROM resolved
  ),
  aggregate AS (
    SELECT
      producer_state.*,
      CASE
        WHEN EXISTS (
          SELECT 1
          FROM jsonb_each(producer_states) AS producer(key, state)
          WHERE state ->> 'status' = 'open'
            AND COALESCE(
              NULLIF(state ->> 'last_seen_at', '')::timestamp(6),
              '-infinity'::timestamp
            ) >= $15::timestamp(6) - make_interval(secs => $24::integer)
        ) THEN 'open'
        ELSE 'cleared'
      END AS aggregate_status,
      jsonb_set(
        COALESCE(previous_payload, '{}'::jsonb) || COALESCE($21::jsonb, '{}'::jsonb),
        '{episode_registry}',
        COALESCE($21::jsonb -> 'episode_registry', '{}'::jsonb) ||
          jsonb_build_object('producer_states', producer_states),
        true
      ) AS payload,
      -- A clear that resolves no episode (nothing open, no exact id, nothing
      -- inside the fold window) has nothing to close. Inserting it minted a
      -- zero-length "cleared" episode for every central seasonal clear that
      -- arrived after the stale sweep had already closed the breach.
      ($9::text <> 'open' AND (SELECT episode_uid FROM existing) IS NULL) AS orphan_clear
    FROM producer_state
  ),
  upserted AS (
    INSERT INTO platform.anomaly_episodes (
      episode_uid,
      finding_uid,
      device_uid,
      series_key,
      metric_name,
      if_index,
      metric_class,
      detector,
      status,
      severity_id,
      peak_severity_id,
      effect_size,
      peak_score,
      opened_at,
      last_seen_at,
      cleared_at,
      clear_reason,
      occurrence_count,
      reopen_count,
      producer_version,
      last_transition,
      last_payload,
      inserted_at,
      updated_at
    )
    SELECT
      aggregate.episode_uid,
      $2::text,
      $3::text,
      $4::text,
      $5::text,
      $6::bigint,
      $7::text,
      $8::text,
      aggregate.aggregate_status,
      $10::bigint,
      GREATEST($10::bigint, $11::bigint),
      $12::double precision,
      $13::double precision,
      $14::timestamp(6),
      $15::timestamp(6),
      CASE WHEN aggregate.aggregate_status = 'open' THEN NULL ELSE $16::timestamp(6) END,
      CASE WHEN aggregate.aggregate_status = 'open' THEN NULL ELSE $17::text END,
      1,
      $18::bigint,
      $19::text,
      CASE
        WHEN aggregate.aggregate_status = 'open' AND $20::text = 'clear' THEN 'update'
        ELSE $20::text
      END,
      aggregate.payload,
      (now() AT TIME ZONE 'utc'),
      (now() AT TIME ZONE 'utc')
    FROM aggregate
    WHERE NOT aggregate.orphan_clear
    ON CONFLICT (episode_uid) DO UPDATE SET
      device_uid = EXCLUDED.device_uid,
      series_key = EXCLUDED.series_key,
      metric_name = COALESCE(EXCLUDED.metric_name, platform.anomaly_episodes.metric_name),
      if_index = COALESCE(EXCLUDED.if_index, platform.anomaly_episodes.if_index),
      metric_class = COALESCE(EXCLUDED.metric_class, platform.anomaly_episodes.metric_class),
      detector = CASE
        WHEN $20::text = 'clear' AND EXCLUDED.status = 'open' THEN platform.anomaly_episodes.detector
        ELSE EXCLUDED.detector
      END,
      status = EXCLUDED.status,
      severity_id = CASE
        WHEN $20::text = 'clear' AND EXCLUDED.status = 'open' THEN platform.anomaly_episodes.severity_id
        ELSE EXCLUDED.severity_id
      END,
      peak_severity_id = GREATEST(
        platform.anomaly_episodes.peak_severity_id,
        EXCLUDED.peak_severity_id,
        EXCLUDED.severity_id
      ),
      effect_size = COALESCE(EXCLUDED.effect_size, platform.anomaly_episodes.effect_size),
      peak_score = CASE
        WHEN platform.anomaly_episodes.peak_score IS NULL THEN EXCLUDED.peak_score
        WHEN EXCLUDED.peak_score IS NULL THEN platform.anomaly_episodes.peak_score
        ELSE GREATEST(platform.anomaly_episodes.peak_score, EXCLUDED.peak_score)
      END,
      opened_at = LEAST(platform.anomaly_episodes.opened_at, EXCLUDED.opened_at),
      last_seen_at = GREATEST(platform.anomaly_episodes.last_seen_at, EXCLUDED.last_seen_at),
      cleared_at = CASE
        WHEN EXCLUDED.status = 'open' THEN NULL
        ELSE COALESCE(EXCLUDED.cleared_at, EXCLUDED.last_seen_at)
      END,
      clear_reason = CASE
        WHEN EXCLUDED.status = 'open' THEN NULL
        ELSE EXCLUDED.clear_reason
      END,
      occurrence_count = platform.anomaly_episodes.occurrence_count + 1,
      reopen_count = platform.anomaly_episodes.reopen_count + CASE
        WHEN platform.anomaly_episodes.status <> 'open' AND EXCLUDED.status = 'open' THEN 1
        ELSE 0
      END,
      producer_version = COALESCE(EXCLUDED.producer_version, platform.anomaly_episodes.producer_version),
      last_transition = EXCLUDED.last_transition,
      last_payload = EXCLUDED.last_payload,
      updated_at = (now() AT TIME ZONE 'utc')
    RETURNING episode_uid, status, severity_id, peak_severity_id
  )
  SELECT
    (SELECT previous_status FROM aggregate) AS previous_status,
    (SELECT previous_peak_severity_id FROM aggregate) AS previous_peak_severity_id,
    (SELECT status FROM upserted) AS current_status,
    (SELECT severity_id FROM upserted) AS current_severity_id,
    (SELECT peak_severity_id FROM upserted) AS current_peak_severity_id,
    (SELECT episode_uid FROM upserted) AS episode_uid,
    (SELECT count(*) FROM jsonb_object_keys((SELECT producer_states FROM aggregate))) AS producer_count
  """

  @type row :: map()

  @doc """
  Returns rows that should still be written to `ocsf_events`.

  When disabled, or when the registry cannot extract a complete episode identity,
  rows pass through unchanged.
  """
  @spec transition_rows([row()], module()) :: [row()]
  def transition_rows(rows, repo \\ ServiceRadar.Repo)

  def transition_rows([], _repo), do: []

  def transition_rows(rows, repo) when is_list(rows) do
    if enabled?() do
      Enum.flat_map(rows, &transition_row(&1, repo))
    else
      rows
    end
  end

  @doc false
  def enabled? do
    app_env = Application.get_env(:serviceradar_core, :anomaly_episodes_enabled)

    cond do
      is_boolean(app_env) ->
        app_env

      is_binary(System.get_env(@feature_flag_env)) ->
        @feature_flag_env |> System.get_env() |> falsy_env?() |> Kernel.not()

      true ->
        true
    end
  end

  @doc false
  def episode_projection(row) when is_map(row) do
    if anomaly_event_row?(row) do
      row
      |> build_episode_attrs()
      |> case do
        {:ok, attrs} -> {:ok, attrs}
        :skip -> :skip
      end
    else
      :skip
    end
  end

  def episode_projection(_row), do: :skip

  @doc false
  def upsert_sql, do: @upsert_sql

  @doc false
  def reset_rate_guard!, do: delete_table_if_present(@rate_guard_table)

  @doc false
  def reset_tripwire!, do: delete_table_if_present(@tripwire_table)

  defp delete_table_if_present(table) do
    case :ets.whereis(table) do
      :undefined ->
        :ok

      tid ->
        :ets.delete(tid)
        :ok
    end
  rescue
    # Test-owned tables are deleted automatically when their owner exits. The
    # owner can terminate between whereis/1 and delete/1 during ExUnit teardown.
    ArgumentError -> :ok
  end

  defp transition_row(row, repo) do
    case episode_projection(row) do
      {:ok, attrs} ->
        case upsert_episode(repo, attrs) do
          {:ok, decision} ->
            # An orphan clear inserts nothing, so the RETURNING projection is
            # all-NULL; keep the derived identity for tripwire accounting.
            attrs = %{attrs | episode_uid: decision.episode_uid || attrs.episode_uid}
            record_tripwire(attrs)

            if (decision.producer_count || 0) > 1 do
              :telemetry.execute(
                [:serviceradar, :anomaly, :episode_registry],
                %{multi_producer_series: 1},
                %{
                  finding_uid: attrs.finding_uid,
                  series_key: attrs.series_key,
                  producer_count: decision.producer_count
                }
              )
            end

            if emit_transition?(attrs, decision) and rate_guard_allows?(attrs) do
              [stamp_transition_identity(row, attrs)]
            else
              []
            end

          {:error, reason} ->
            Logger.warning("Anomaly episode registry failed open",
              reason: inspect(reason),
              episode_uid: attrs.episode_uid
            )

            if rate_guard_allows?(attrs), do: [stamp_transition_identity(row, attrs)], else: []
        end

      :skip ->
        [row]
    end
  end

  defp anomaly_event_row?(row) when is_map(row) do
    class_uid = Map.get(row, :class_uid) || Map.get(row, "class_uid")

    class_uid == 2004 and
      row_value(row, "event_type") in @event_type_anomaly and
      row |> row_payload() |> is_map()
  end

  defp build_episode_attrs(row) do
    payload = row_payload(row)
    metadata = row_metadata(row)
    service_radar = Map.get(metadata, "service_radar") || %{}
    finding_info = Map.get(metadata, "finding_info") || %{}
    detection = Map.get(metadata, "detection_finding") || %{}
    anomaly = Map.get(payload, "anomaly") || %{}
    dimensions = Map.get(finding_info, "dimensions") || %{}

    finding_uid =
      first_non_blank([
        service_radar["finding_uid"],
        finding_info["uid"],
        payload["finding_uid"],
        anomaly["finding_uid"]
      ])

    series_key =
      first_non_blank([
        service_radar["series_key"],
        detection["series_key"],
        dimensions["series_key"],
        anomaly["series_key"],
        payload["series_key"]
      ])

    device_uid =
      first_non_blank([
        service_radar["device_uid"],
        service_radar["device_id"],
        get_in(row, [:device, "uid"]),
        get_in(row, ["device", "uid"]),
        payload["device_uid"],
        payload["device_id"]
      ])

    with finding_uid when is_binary(finding_uid) <- finding_uid,
         series_key when is_binary(series_key) <- series_key,
         device_uid when is_binary(device_uid) <- device_uid do
      transition = episode_transition(payload)
      status = if transition == "clear", do: "cleared", else: "open"
      row_time = row_time(row)
      opened_at = episode_opened_at(anomaly, dimensions, row_time)
      cleared_at = if status == "cleared", do: episode_cleared_at(anomaly, dimensions, row_time)

      {:ok,
       %{
         episode_uid: episode_uid(payload, anomaly, finding_uid, opened_at),
         finding_uid: finding_uid,
         device_uid: device_uid,
         series_key: series_key,
         metric_name:
           first_non_blank([
             service_radar["metric_name"],
             detection["metric_name"],
             dimensions["metric_name"],
             anomaly["metric_name"],
             payload["metric_name"]
           ]),
         if_index:
           [
             service_radar["if_index"],
             detection["if_index"],
             dimensions["if_index"],
             anomaly["if_index"],
             payload["if_index"]
           ]
           |> first_present()
           |> normalize_int()
           |> positive_int(),
         metric_class:
           first_non_blank([
             service_radar["metric_class"],
             detection["metric_class"],
             dimensions["metric_class"],
             anomaly["metric_class"],
             payload["metric_class"]
           ]),
         detector: episode_detector(payload, anomaly, service_radar, detection),
         status: status,
         severity_id: row_severity(row),
         peak_severity_id: row_severity(row),
         effect_size:
           [anomaly["effect_size"], payload["effect_size"]]
           |> first_present()
           |> normalize_float(),
         peak_score:
           [anomaly["peak_score"], anomaly["score"], payload["score"]]
           |> first_present()
           |> normalize_float(),
         opened_at: opened_at,
         last_seen_at: row_time,
         cleared_at: cleared_at,
         clear_reason:
           first_non_blank([
             anomaly["clear_reason"],
             payload["clear_reason"],
             anomaly["reason"],
             payload["reason"]
           ]),
         reopen_count:
           [anomaly["reopen_count"], payload["reopen_count"]]
           |> first_present()
           |> normalize_int()
           |> non_negative_int(),
         producer_version:
           first_non_blank([
             payload["producer_version"],
             anomaly["producer_version"],
             service_radar["producer_version"]
           ]),
         producer_uid: producer_uid(payload, anomaly, service_radar, finding_uid, opened_at),
         last_transition: transition,
         last_payload: payload
       }}
    else
      _ -> :skip
    end
  end

  defp episode_transition(payload) do
    anomaly = Map.get(payload, "anomaly") || %{}

    Enum.find_value(
      [
        payload["transition"],
        anomaly["transition"],
        payload["event_subtype"],
        anomaly["event_subtype"],
        anomaly["state"],
        anomaly["detector_state"],
        payload["status"]
      ],
      &normalize_transition/1
    ) ||
      "update"
  end

  defp normalize_transition(value) when is_binary(value) do
    value =
      value
      |> String.trim()
      |> String.downcase()
      |> String.replace("-", "_")

    cond do
      value in ["open", "update", "clear"] -> value
      value in @open_states -> "open"
      value in @clear_states -> "clear"
      true -> nil
    end
  end

  defp normalize_transition(_value), do: nil

  defp episode_uid(payload, anomaly, finding_uid, opened_at) do
    first_non_blank([
      payload["episode_uid"],
      anomaly["episode_uid"],
      payload["anomaly_episode_uid"],
      anomaly["anomaly_episode_uid"]
    ]) ||
      deterministic_uuid("anomaly:episode:#{finding_uid}:#{NaiveDateTime.to_iso8601(opened_at)}")
  end

  # A gateway-attested agent identity lets the canonical episode remain open
  # while another poller is still anomalous.  Legacy producers lack it, so their
  # own stable edge episode id is a safe contributor key rather than collapsing
  # unrelated old payloads into one producer.
  defp producer_uid(payload, anomaly, service_radar, finding_uid, opened_at) do
    source_identity = Map.get(payload, "source_identity") || %{}

    first_non_blank([
      source_identity["agent_id"],
      payload["producer_agent_uid"],
      anomaly["producer_agent_uid"],
      service_radar["agent_uid"]
    ]) ||
      if episode_detector(payload, anomaly, service_radar, %{}) == "central_seasonal" do
        # Central disposition has no edge-agent identity and may omit an
        # episode timestamp. Its stable finding identity is one producer, not
        # a new producer-state entry for every evaluation row.
        "central:#{finding_uid}"
      else
        "edge:#{episode_uid(payload, anomaly, finding_uid, opened_at)}"
      end
  end

  defp episode_detector(payload, anomaly, service_radar, detection) do
    verdict_source =
      first_non_blank([
        payload["verdict_source"],
        anomaly["verdict_source"],
        service_radar["verdict_source"],
        detection["source"]
      ])

    detector_method =
      first_non_blank([
        payload["detector_method"],
        anomaly["detector_method"]
      ])

    cond do
      verdict_source == "edge-drift" or detector_method == "cusum_drift" ->
        "drift"

      verdict_source == "edge-spike" or detector_method in ["rolling_z", "z_score", "zscore"] ->
        "spike"

      verdict_source in ["central", "central-seasonal", "central_seasonal"] ->
        "central_seasonal"

      true ->
        "unknown"
    end
  end

  defp upsert_episode(repo, attrs) do
    params = [
      attrs.episode_uid,
      attrs.finding_uid,
      attrs.device_uid,
      attrs.series_key,
      attrs.metric_name,
      attrs.if_index,
      attrs.metric_class,
      attrs.detector,
      attrs.status,
      attrs.severity_id,
      attrs.peak_severity_id,
      attrs.effect_size,
      attrs.peak_score,
      attrs.opened_at,
      attrs.last_seen_at,
      attrs.cleared_at,
      attrs.clear_reason,
      attrs.reopen_count,
      attrs.producer_version,
      attrs.last_transition,
      # Pass the map itself: the $21::jsonb placeholder makes Postgrex use its
      # jsonb encoder, and a pre-encoded binary here gets JSON-encoded AGAIN,
      # storing a jsonb string scalar that Ash cannot load as :map.
      attrs.last_payload,
      attrs.producer_uid,
      flap_window_seconds(),
      producer_stale_seconds()
    ]

    case repo.query(@upsert_sql, params) do
      {:ok,
       %{
         rows: [
           [
             previous_status,
             previous_peak_severity_id,
             current_status,
             current_severity_id,
             current_peak_severity_id,
             episode_uid,
             producer_count
           ]
         ]
       }} ->
        {:ok,
         %{
           previous_status: previous_status,
           previous_peak_severity_id: previous_peak_severity_id,
           current_status: current_status,
           current_severity_id: current_severity_id,
           current_peak_severity_id: current_peak_severity_id,
           episode_uid: episode_uid,
           producer_count: producer_count
         }}

      {:ok, other} ->
        {:error, {:unexpected_result, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp emit_transition?(%{last_transition: "clear"}, %{
         previous_status: "open",
         current_status: "cleared"
       }), do: true

  defp emit_transition?(%{status: "open"}, %{
         previous_status: previous_status,
         previous_peak_severity_id: previous_peak,
         current_severity_id: current_severity
       }) do
    previous_status != "open" or current_severity > previous_peak
  end

  defp emit_transition?(_attrs, _decision), do: false

  # A clear is terminal state for downstream alert machines. It must never be
  # rate-limited after the registry has persisted that transition, or it can be
  # lost permanently until stale sweeping repairs the finding.
  defp rate_guard_allows?(%{last_transition: "clear"}), do: true

  defp rate_guard_allows?(%{finding_uid: finding_uid} = attrs) do
    limit = rate_limit_per_hour()

    if limit <= 0 do
      true
    else
      table = rate_guard_table()
      bucket = div(System.system_time(:second), 3600)
      key = {finding_uid, bucket}
      count = :ets.update_counter(table, key, {2, 1}, {key, 0})

      if count <= limit do
        true
      else
        :telemetry.execute(
          [:serviceradar, :anomaly, :governor],
          %{count: 1},
          %{
            reason: :rate_limited,
            finding_uid: attrs.finding_uid,
            episode_uid: attrs.episode_uid,
            transition: attrs.last_transition,
            limit_per_hour: limit
          }
        )

        false
      end
    end
  end

  defp rate_limit_per_hour do
    configured = Application.get_env(:serviceradar_core, :anomaly_episode_rate_limit_per_hour)

    case configured do
      value when is_integer(value) and value >= 0 -> value
      _ -> @default_rate_limit_per_hour
    end
  end

  defp flap_window_seconds do
    non_negative_env(:anomaly_episode_flap_window_seconds, @default_flap_window_seconds)
  end

  defp producer_stale_seconds do
    non_negative_env(:anomaly_episode_producer_stale_seconds, @default_producer_stale_seconds)
  end

  defp non_negative_env(key, default) do
    case Application.get_env(:serviceradar_core, key) do
      value when is_integer(value) and value >= 0 -> value
      _ -> default
    end
  end

  defp rate_guard_table do
    case :ets.whereis(@rate_guard_table) do
      :undefined ->
        try do
          :ets.new(@rate_guard_table, [
            :named_table,
            :public,
            read_concurrency: true,
            write_concurrency: true
          ])
        rescue
          ArgumentError ->
            :ets.whereis(@rate_guard_table)
        end

      tid ->
        tid
    end
  end

  defp record_tripwire(attrs) do
    threshold = flood_threshold_per_minute()

    if threshold > 0 do
      table = tripwire_table()
      bucket = div(System.system_time(:second), 60)
      count = :ets.update_counter(table, {:count, bucket}, {2, 1}, {{:count, bucket}, 0})

      if count > threshold and :ets.insert_new(table, {{:fired, bucket}, true}) do
        publish_flood_event(attrs, count, threshold)
      end
    end
  end

  defp flood_threshold_per_minute do
    configured =
      Application.get_env(:serviceradar_core, :anomaly_ingest_flood_threshold_per_minute)

    case configured do
      value when is_integer(value) and value >= 0 -> value
      _ -> @default_flood_threshold_per_minute
    end
  end

  defp tripwire_table do
    case :ets.whereis(@tripwire_table) do
      :undefined ->
        try do
          :ets.new(@tripwire_table, [
            :named_table,
            :public,
            read_concurrency: true,
            write_concurrency: true
          ])
        rescue
          ArgumentError ->
            :ets.whereis(@tripwire_table)
        end

      tid ->
        tid
    end
  end

  defp publish_flood_event(attrs, count, threshold) do
    payload = %{
      severity_text: "WARN",
      body: "Anomaly ingest flood threshold exceeded",
      event: "anomaly_ingest_flood",
      status_code: "anomaly_ingest_flood",
      count_per_minute: count,
      threshold_per_minute: threshold,
      finding_uid: attrs.finding_uid,
      episode_uid: attrs.episode_uid,
      transition: attrs.last_transition,
      metric_class: attrs.metric_class,
      metric_name: attrs.metric_name
    }

    case call_tripwire_publisher("event_writer", payload) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to publish anomaly ingest flood tripwire",
          reason: inspect(reason),
          count_per_minute: count,
          threshold_per_minute: threshold
        )

        :ok
    end
  end

  defp call_tripwire_publisher(subject, payload) do
    case Application.get_env(:serviceradar_core, :anomaly_ingest_tripwire_publisher) do
      {mod, fun, extra_args} -> apply(mod, fun, [subject, payload | extra_args])
      fun when is_function(fun, 2) -> fun.(subject, payload)
      nil -> InternalLogPublisher.publish(subject, payload)
    end
  end

  defp stamp_transition_identity(row, attrs) do
    transition_id =
      deterministic_uuid(
        Enum.join(
          [
            "anomaly",
            "episode-transition",
            attrs.episode_uid,
            attrs.last_transition,
            attrs.severity_id
          ],
          ":"
        )
      )

    id = Ecto.UUID.dump!(transition_id)
    metadata = row_metadata(row)
    service_radar = Map.get(metadata, "service_radar") || %{}
    detection = Map.get(metadata, "detection_finding") || %{}

    metadata =
      metadata
      |> Map.put("event_identity", transition_id)
      |> Map.put(
        "service_radar",
        service_radar
        |> Map.put("episode_uid", attrs.episode_uid)
        |> Map.put("transition", attrs.last_transition)
        |> Map.put("producer_version", attrs.producer_version)
      )
      |> Map.put(
        "detection_finding",
        detection
        |> Map.put("episode_uid", attrs.episode_uid)
        |> Map.put("transition", attrs.last_transition)
      )

    row
    |> Map.put(:id, id)
    |> Map.put(:metadata, metadata)
  end

  defp row_metadata(row), do: Map.get(row, :metadata) || Map.get(row, "metadata") || %{}
  defp row_payload(row), do: Map.get(row, :unmapped) || Map.get(row, "unmapped") || %{}

  defp row_time(row),
    do: normalize_datetime(Map.get(row, :time) || Map.get(row, "time")) || now_naive()

  defp row_severity(row) do
    row
    |> Map.get(:severity_id, Map.get(row, "severity_id", 1))
    |> normalize_int()
    |> case do
      value when is_integer(value) and value < 0 -> 0
      value when is_integer(value) and value > 5 -> 5
      value when is_integer(value) -> value
      _ -> 1
    end
  end

  defp episode_opened_at(anomaly, dimensions, fallback) do
    [
      anomaly["episode_started_at_unix_nano"],
      dimensions["episode_started_at_unix_nano"],
      anomaly["opened_at"],
      dimensions["opened_at"]
    ]
    |> Enum.find_value(&normalize_datetime/1)
    |> Kernel.||(fallback)
  end

  defp episode_cleared_at(anomaly, dimensions, fallback) do
    [
      anomaly["episode_ended_at_unix_nano"],
      dimensions["episode_ended_at_unix_nano"],
      anomaly["cleared_at"],
      dimensions["cleared_at"]
    ]
    |> Enum.find_value(&normalize_datetime/1)
    |> Kernel.||(fallback)
  end

  defp normalize_datetime(%DateTime{} = dt) do
    dt
    |> DateTime.to_naive()
    |> NaiveDateTime.truncate(:microsecond)
  end

  defp normalize_datetime(%NaiveDateTime{} = dt), do: NaiveDateTime.truncate(dt, :microsecond)

  defp normalize_datetime(value) when is_integer(value) do
    value
    |> unix_time_unit()
    |> then(&DateTime.from_unix(value, &1))
    |> case do
      {:ok, dt} -> normalize_datetime(dt)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp normalize_datetime(value) when is_binary(value) do
    trimmed = String.trim(value)

    case Integer.parse(trimmed) do
      {int, ""} ->
        normalize_datetime(int)

      _ ->
        case DateTime.from_iso8601(trimmed) do
          {:ok, dt, _} -> normalize_datetime(dt)
          _ -> nil
        end
    end
  rescue
    _ -> nil
  end

  defp normalize_datetime(_value), do: nil

  defp now_naive do
    DateTime.utc_now()
    |> DateTime.to_naive()
    |> NaiveDateTime.truncate(:microsecond)
  end

  defp row_value(row, key) when is_map(row) and is_binary(key) do
    metadata = row_metadata(row)
    unmapped = row_payload(row)

    Map.get(metadata, key) || Map.get(unmapped, key)
  end

  defp first_non_blank(values) when is_list(values) do
    values
    |> Enum.map(&normalize_optional_string/1)
    |> Enum.find(&is_binary/1)
  end

  defp first_present(values) when is_list(values) do
    Enum.find(values, fn
      nil -> false
      value when is_binary(value) -> String.trim(value) != ""
      _ -> true
    end)
  end

  defp normalize_optional_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_optional_string(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_optional_string(value) when is_float(value), do: Float.to_string(value)
  defp normalize_optional_string(_value), do: nil

  defp normalize_int(value) when is_integer(value), do: value

  defp normalize_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp normalize_int(_value), do: nil

  defp positive_int(value) when is_integer(value) and value > 0, do: value
  defp positive_int(_value), do: nil

  defp non_negative_int(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_int(_value), do: 0

  defp normalize_float(value) when is_float(value), do: value
  defp normalize_float(value) when is_integer(value), do: value / 1

  defp normalize_float(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {float, ""} -> float
      _ -> nil
    end
  end

  defp normalize_float(_value), do: nil

  defp unix_time_unit(value) do
    value
    |> abs()
    |> case do
      unix when unix >= 100_000_000_000_000_000 -> :nanosecond
      unix when unix >= 100_000_000_000_000 -> :microsecond
      unix when unix >= 100_000_000_000 -> :millisecond
      _ -> :second
    end
  end

  defp deterministic_uuid(key) do
    <<a1::32, a2::16, a3::16, a4::16, a5::48, _rest::binary>> = :crypto.hash(:sha256, key)
    versioned_a3 = a3 |> Bitwise.band(0x0FFF) |> Bitwise.bor(0x4000)
    versioned_a4 = a4 |> Bitwise.band(0x3FFF) |> Bitwise.bor(0x8000)

    "~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b"
    |> :io_lib.format([a1, a2, versioned_a3, versioned_a4, a5])
    |> IO.iodata_to_binary()
  end

  defp falsy_env?(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> Kernel.in(["0", "false", "no", "off"])
  end

  defp falsy_env?(_value), do: false
end
