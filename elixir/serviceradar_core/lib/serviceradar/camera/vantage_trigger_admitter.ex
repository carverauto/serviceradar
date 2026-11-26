defmodule ServiceRadar.Camera.VantageTriggerAdmitter do
  @moduledoc """
  Evaluates enabled `ServiceRadar.Camera.VantagePipeline` definitions for
  Stage 1 detections (`:on_stage1_detection`) and sealed recording blocks
  (`:on_sealed_block`), admitting idempotent CNPG outbox jobs in
  `platform.camera_vantage_jobs` within per-pipeline rate and track budgets.

  When `SERVICERADAR_VANTAGE_PIPELINES_ENABLED` is not `"true"`, admission
  returns `{:ok, []}` immediately with zero database reads.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.RecordingCatalogEntry
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Camera.VantageJob
  alias ServiceRadar.Camera.VantagePipeline
  alias ServiceRadar.Camera.VantagePipelineDispatcher
  alias ServiceRadar.Inventory.Device

  require Ash.Query
  require Logger

  @vlm_subject "media.jobs.vantage.vlm.v1"
  @default_deadline_ms 30_000
  @max_sealed_block_fragments 8
  @system_actor SystemActor.system(:camera_vantage_trigger_admitter)

  @doc """
  Returns `true` when Vantage ML pipeline admission and ingestion are enabled.
  """
  @spec deployment_enabled?((String.t(), String.t() -> String.t() | nil)) :: boolean()
  def deployment_enabled?(fetch \\ &System.get_env/2) when is_function(fetch, 2) do
    fetch.("SERVICERADAR_VANTAGE_PIPELINES_ENABLED", "false") == "true"
  end

  @doc """
  Normalizes a capability string (e.g. `"vantage.alpr.v1"`) into a NATS
  subject token slug (`"vantage_alpr_v1"`).
  """
  @spec capability_slug(String.t()) :: String.t()
  def capability_slug(capability) when is_binary(capability) do
    capability
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  @doc """
  Builds the JetStream job subject for a runner/capability target.
  """
  @spec job_subject(atom(), String.t() | nil, :live | :backfill) :: String.t()
  def job_subject(:camera_vlm, _capability, :live), do: @vlm_subject
  def job_subject(:camera_vlm, _capability, :backfill), do: "media.jobs.vantage.vlm.backfill.v1"

  def job_subject(:external_worker, capability, kind) when kind in [:live, :backfill] do
    if valid_external_capability?(capability) do
      slug = capability_slug(capability)

      case kind do
        :live -> "media.jobs.vantage.#{slug}.v1"
        :backfill -> "media.jobs.vantage.#{slug}.backfill.v1"
      end
    else
      raise ArgumentError, "invalid external_worker capability: #{inspect(capability)}"
    end
  end

  def job_subject(_runner, _capability, job_kind), do: job_subject(:camera_vlm, nil, job_kind)

  @doc """
  Evaluates `:on_stage1_detection` pipelines for a playable `RecordingCatalogEntry`
  and its projected Stage 1 `frames` (carrying transient `:vantage_detections` or
  `:detections`).
  """
  @spec admit_for_stage1_detections(RecordingCatalogEntry.t(), [map()], keyword()) ::
          {:ok, [VantageJob.t() | map()]} | {:error, term()}
  def admit_for_stage1_detections(%RecordingCatalogEntry{} = entry, frames, opts \\ [])
      when is_list(frames) and is_list(opts) do
    if enabled?(opts) and RecordingCatalogEntry.playable?(entry) and frames != [] do
      do_admit_stage1(entry, frames, opts)
    else
      {:ok, []}
    end
  end

  @doc """
  Evaluates `:on_sealed_block` pipelines for a newly sealed playable
  `RecordingCatalogEntry` and its descriptor map.
  """
  @spec admit_for_sealed_block(RecordingCatalogEntry.t(), map() | nil, keyword()) ::
          {:ok, [VantageJob.t() | map()]} | {:error, term()}
  def admit_for_sealed_block(%RecordingCatalogEntry{} = entry, descriptor, opts \\ [])
      when is_list(opts) do
    fragments = if is_map(descriptor), do: fetch_val(descriptor, :fragments)

    if enabled?(opts) and RecordingCatalogEntry.playable?(entry) and is_list(fragments) and
         fragments != [] do
      do_admit_sealed_block(entry, descriptor, opts)
    else
      {:ok, []}
    end
  end

  defp enabled?(opts) do
    case Keyword.fetch(opts, :enabled?) do
      {:ok, val} -> val == true
      :error -> deployment_enabled?(Keyword.get(opts, :env_fetch, &System.get_env/2))
    end
  end

  defp do_admit_stage1(entry, frames, opts) do
    with {:ok, pipelines} <- load_pipelines(:on_stage1_detection, opts) do
      if pipelines == [] do
        {:ok, []}
      else
        now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
        source = load_source(entry.camera_source_id, opts)
        device = maybe_load_device(source, pipelines, opts)

        admitted_result =
          Enum.reduce_while(pipelines, {:ok, []}, fn pipeline, {:ok, acc} ->
            case admit_stage1_pipeline(pipeline, entry, frames, source, device, now, opts) do
              {:ok, jobs} -> {:cont, {:ok, acc ++ jobs}}
              {:error, _} = err -> {:halt, err}
            end
          end)

        with {:ok, admitted} <- admitted_result do
          maybe_nudge_dispatch(admitted, opts)
          {:ok, admitted}
        end
      end
    end
  end

  defp do_admit_sealed_block(entry, descriptor, opts) do
    with {:ok, pipelines} <- load_pipelines(:on_sealed_block, opts) do
      if pipelines == [] do
        {:ok, []}
      else
        now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
        source = load_source(entry.camera_source_id, opts)
        device = maybe_load_device(source, pipelines, opts)

        admitted_result =
          Enum.reduce_while(pipelines, {:ok, []}, fn pipeline, {:ok, acc} ->
            case admit_sealed_pipeline(pipeline, entry, descriptor, source, device, now, opts) do
              {:ok, jobs} -> {:cont, {:ok, acc ++ jobs}}
              {:error, _} = err -> {:halt, err}
            end
          end)

        with {:ok, admitted} <- admitted_result do
          maybe_nudge_dispatch(admitted, opts)
          {:ok, admitted}
        end
      end
    end
  end

  defp maybe_nudge_dispatch([], _opts), do: :ok

  defp maybe_nudge_dispatch(_admitted, opts) do
    if Keyword.get(opts, :nudge_dispatch?, true) do
      VantagePipelineDispatcher.nudge_dispatch(opts)
    else
      :ok
    end
  end

  defp admit_stage1_pipeline(pipeline, entry, frames, source, device, now, opts) do
    if matches_camera_selector?(pipeline, entry, source, device) do
      candidates = collect_matching_detections(pipeline, entry, frames, source)

      groups =
        candidates
        |> group_detections_for_pipeline(pipeline)
        |> apply_rate_budget(pipeline, now, opts)

      enqueue_groups(pipeline, entry, groups, now, opts)
    else
      {:ok, []}
    end
  end

  defp admit_sealed_pipeline(pipeline, entry, descriptor, source, device, now, opts) do
    if matches_camera_selector?(pipeline, entry, source, device) do
      case extract_sealed_block_targets(entry, descriptor, pipeline) do
        [] ->
          {:ok, []}

        sampled_targets ->
          groups = apply_rate_budget([{"block", sampled_targets}], pipeline, now, opts)
          enqueue_groups(pipeline, entry, groups, now, opts)
      end
    else
      {:ok, []}
    end
  end

  defp collect_matching_detections(pipeline, entry, frames, source) when is_list(frames) do
    roi_polygons = normalize_polygons(Map.get(pipeline, :roi_polygons))
    roi_grid = extract_source_roi_grid(source)
    allowed_classes = normalize_classes(Map.get(pipeline, :object_classes))

    min_conf =
      case Map.get(pipeline, :min_confidence) do
        n when is_number(n) -> n
        _ -> 0.0
      end

    for frame <- frames,
        is_map(frame),
        frag_seq = fetch_val(frame, :fragment_sequence),
        media_pts_ns = fetch_val(frame, :media_pts_ns),
        timeline_ts_us = compute_timeline_ts_us(entry, media_pts_ns),
        detections = extract_frame_detections(frame),
        {det, idx} <- Enum.with_index(detections),
        normalized = normalize_detection(det, frag_seq, media_pts_ns, timeline_ts_us, idx),
        normalized != nil,
        matches_class?(allowed_classes, normalized.object_class),
        normalized.confidence >= min_conf,
        matches_roi?(normalized.bbox, roi_polygons, roi_grid) do
      normalized
    end
  end

  defp extract_frame_detections(frame) do
    case fetch_val(frame, :vantage_detections) do
      list when is_list(list) ->
        list

      nil ->
        case fetch_val(frame, :detections) do
          list when is_list(list) -> list
          _ -> []
        end

      _ ->
        []
    end
  end

  defp normalize_detection(det, frag_seq, media_pts_ns, timeline_ts_us, idx) when is_map(det) do
    object_class = fetch_val(det, :object_class)
    confidence = fetch_val(det, :confidence)
    bbox = normalize_bbox(fetch_val(det, :bbox))
    track_id = normalize_track_id(fetch_val(det, :track_id))

    if is_binary(object_class) and is_number(confidence) and not is_nil(bbox) and
         is_integer(frag_seq) and is_integer(media_pts_ns) do
      %{
        object_class: object_class,
        confidence: confidence * 1.0,
        bbox: bbox,
        bbox_list: [bbox["x1"], bbox["y1"], bbox["x2"], bbox["y2"]],
        bbox_area: (bbox["x2"] - bbox["x1"]) * (bbox["y2"] - bbox["y1"]),
        track_id: track_id,
        fragment_sequence: frag_seq,
        media_pts_ns: media_pts_ns,
        timeline_ts_us: timeline_ts_us,
        det_idx: idx
      }
    end
  end

  defp normalize_detection(_, _, _, _, _), do: nil

  defp normalize_track_id(nil), do: nil

  defp normalize_track_id(track_id) when is_binary(track_id) do
    trimmed = String.trim(track_id)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_track_id(track_id) when is_integer(track_id), do: Integer.to_string(track_id)

  defp normalize_track_id(track_id) when is_atom(track_id) do
    track_id |> Atom.to_string() |> normalize_track_id()
  end

  defp normalize_track_id(_), do: nil

  defguardp unit_coord(v) when (is_float(v) or is_integer(v)) and v >= 0.0 and v <= 1.0

  defp normalize_bbox(%{} = bbox) do
    x1 = fetch_val(bbox, :x1)
    y1 = fetch_val(bbox, :y1)
    x2 = fetch_val(bbox, :x2)
    y2 = fetch_val(bbox, :y2)

    if unit_coord(x1) and unit_coord(y1) and unit_coord(x2) and unit_coord(y2) and x1 < x2 and
         y1 < y2 do
      %{"x1" => x1 * 1.0, "y1" => y1 * 1.0, "x2" => x2 * 1.0, "y2" => y2 * 1.0}
    end
  end

  defp normalize_bbox([x1, y1, x2, y2])
       when unit_coord(x1) and unit_coord(y1) and unit_coord(x2) and unit_coord(y2) and x1 < x2 and
              y1 < y2 do
    %{"x1" => x1 * 1.0, "y1" => y1 * 1.0, "x2" => x2 * 1.0, "y2" => y2 * 1.0}
  end

  defp normalize_bbox(_), do: nil

  defp group_detections_for_pipeline([], _pipeline), do: []

  defp group_detections_for_pipeline(detections, pipeline) do
    max_per_track = max(1, Map.get(pipeline, :max_frames_per_track) || 3)

    detections
    |> Enum.group_by(fn det ->
      if is_binary(det.track_id) and det.track_id != "" do
        "track:" <> det.track_id
      else
        "frame:#{det.fragment_sequence}:det:#{det.det_idx}"
      end
    end)
    |> Enum.sort_by(fn {target_key, _items} -> target_key end)
    |> Enum.map(fn {target_key, items} ->
      selected =
        items
        |> Enum.sort_by(fn det -> {det.confidence, det.bbox_area} end, :desc)
        |> Enum.take(max_per_track)
        |> Enum.sort_by(& &1.fragment_sequence)
        |> Enum.map(fn det ->
          %{
            "target_key" => target_key,
            "track_id" => det.track_id,
            "fragment_sequence" => det.fragment_sequence,
            "media_pts_ns" => det.media_pts_ns,
            "timeline_ts_us" => det.timeline_ts_us,
            "category" => det.object_class,
            "confidence" => det.confidence,
            "bbox" => det.bbox_list
          }
        end)

      {target_key, selected}
    end)
  end

  defp apply_rate_budget([], _pipeline, _now, _opts), do: []

  defp apply_rate_budget(groups, pipeline, now, opts) do
    limit = max(1, Map.get(pipeline, :max_jobs_per_minute) || 60)
    recent_count = count_recent_jobs(pipeline.pipeline_id, now, opts)
    remaining = max(0, limit - recent_count)
    {allowed, dropped} = Enum.split(groups, remaining)

    if dropped != [] do
      emit_dropped_telemetry(pipeline, length(dropped), :rate_limit_exceeded)
    end

    allowed
  end

  defp enqueue_groups(_pipeline, _entry, [], _now, _opts), do: {:ok, []}

  defp enqueue_groups(pipeline, entry, groups, now, opts) do
    with {:ok, target_runner, subject} <- resolve_runner_and_subject(pipeline, now, opts) do
      deadline_at = DateTime.add(now, @default_deadline_ms, :millisecond)
      entry_time_basis = normalize_entry_time_basis(entry)
      capability = normalize_admitted_capability(pipeline, target_runner)

      base_payload = %{
        "schema_version" => "vantage.job.v1",
        "pack_id" => Map.get(pipeline, :pack_id),
        "capability" => capability,
        "source_mode" => to_string(Map.get(pipeline, :source_mode) || :recorded_block),
        "input_mode" => to_string(pipeline.input_mode),
        "roi_polygons" => normalize_wire_roi_polygons(pipeline.roi_polygons || []),
        "crop_policy" => pipeline.crop_policy || %{},
        "signal_schema_id" => pipeline.signal_schema_id,
        "signal_schema_version" => pipeline.signal_schema_version,
        "display_contract_id" => pipeline.display_contract_id,
        "budget_ms" => Map.get(pipeline, :budget_ms) || 5000,
        "pipeline_config" => VantagePipeline.effective_pipeline_config(pipeline),
        "time_basis" => entry_time_basis
      }

      raw_vlm_config = Map.get(pipeline, :vlm_config) || %{}

      job_payload =
        if target_runner == "camera_vlm" or map_size(raw_vlm_config) > 0 do
          Map.put(base_payload, "vlm_config", raw_vlm_config)
        else
          base_payload
        end

      enqueued =
        Enum.flat_map(groups, fn {target_key, sampled_targets} ->
          targets_with_basis =
            Enum.map(sampled_targets, fn target ->
              Map.put_new(target, "time_basis", entry_time_basis)
            end)

          attrs = %{
            vantage_pipeline_id: Map.get(pipeline, :id),
            pipeline_id: pipeline.pipeline_id,
            pipeline_version: pipeline.version,
            catalog_entry_id: entry.id,
            camera_source_id: entry.camera_source_id,
            stream_profile_id: entry.stream_profile_id,
            target_key: target_key,
            job_kind: :live,
            state: :pending,
            target_runner: target_runner,
            subject: subject,
            descriptor_sha256: entry.descriptor_sha256,
            sampled_targets: targets_with_basis,
            job_payload: job_payload,
            deadline_at: deadline_at
          }

          case enqueue_job(attrs, opts) do
            {:ok, job} ->
              [job]

            {:error, reason} ->
              Logger.warning("Failed to enqueue Vantage job",
                pipeline_id: pipeline.pipeline_id,
                catalog_entry_id: to_string(entry.id),
                target_key: target_key,
                reason: inspect(reason)
              )

              []
          end
        end)

      {:ok, enqueued}
    end
  end

  defp resolve_runner_and_subject(pipeline, now, opts) do
    capability = Map.get(pipeline, :capability)
    runner = Map.get(pipeline, :runner, :camera_vlm)
    fallback = Map.get(pipeline, :fallback_runner)
    source_mode = Map.get(pipeline, :source_mode, :recorded_block)

    if runner in [:external_worker, "external_worker"] do
      if valid_external_capability?(capability) do
        if worker_active?(capability, source_mode, now, opts) do
          {:ok, capability, job_subject(:external_worker, capability, :live)}
        else
          if fallback == "camera_vlm" and source_mode in [:recorded_block, "recorded_block"] do
            {:ok, "camera_vlm", @vlm_subject}
          else
            {:ok, capability, job_subject(:external_worker, capability, :live)}
          end
        end
      else
        {:error, :invalid_capability}
      end
    else
      {:ok, "camera_vlm", @vlm_subject}
    end
  end

  defp valid_external_capability?(capability) when is_binary(capability) do
    VantagePipeline.valid_capability?(capability) and capability_slug(capability) != ""
  end

  defp valid_external_capability?(_), do: false

  defp worker_active?(capability, source_mode, now, opts) do
    case Keyword.get(opts, :worker_active_fn) do
      fun when is_function(fun, 2) ->
        fun.(capability, now)

      _ ->
        case VantagePipelineDispatcher.eligible_workers(capability, source_mode, now, opts) do
          {:ok, [_ | _]} -> true
          _ -> false
        end
    end
  end

  defp normalize_entry_time_basis(entry) do
    case fetch_val(entry, :time_basis) do
      basis when basis in [:camera_reported, "camera_reported"] -> "camera_reported"
      _ -> "received"
    end
  end

  defp normalize_admitted_capability(pipeline, target_runner) do
    case Map.get(pipeline, :capability) do
      cap when is_binary(cap) ->
        if VantagePipeline.valid_capability?(cap) do
          cap
        else
          default_admitted_capability(target_runner)
        end

      _ ->
        default_admitted_capability(target_runner)
    end
  end

  defp default_admitted_capability(target_runner)
       when is_binary(target_runner) and target_runner != "camera_vlm",
       do: target_runner

  defp default_admitted_capability(_), do: "vantage.vlm.v1"

  defp normalize_wire_roi_polygons(polygons) when is_list(polygons) do
    Enum.flat_map(polygons, fn
      %{"points" => pts} -> normalize_wire_poly(pts)
      %{points: pts} -> normalize_wire_poly(pts)
      pts when is_list(pts) -> normalize_wire_poly(pts)
      _ -> []
    end)
  end

  defp normalize_wire_roi_polygons(_), do: []

  defp normalize_wire_poly(pts) when is_list(pts) do
    parsed =
      Enum.flat_map(pts, fn
        [x, y] when is_number(x) and is_number(y) -> [[x * 1.0, y * 1.0]]
        %{"x" => x, "y" => y} when is_number(x) and is_number(y) -> [[x * 1.0, y * 1.0]]
        %{x: x, y: y} when is_number(x) and is_number(y) -> [[x * 1.0, y * 1.0]]
        _ -> []
      end)

    if length(parsed) >= 3, do: [parsed], else: []
  end

  defp normalize_wire_poly(_), do: []

  defp enqueue_job(attrs, opts) do
    case Keyword.get(opts, :enqueue_fn) do
      fun when is_function(fun, 1) ->
        fun.(attrs)

      _ ->
        VantageJob
        |> Ash.Changeset.for_create(:enqueue, attrs, actor: @system_actor)
        |> Ash.create(actor: @system_actor)
    end
  end

  defp count_recent_jobs(pipeline_id, now, opts) do
    case Keyword.get(opts, :recent_job_count_fn) do
      fun when is_function(fun, 2) ->
        fun.(pipeline_id, now)

      _ ->
        cutoff = DateTime.shift(now, minute: -1)

        VantageJob
        |> Ash.Query.filter(pipeline_id == ^pipeline_id and inserted_at >= ^cutoff)
        |> Ash.count(actor: @system_actor)
        |> case do
          {:ok, count} -> count
          _ -> 0
        end
    end
  end

  defp load_pipelines(trigger_kind, opts) do
    case Keyword.get(opts, :pipelines_loader) do
      fun when is_function(fun, 1) ->
        fun.(trigger_kind)

      _ ->
        if Keyword.has_key?(opts, :pipelines) do
          pipelines =
            opts
            |> Keyword.get(:pipelines, [])
            |> Enum.filter(&(&1.enabled == true and &1.trigger_kind == trigger_kind))

          {:ok, pipelines}
        else
          VantagePipeline
          |> Ash.Query.filter(
            enabled == true and
              trigger_kind == ^trigger_kind and
              source_mode == :recorded_block
          )
          |> Ash.read(actor: @system_actor)
        end
    end
  end

  defp load_source(camera_source_id, opts) do
    cond do
      Keyword.has_key?(opts, :source) ->
        Keyword.get(opts, :source)

      is_function(opts[:source_loader], 1) ->
        case opts[:source_loader].(camera_source_id) do
          {:ok, source} -> source
          source when is_map(source) -> source
          _ -> nil
        end

      true ->
        case Ash.get(Source, camera_source_id, actor: @system_actor, not_found_error?: false) do
          {:ok, %Source{} = source} -> source
          _ -> nil
        end
    end
  end

  defp maybe_load_device(nil, _pipelines, _opts), do: nil

  defp maybe_load_device(source, pipelines, opts) do
    needs_device? =
      Enum.any?(pipelines, fn pipeline ->
        selector = Map.get(pipeline, :camera_selector) || %{}
        fetch_val(selector, :mode) == "srql"
      end)

    cond do
      not needs_device? ->
        nil

      Keyword.has_key?(opts, :device) ->
        Keyword.get(opts, :device)

      is_function(opts[:device_loader], 1) ->
        case opts[:device_loader].(fetch_val(source, :device_uid)) do
          {:ok, device} -> device
          device when is_map(device) -> device
          _ -> nil
        end

      is_binary(fetch_val(source, :device_uid)) ->
        case Ash.get(Device, fetch_val(source, :device_uid),
               actor: @system_actor,
               not_found_error?: false
             ) do
          {:ok, %Device{} = device} -> device
          _ -> nil
        end

      true ->
        nil
    end
  end

  @doc false
  @spec matches_camera_selector?(map(), map(), map() | nil, map() | nil) :: boolean()
  def matches_camera_selector?(pipeline, entry, source, device) do
    selector = Map.get(pipeline, :camera_selector) || %{}
    mode = fetch_val(selector, :mode) || "all"

    case mode do
      "all" ->
        true

      "camera_source_ids" ->
        case fetch_val(selector, :camera_source_ids) do
          ids when is_list(ids) ->
            safe_ids = Enum.flat_map(ids, &safe_string_list/1)
            to_string(entry.camera_source_id) in safe_ids

          _ ->
            false
        end

      "policy_binding" ->
        entry_policy = Map.get(entry, :policy_id)

        case fetch_val(selector, :policy_ids) do
          policy_ids when is_list(policy_ids) and not is_nil(entry_policy) ->
            safe_ids = Enum.flat_map(policy_ids, &safe_string_list/1)
            to_string(entry_policy) in safe_ids

          _ ->
            false
        end

      "srql" ->
        srql = fetch_val(selector, :srql) || ""
        matches_srql_selector?(srql, entry, source, device)

      _ ->
        false
    end
  end

  defp safe_string_list(v) when is_binary(v), do: [v]
  defp safe_string_list(v) when is_integer(v), do: [Integer.to_string(v)]
  defp safe_string_list(v) when is_atom(v) and not is_nil(v), do: [Atom.to_string(v)]
  defp safe_string_list(_), do: []

  defp matches_srql_selector?(srql, entry, source, device) when is_binary(srql) do
    tokens = tokenize_srql(srql)

    tokens != [] and Enum.all?(tokens, &matches_srql_token?(&1, entry, source, device))
  end

  defp matches_srql_selector?(_, _, _, _), do: false

  defp tokenize_srql(srql) when is_binary(srql) do
    do_tokenize_srql(srql, "", nil, [])
  end

  defp do_tokenize_srql(<<>>, current, nil, acc) do
    tokens = if current == "", do: acc, else: [current | acc]
    Enum.reverse(tokens)
  end

  defp do_tokenize_srql(<<>>, _current, _unclosed_quote, _acc), do: []

  defp do_tokenize_srql(<<ch, rest::binary>>, current, nil, acc)
       when ch in [?\s, ?\t, ?\n, ?\r] do
    if current == "" do
      do_tokenize_srql(rest, "", nil, acc)
    else
      do_tokenize_srql(rest, "", nil, [current | acc])
    end
  end

  defp do_tokenize_srql(<<q, rest::binary>>, current, nil, acc) when q in [?", ?'] do
    do_tokenize_srql(rest, current, q, acc)
  end

  defp do_tokenize_srql(<<?\\, next::utf8, rest::binary>>, current, q, acc) when not is_nil(q) do
    do_tokenize_srql(rest, current <> <<next::utf8>>, q, acc)
  end

  defp do_tokenize_srql(<<q, rest::binary>>, current, q, acc) when not is_nil(q) do
    do_tokenize_srql(rest, current, nil, acc)
  end

  defp do_tokenize_srql(<<ch::utf8, rest::binary>>, current, q, acc) do
    do_tokenize_srql(rest, current <> <<ch::utf8>>, q, acc)
  end

  defp matches_srql_token?("tag:" <> tag, _entry, source, device) do
    expected = String.downcase(String.trim(tag))

    tags = Enum.map(extract_tags(device) ++ extract_source_tags(source), &String.downcase/1)

    expected != "" and expected in tags
  end

  defp matches_srql_token?("camera_source_id:" <> id, entry, _source, _device) do
    trimmed = String.trim(id)
    trimmed != "" and trimmed == to_string(entry.camera_source_id)
  end

  defp matches_srql_token?("display_name:" <> expected, _entry, source, _device) do
    display = source && fetch_val(source, :display_name)
    trimmed = String.trim(expected)

    is_binary(display) and trimmed != "" and
      String.downcase(display) == String.downcase(trimmed)
  end

  defp matches_srql_token?(_, _, _, _), do: false

  defp extract_tags(nil), do: []

  defp extract_tags(device) do
    case fetch_val(device, :tags) do
      %{} = map ->
        Enum.flat_map(map, fn
          {k, true} ->
            safe_string_list(k)

          {k, v} when is_binary(v) and v != "" ->
            case safe_string_list(k) do
              [ks] -> [ks, v, "#{ks}=#{v}"]
              [] -> [v]
            end

          {k, _} ->
            safe_string_list(k)
        end)

      list when is_list(list) ->
        Enum.flat_map(list, &safe_string_list/1)

      _ ->
        []
    end
  end

  defp extract_source_tags(nil), do: []

  defp extract_source_tags(source) do
    meta = fetch_val(source, :metadata) || %{}

    case fetch_val(meta, :tags) do
      list when is_list(list) -> Enum.flat_map(list, &safe_string_list/1)
      %{} = map -> map |> Map.keys() |> Enum.flat_map(&safe_string_list/1)
      _ -> []
    end
  end

  defp normalize_classes(classes) when is_list(classes) do
    classes
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.downcase(String.trim(&1)))
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_classes(_), do: []

  defp matches_class?([], _object_class), do: true

  defp matches_class?(allowed, object_class) when is_binary(object_class) do
    String.downcase(String.trim(object_class)) in allowed
  end

  defp matches_class?(_, _), do: false

  defp normalize_polygons(polygons) when is_list(polygons) do
    Enum.flat_map(polygons, fn poly ->
      case fetch_val(poly, :points) do
        pts when is_list(pts) ->
          parsed =
            Enum.flat_map(pts, fn
              [x, y] when is_number(x) and is_number(y) -> [{x * 1.0, y * 1.0}]
              %{"x" => x, "y" => y} when is_number(x) and is_number(y) -> [{x * 1.0, y * 1.0}]
              %{x: x, y: y} when is_number(x) and is_number(y) -> [{x * 1.0, y * 1.0}]
              _ -> []
            end)

          if length(parsed) >= 3, do: [parsed], else: []

        _ ->
          []
      end
    end)
  end

  defp normalize_polygons(_), do: []

  defp matches_roi?(bbox, [_ | _] = polygons, _roi_grid) do
    cx = (bbox["x1"] + bbox["x2"]) / 2.0
    cy = (bbox["y1"] + bbox["y2"]) / 2.0
    Enum.any?(polygons, &point_in_polygon?({cx, cy}, &1))
  end

  defp matches_roi?(bbox, [], %{"rows" => rows, "cols" => cols, "ignore_cells" => ignore_cells}) do
    cx = (bbox["x1"] + bbox["x2"]) / 2.0
    cy = (bbox["y1"] + bbox["y2"]) / 2.0
    row = min(rows - 1, max(0, trunc(cy * rows)))
    col = min(cols - 1, max(0, trunc(cx * cols)))
    [row, col] not in ignore_cells
  end

  defp matches_roi?(_bbox, [], _roi_grid), do: true

  @doc false
  @spec point_in_polygon?({float(), float()}, [{float(), float()}]) :: boolean()
  def point_in_polygon?({px, py}, vertices) when length(vertices) >= 3 do
    shifted = tl(vertices) ++ [hd(vertices)]

    vertices
    |> Enum.zip(shifted)
    |> Enum.reduce(false, fn {{x1, y1}, {x2, y2}}, inside ->
      intersects? =
        y1 > py != y2 > py and
          px < (x2 - x1) * (py - y1) / (y2 - y1) + x1

      if intersects?, do: not inside, else: inside
    end)
  end

  def point_in_polygon?(_, _), do: false

  defp extract_source_roi_grid(nil), do: nil

  defp extract_source_roi_grid(source) do
    meta = fetch_val(source, :metadata) || %{}

    case fetch_val(meta, :detection_roi_grid) do
      %{} = grid ->
        rows = clamp_grid_dim(fetch_val(grid, :rows), 8)
        cols = clamp_grid_dim(fetch_val(grid, :cols), 12)

        ignore =
          case fetch_val(grid, :ignore_cells) do
            list when is_list(list) -> list
            _ -> []
          end

        ignore_cells =
          Enum.filter(ignore, fn
            [r, c]
            when is_integer(r) and is_integer(c) and r >= 0 and r < rows and c >= 0 and
                   c < cols ->
              true

            _ ->
              false
          end)

        if ignore_cells == [] do
          nil
        else
          %{"rows" => rows, "cols" => cols, "ignore_cells" => ignore_cells}
        end

      _ ->
        nil
    end
  end

  defp clamp_grid_dim(v, _default) when is_integer(v) and v >= 1 and v <= 64, do: v
  defp clamp_grid_dim(_, default), do: default

  defp extract_sealed_block_targets(entry, descriptor, pipeline) do
    max_items =
      min(@max_sealed_block_fragments, max(1, Map.get(pipeline, :max_frames_per_track) || 3))

    fragments =
      case fetch_val(descriptor, :fragments) do
        list when is_list(list) -> Enum.filter(list, &is_map/1)
        _ -> []
      end

    fragments
    |> Enum.filter(fn frag ->
      fetch_val(frag, :has_idr) == true or fetch_val(frag, :keyframe) == true
    end)
    |> case do
      [] -> Enum.take(fragments, max_items)
      kfs -> Enum.take(kfs, max_items)
    end
    |> Enum.with_index()
    |> Enum.map(fn {frag, idx} ->
      seq =
        case fetch_val(frag, :sequence) do
          n when is_integer(n) and n >= 0 -> n
          _ -> idx
        end

      raw_pts_ns =
        fetch_val(frag, :media_pts_ns) ||
          fetch_val(frag, :start_ns) ||
          fetch_val(frag, :pts_ns) ||
          entry.media_start_ns ||
          0

      pts_ns = if is_integer(raw_pts_ns), do: raw_pts_ns, else: entry.media_start_ns || 0

      %{
        "target_key" => "block",
        "fragment_sequence" => seq,
        "media_pts_ns" => pts_ns,
        "timeline_ts_us" => compute_timeline_ts_us(entry, pts_ns),
        "time_basis" => normalize_entry_time_basis(entry)
      }
    end)
  end

  defp compute_timeline_ts_us(entry, media_pts_ns) when is_integer(media_pts_ns) do
    base_ns = Map.get(entry, :media_start_ns) || 0
    offset_us = div(max(0, media_pts_ns - base_ns), 1_000)

    case fallback_timeline_start_us(entry) do
      start_us when is_integer(start_us) ->
        ts = max(0, start_us + offset_us)
        clamp_timeline_end_us(ts, Map.get(entry, :timeline_end_us))

      nil ->
        0
    end
  end

  defp compute_timeline_ts_us(entry, _), do: fallback_timeline_start_us(entry) || 0

  defp fallback_timeline_start_us(entry) do
    cond do
      is_integer(s = Map.get(entry, :timeline_start_us)) ->
        max(0, s)

      match?(%DateTime{}, dt = Map.get(entry, :first_unit_received_at)) ->
        max(0, DateTime.to_unix(dt, :microsecond))

      is_integer(e = Map.get(entry, :timeline_end_us)) ->
        max(0, e)

      true ->
        nil
    end
  end

  defp clamp_timeline_end_us(ts, end_us) when is_integer(end_us) and end_us >= 0,
    do: min(end_us, ts)

  defp clamp_timeline_end_us(ts, _), do: ts

  defp emit_dropped_telemetry(pipeline, count, reason) do
    :telemetry.execute(
      [:serviceradar, :camera, :vantage, :admission_dropped],
      %{count: count},
      %{pipeline_id: pipeline.pipeline_id, reason: reason}
    )
  end

  defp fetch_val(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp fetch_val(_, _), do: nil
end
