defmodule ServiceRadar.Camera.RecordingEventClips do
  @moduledoc """
  Query and projection service for per-camera event clips over detection
  frames and playable `RecordingCatalogEntry` segments.

  `list_clips/3` projects coalesced event clips (`:person`, `:vehicle`,
  `:animal`, `:package`, `:motion`, and `:recording` fallback segments) for a
  camera coverage window using separate bounded queries for detection and
  motion-only frames. `list_page/3` and `paginate_clips/2` return a bounded
  server-side page (`12` per page by default, capped at `48`) alongside
  full-window mode/category counts and lightweight timeline event markers.
  `category_counts/1` and `filter_clips/2` provide in-memory mode
  (`:all | :smart | :basic`) and category counting and filtering.

  Detection and motion frames come only from a detection provider passed as
  `loaders.visual_frames_loader/4` (`camera_source_id, stream_profile_id,
  from_us, to_us -> {:ok, frames}`). ServiceRadar ships none: detections come
  from the commercial Vantage addon. Without a provider, only `:recording`
  segments over playable `RecordingCatalogEntry` blocks are listed.

  Supports both live CNPG execution and `:loaders` injection for `:db_free`
  unit test suites in `serviceradar_core` and `web-ng`.
  """

  alias Ash.Error.Forbidden
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.RecordingCatalogEntry
  alias ServiceRadar.Camera.RecordingTimeline
  alias ServiceRadar.Camera.Thumbnail
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  require Ash.Query

  @system_actor SystemActor.system(:camera_recording_event_clips)

  @max_window_us 31 * 86_400 * 1_000_000
  @default_limit 100
  @default_per_page 12
  @max_per_page 48
  @default_coalesce_gap_us 8_000_000
  @default_detection_clip_duration_us 4_000_000

  @smart_categories [:person, :vehicle, :animal, :package]
  @basic_categories [:motion, :recording]
  @all_categories @smart_categories ++ @basic_categories

  @read_permissions [
    "devices.cameras.recordings.view",
    "settings.recording.view",
    "settings.recording.manage",
    "settings.recording.operate"
  ]

  @type category :: :person | :vehicle | :animal | :package | :motion | :recording
  @type smart_type :: :smart | :basic
  @type mode_filter :: :all | :smart | :basic
  @type category_filter :: :all | category()

  @doc "All supported clip categories."
  @spec categories() :: [category()]
  def categories, do: @all_categories

  @doc "Categories classified as `:smart` detections."
  @spec smart_categories() :: [category()]
  def smart_categories, do: @smart_categories

  @doc "Categories classified as `:basic` (motion or recorded segment fallback)."
  @spec basic_categories() :: [category()]
  def basic_categories, do: @basic_categories

  @doc "Default per-view clip display limit."
  @spec default_limit() :: pos_integer()
  def default_limit, do: @default_limit

  @doc "Default page size for server-side paginated clip views (2 rows x 6 cards)."
  @spec default_per_page() :: pos_integer()
  def default_per_page, do: @default_per_page

  @doc "Maximum allowed page size for server-side paginated clip views."
  @spec max_per_page() :: pos_integer()
  def max_per_page, do: @max_per_page

  @doc """
  Lists event clips for `camera_source_id` within `[from_us, to_us]`.

  When playable `RecordingCatalogEntry` blocks exist in the window and have no
  detection clips covering them, `:recording` fallback segments (`smart_type: :basic`)
  are included so recording cameras immediately present clickable clips under
  `All` and `Basic`.
  """
  @spec list_clips(String.t(), map() | keyword(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def list_clips(camera_source_id, params \\ %{}, opts \\ [])
      when is_binary(camera_source_id) and (is_map(params) or is_list(params)) and is_list(opts) do
    attrs = to_map(params)
    loaders = Keyword.get(opts, :loaders, %{})
    coalesce_gap_us = Keyword.get(opts, :coalesce_gap_us, @default_coalesce_gap_us)

    with :ok <- authorize_optional_caller(opts),
         {:ok, camera_uuid} <- cast_uuid(camera_source_id, :invalid_camera_source_id),
         {:ok, profile_uuid} <- parse_optional_profile_id(attrs),
         {:ok, from_us, to_us} <- parse_window(attrs),
         {:ok, catalog_entries} <-
           load_playable_catalog_entries(
             camera_uuid,
             profile_uuid,
             from_us,
             to_us,
             fetch_val(attrs, :catalog_blocks),
             loaders
           ),
         {:ok, frames} <-
           load_window_visual_frames(camera_uuid, profile_uuid, from_us, to_us, loaders) do
      playable_by_id = Map.new(catalog_entries, &{to_string(entry_id(&1)), &1})

      detection_clips =
        frames
        |> Enum.filter(&frame_belongs_to_playable?(&1, playable_by_id, from_us, to_us))
        |> build_detection_clips(camera_uuid, playable_by_id, coalesce_gap_us)

      covered_entry_ids =
        detection_clips
        |> Enum.map(& &1.catalog_entry_id)
        |> Enum.reject(&is_nil/1)
        |> MapSet.new(&to_string/1)

      fallback_clips =
        catalog_entries
        |> Enum.reject(fn entry ->
          MapSet.member?(covered_entry_ids, to_string(entry_id(entry)))
        end)
        |> Enum.map(&build_recording_segment_clip(&1, camera_uuid))

      clips =
        Enum.sort_by(detection_clips ++ fallback_clips, fn clip -> {-clip.start_us, clip.id} end)

      {:ok,
       %{
         camera_source_id: camera_uuid,
         from_us: from_us,
         to_us: to_us,
         clips: clips
       }}
    end
  end

  @doc """
  Lists a server-side paginated and filtered slice of event clips for
  `camera_source_id` within `[from_us, to_us]`, together with full window
  category/mode counts and lightweight timeline event markers.

  Supports:
  - `mode`: `:all | :smart | :basic` (or string equivalents, default `:all`)
  - `category`: `:all | category()` (or string equivalents, default `:all`)
  - `page`: 1-indexed page number (default `1`, clamped to `1..total_pages`)
  - `per_page`: page size (default `12`, capped at `48`)
  """
  @spec list_page(String.t(), map() | keyword(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def list_page(camera_source_id, params \\ %{}, opts \\ [])
      when is_binary(camera_source_id) and (is_map(params) or is_list(params)) and is_list(opts) do
    attrs = to_map(params)

    with {:ok, result} <- list_clips(camera_source_id, attrs, opts) do
      min_confidence = normalize_min_confidence(fetch_val(attrs, :min_confidence))
      threshold_clips = filter_by_min_confidence(result.clips, min_confidence)
      paged = paginate_clips(threshold_clips, attrs)

      markers =
        threshold_clips
        |> Enum.reject(&(&1.category == :recording))
        |> Enum.map(fn clip ->
          %{
            id: clip.id,
            category: clip.category,
            smart_type: clip.smart_type,
            label: clip.label,
            confidence: clip.confidence,
            start_us: clip.start_us,
            end_us: clip.end_us,
            peak_ts_us: clip.peak_ts_us,
            visual_frame_id: clip.visual_frame_id,
            thumbnail_url: clip.thumbnail_url
          }
        end)

      {:ok,
       Map.merge(paged, %{
         camera_source_id: result.camera_source_id,
         from_us: result.from_us,
         to_us: result.to_us,
         markers: markers
       })}
    end
  end

  @doc """
  Computes full counts, applies mode/category/confidence filters, and returns a single
  bounded page slice of clips.
  """
  @spec paginate_clips([map()], map() | keyword()) :: map()
  def paginate_clips(clips, params \\ %{}) when is_list(clips) do
    attrs = to_map(params)
    min_confidence = normalize_min_confidence(fetch_val(attrs, :min_confidence))
    threshold_clips = filter_by_min_confidence(clips, min_confidence)
    counts = category_counts(threshold_clips)
    filtered = filter_clips(threshold_clips, attrs)
    total_count = length(filtered)
    per_page = parse_per_page(fetch_val(attrs, :per_page))
    total_pages = max(div(total_count + per_page - 1, per_page), 1)
    requested_page = parse_page(fetch_val(attrs, :page))
    page = min(requested_page, total_pages)

    page_clips =
      filtered
      |> Enum.drop((page - 1) * per_page)
      |> Enum.take(per_page)

    %{
      clips: page_clips,
      total_count: total_count,
      page: page,
      per_page: per_page,
      total_pages: total_pages,
      counts: counts
    }
  end

  @doc """
  Filters a list of clip maps in-memory by `mode` (`:all | :smart | :basic`),
  `category` (`:all | category()`), and optional `min_confidence` (`0.0..1.0`
  or `0..100` percentage, applied to `:smart` clips).
  """
  @spec filter_clips([map()], map() | keyword()) :: [map()]
  def filter_clips(clips, filters \\ %{}) when is_list(clips) do
    attrs = to_map(filters)
    mode = normalize_mode_value(fetch_val(attrs, :mode))
    category = normalize_category_value(fetch_val(attrs, :category))
    min_confidence = normalize_min_confidence(fetch_val(attrs, :min_confidence))

    Enum.filter(clips, fn clip ->
      mode_matches?(clip, mode) and category_matches?(clip, category) and
        confidence_matches?(clip, min_confidence)
    end)
  end

  @doc """
  Computes clip counts by mode (`:all`, `:smart`, `:basic`) and by each category.
  """
  @spec category_counts([map()]) :: map()
  def category_counts(clips) when is_list(clips) do
    initial = %{
      all: 0,
      smart: 0,
      basic: 0,
      person: 0,
      vehicle: 0,
      animal: 0,
      package: 0,
      motion: 0,
      recording: 0
    }

    Enum.reduce(clips, initial, fn clip, acc ->
      cat = clip[:category]
      smart_type = clip[:smart_type]

      acc = Map.update!(acc, :all, &(&1 + 1))

      acc =
        case smart_type do
          :smart -> Map.update!(acc, :smart, &(&1 + 1))
          :basic -> Map.update!(acc, :basic, &(&1 + 1))
          _ -> acc
        end

      if Map.has_key?(acc, cat) do
        Map.update!(acc, cat, &(&1 + 1))
      else
        acc
      end
    end)
  end

  @doc """
  Maps a raw detector `object_class` string to `{category, smart_type}`.
  """
  @spec classify_object_class(String.t() | atom() | nil) :: {category(), smart_type()}
  def classify_object_class(nil), do: {:motion, :basic}

  def classify_object_class(raw) do
    case raw |> to_string() |> String.trim() |> String.downcase() do
      "person" -> {:person, :smart}
      "human" -> {:person, :smart}
      "pedestrian" -> {:person, :smart}
      "vehicle" -> {:vehicle, :smart}
      "car" -> {:vehicle, :smart}
      "truck" -> {:vehicle, :smart}
      "bus" -> {:vehicle, :smart}
      "van" -> {:vehicle, :smart}
      "motorcycle" -> {:vehicle, :smart}
      "bicycle" -> {:vehicle, :smart}
      "animal" -> {:animal, :smart}
      "dog" -> {:animal, :smart}
      "cat" -> {:animal, :smart}
      "bird" -> {:animal, :smart}
      "pet" -> {:animal, :smart}
      "package" -> {:package, :smart}
      "parcel" -> {:package, :smart}
      "box" -> {:package, :smart}
      "motion" -> {:motion, :basic}
      _ -> {:motion, :basic}
    end
  end

  @doc "Returns a human-readable label for a clip category."
  @spec category_label(category()) :: String.t()
  def category_label(:person), do: "Person"
  def category_label(:vehicle), do: "Vehicle"
  def category_label(:animal), do: "Animal"
  def category_label(:package), do: "Package"
  def category_label(:motion), do: "Motion"
  def category_label(:recording), do: "Recording"
  def category_label(other), do: other |> to_string() |> String.capitalize()

  # ---------------------------------------------------------------------------
  # Private: Data Loading
  # ---------------------------------------------------------------------------

  defp load_playable_catalog_entries(
         camera_uuid,
         profile_uuid,
         from_us,
         to_us,
         preloaded_blocks,
         loaders
       ) do
    if is_list(preloaded_blocks) do
      {:ok, filter_playable_entries(preloaded_blocks, camera_uuid, profile_uuid, from_us, to_us)}
    else
      case Map.get(loaders, :catalog_loader) do
        loader when is_function(loader, 4) ->
          with {:ok, rows} <- loader.(camera_uuid, profile_uuid, from_us, to_us) do
            {:ok, filter_playable_entries(rows, camera_uuid, profile_uuid, from_us, to_us)}
          end

        nil ->
          query =
            RecordingCatalogEntry
            |> Ash.Query.for_read(:read, %{}, actor: @system_actor)
            |> Ash.Query.filter(
              camera_source_id == ^camera_uuid and
                local_state != :quarantined and
                is_nil(quarantine_reason) and
                not is_nil(recording_block_id) and
                not is_nil(timeline_start_us) and
                not is_nil(timeline_end_us) and
                timeline_end_us > ^from_us and
                timeline_start_us < ^to_us
            )
            |> maybe_filter_profile_query(profile_uuid)
            |> Ash.Query.load([:has_thumbnail])
            |> Ash.Query.sort(timeline_start_us: :asc, block_key: :asc)

          with {:ok, rows} <- Ash.read(query, actor: @system_actor) do
            {:ok, filter_playable_entries(rows, camera_uuid, profile_uuid, from_us, to_us)}
          end
      end
    end
  end

  # Detection frames come only from an injected provider; without one there are none.
  defp load_window_visual_frames(camera_uuid, profile_uuid, from_us, to_us, loaders) do
    case Map.get(loaders, :visual_frames_loader) do
      loader when is_function(loader, 4) -> loader.(camera_uuid, profile_uuid, from_us, to_us)
      _ -> {:ok, []}
    end
  end

  defp maybe_filter_profile_query(query, nil), do: query

  defp maybe_filter_profile_query(query, profile_uuid) do
    Ash.Query.filter(query, stream_profile_id == ^profile_uuid)
  end

  defp filter_playable_entries(entries, camera_uuid, profile_uuid, from_us, to_us) do
    entries
    |> Enum.filter(fn entry ->
      cam = fetch_val(entry, :camera_source_id)
      prof = fetch_val(entry, :stream_profile_id)
      t_start = fetch_val(entry, :timeline_start_us)
      t_end = fetch_val(entry, :timeline_end_us)

      RecordingCatalogEntry.playable?(entry) and
        to_string(cam || "") == camera_uuid and
        (is_nil(profile_uuid) or to_string(prof || "") == profile_uuid) and
        is_integer(t_start) and is_integer(t_end) and
        t_end > from_us and t_start < to_us
    end)
    |> Enum.sort_by(fn entry ->
      {fetch_val(entry, :timeline_start_us), to_string(entry_id(entry) || "")}
    end)
  end

  defp frame_belongs_to_playable?(frame, playable_by_id, from_us, to_us) do
    ts = fetch_val(frame, :timeline_ts_us)
    cid = to_string(fetch_val(frame, :catalog_entry_id) || "")

    is_integer(ts) and ts >= from_us and ts <= to_us and Map.has_key?(playable_by_id, cid)
  end

  # ---------------------------------------------------------------------------
  # Private: Detection Clip Coalescing & Segment Fallback
  # ---------------------------------------------------------------------------

  defp build_detection_clips(frames, camera_uuid, playable_by_id, coalesce_gap_us) do
    frames
    |> Enum.flat_map(&expand_frame_observations/1)
    |> Enum.sort_by(fn obs -> {obs.catalog_entry_id, obs.category, obs.timeline_ts_us} end)
    |> coalesce_observations(coalesce_gap_us)
    |> Enum.map(fn cluster ->
      entry = Map.get(playable_by_id, to_string(cluster.catalog_entry_id))
      finalize_detection_clip(cluster, camera_uuid, entry)
    end)
  end

  defp expand_frame_observations(frame) do
    detections = List.wrap(fetch_val(frame, :detections))
    scene_suppressed? = fetch_val(frame, :scene_suppressed) == true
    thumbnail_url = frame_thumbnail_url(frame)

    cond do
      detections != [] ->
        detections
        |> Enum.filter(&is_map/1)
        |> Enum.group_by(fn det ->
          {category, _smart_type} = classify_object_class(fetch_val(det, :object_class))
          category
        end)
        |> Enum.map(fn {category, dets} ->
          best =
            Enum.max_by(dets, fn det ->
              conf = fetch_val(det, :confidence)
              if is_number(conf), do: conf * 1.0, else: 0.0
            end)

          {_cat, smart_type} = classify_object_class(fetch_val(best, :object_class))

          colors =
            dets
            |> Enum.flat_map(&List.wrap(fetch_val(&1, :dominant_colors)))
            |> Enum.map(&to_string/1)
            |> Enum.reject(&(&1 == ""))
            |> Enum.uniq()

          %{
            visual_frame_id: fetch_val(frame, :id),
            catalog_entry_id: fetch_val(frame, :catalog_entry_id),
            fragment_sequence: fetch_val(frame, :fragment_sequence),
            timeline_ts_us: fetch_val(frame, :timeline_ts_us),
            category: category,
            smart_type: smart_type,
            object_class: fetch_val(best, :object_class),
            confidence: normalize_confidence(fetch_val(best, :confidence)),
            bbox: fetch_val(best, :bbox),
            dominant_colors: colors,
            thumbnail_url: thumbnail_url
          }
        end)

      not scene_suppressed? ->
        [
          %{
            visual_frame_id: fetch_val(frame, :id),
            catalog_entry_id: fetch_val(frame, :catalog_entry_id),
            fragment_sequence: fetch_val(frame, :fragment_sequence),
            timeline_ts_us: fetch_val(frame, :timeline_ts_us),
            category: :motion,
            smart_type: :basic,
            object_class: "motion",
            confidence: nil,
            bbox: nil,
            dominant_colors: [],
            thumbnail_url: thumbnail_url
          }
        ]

      true ->
        []
    end
  end

  defp coalesce_observations(observations, coalesce_gap_us) do
    observations
    |> Enum.reduce([], fn obs, acc ->
      case acc do
        [current | rest] ->
          same_group? =
            current.catalog_entry_id == obs.catalog_entry_id and
              current.category == obs.category

          within_gap? = obs.timeline_ts_us - current.last_ts_us <= coalesce_gap_us

          if same_group? and within_gap? do
            [merge_observation(current, obs) | rest]
          else
            [start_cluster(obs) | acc]
          end

        [] ->
          [start_cluster(obs)]
      end
    end)
    |> Enum.reverse()
  end

  defp start_cluster(obs) do
    %{
      catalog_entry_id: obs.catalog_entry_id,
      category: obs.category,
      smart_type: obs.smart_type,
      first_ts_us: obs.timeline_ts_us,
      last_ts_us: obs.timeline_ts_us,
      peak_ts_us: obs.timeline_ts_us,
      best_frame_id: obs.visual_frame_id,
      best_fragment_sequence: obs.fragment_sequence,
      best_confidence: obs.confidence,
      best_bbox: obs.bbox,
      object_class: obs.object_class,
      dominant_colors: obs.dominant_colors,
      thumbnail_url: obs.thumbnail_url,
      frame_count: 1
    }
  end

  defp merge_observation(cluster, obs) do
    better_peak? =
      case {cluster.best_confidence, obs.confidence} do
        {nil, c} when is_number(c) -> true
        {cur, c} when is_number(cur) and is_number(c) -> c > cur
        _ -> false
      end

    %{
      cluster
      | last_ts_us: max(cluster.last_ts_us, obs.timeline_ts_us),
        peak_ts_us: if(better_peak?, do: obs.timeline_ts_us, else: cluster.peak_ts_us),
        best_frame_id: if(better_peak?, do: obs.visual_frame_id, else: cluster.best_frame_id),
        best_fragment_sequence:
          if(better_peak?, do: obs.fragment_sequence, else: cluster.best_fragment_sequence),
        best_confidence: if(better_peak?, do: obs.confidence, else: cluster.best_confidence),
        best_bbox: if(better_peak?, do: obs.bbox, else: cluster.best_bbox),
        object_class: if(better_peak?, do: obs.object_class, else: cluster.object_class),
        thumbnail_url:
          if(better_peak?,
            do: obs.thumbnail_url || cluster.thumbnail_url,
            else: cluster.thumbnail_url || obs.thumbnail_url
          ),
        dominant_colors: Enum.uniq(cluster.dominant_colors ++ obs.dominant_colors),
        frame_count: cluster.frame_count + 1
    }
  end

  defp finalize_detection_clip(cluster, camera_uuid, entry) do
    entry_end_us = fetch_val(entry, :timeline_end_us)
    start_us = cluster.first_ts_us

    raw_end_us =
      if cluster.last_ts_us > start_us do
        cluster.last_ts_us + 2_000_000
      else
        start_us + @default_detection_clip_duration_us
      end

    end_us =
      if is_integer(entry_end_us) and entry_end_us > start_us do
        min(raw_end_us, entry_end_us)
      else
        raw_end_us
      end

    duration_seconds = max(round((end_us - start_us) / 1_000_000), 1)
    archive_state = normalize_atom(fetch_val(entry, :archive_state))
    local_state = normalize_atom(fetch_val(entry, :local_state))
    copy_state = if(is_map(entry), do: RecordingTimeline.copy_state(entry), else: :local_only)

    clip_id =
      case cluster.best_frame_id do
        nil -> "evt-#{cluster.catalog_entry_id}-#{cluster.category}-#{start_us}"
        frame_id -> "evt-#{frame_id}-#{cluster.category}"
      end

    %{
      id: clip_id,
      camera_source_id: camera_uuid,
      started_at: DateTime.from_unix!(start_us, :microsecond),
      ended_at: DateTime.from_unix!(end_us, :microsecond),
      start_us: start_us,
      end_us: end_us,
      peak_ts_us: cluster.peak_ts_us,
      duration_seconds: duration_seconds,
      category: cluster.category,
      smart_type: cluster.smart_type,
      label: category_label(cluster.category),
      confidence: cluster.best_confidence,
      attributes: %{
        dominant_colors: Enum.take(cluster.dominant_colors, 4),
        frame_count: cluster.frame_count,
        object_class: cluster.object_class,
        bbox: cluster.best_bbox
      },
      visual_frame_id: cluster.best_frame_id,
      fragment_sequence: cluster.best_fragment_sequence,
      catalog_entry_id: cluster.catalog_entry_id,
      archive_state: archive_state,
      local_state: local_state,
      copy_state: copy_state,
      thumbnail_url: cluster.thumbnail_url || entry_thumbnail_url(entry, camera_uuid)
    }
  end

  defp build_recording_segment_clip(entry, camera_uuid) do
    eid = entry_id(entry)
    start_us = fetch_val(entry, :timeline_start_us)
    end_us = max(fetch_val(entry, :timeline_end_us), start_us + 1_000_000)
    duration_seconds = max(round((end_us - start_us) / 1_000_000), 1)
    archive_state = normalize_atom(fetch_val(entry, :archive_state))
    local_state = normalize_atom(fetch_val(entry, :local_state))
    copy_state = RecordingTimeline.copy_state(entry)

    %{
      id: "rec-#{eid}",
      camera_source_id: camera_uuid,
      started_at: DateTime.from_unix!(start_us, :microsecond),
      ended_at: DateTime.from_unix!(end_us, :microsecond),
      start_us: start_us,
      end_us: end_us,
      peak_ts_us: start_us,
      duration_seconds: duration_seconds,
      category: :recording,
      smart_type: :basic,
      label: category_label(:recording),
      confidence: nil,
      attributes: %{
        dominant_colors: [],
        fragment_count: fetch_val(entry, :fragment_count),
        copy_state: copy_state
      },
      visual_frame_id: nil,
      fragment_sequence: nil,
      catalog_entry_id: eid,
      archive_state: archive_state,
      local_state: local_state,
      copy_state: copy_state,
      thumbnail_url: entry_thumbnail_url(entry, camera_uuid)
    }
  end

  # A provider may supply a thumbnail URL per frame; otherwise the clip falls back
  # to its recording block's thumbnail.
  defp frame_thumbnail_url(frame) do
    case fetch_val(frame, :thumbnail_url) do
      url when is_binary(url) and url != "" -> url
      _ -> nil
    end
  end

  defp entry_thumbnail_url(entry, camera_uuid) do
    case fetch_val(entry, :thumbnail_url) do
      url when is_binary(url) and url != "" ->
        url

      _ ->
        eid = entry_id(entry)

        if fetch_val(entry, :has_thumbnail) == true and not is_nil(eid) do
          Thumbnail.block_url(camera_uuid, eid)
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Private: Filtering, Validation & Authorization
  # ---------------------------------------------------------------------------

  defp mode_matches?(_clip, :all), do: true
  defp mode_matches?(clip, :smart), do: clip[:smart_type] == :smart
  defp mode_matches?(clip, :basic), do: clip[:smart_type] == :basic

  defp category_matches?(_clip, :all), do: true
  defp category_matches?(clip, cat), do: clip[:category] == cat

  defp authorize_optional_caller(opts) do
    if Keyword.has_key?(opts, :actor) do
      actor = Keyword.get(opts, :actor)

      permitted? =
        system_actor?(actor) or
          Enum.any?(@read_permissions, fn perm ->
            ActorHasPermission.match?(actor, [permission: perm], %{})
          end)

      if permitted?, do: :ok, else: {:error, Forbidden.exception([])}
    else
      :ok
    end
  end

  defp system_actor?(%{role: :system}), do: true
  defp system_actor?(%{role: "system"}), do: true
  defp system_actor?(_), do: false

  defp cast_uuid(val, error_reason) when is_binary(val) do
    case Ecto.UUID.cast(String.trim(val)) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, error_reason}
    end
  end

  defp cast_uuid(_, error_reason), do: {:error, error_reason}

  defp parse_optional_profile_id(attrs) do
    case fetch_val(attrs, :stream_profile_id) do
      val when val in [nil, ""] -> {:ok, nil}
      val -> cast_uuid(val, :invalid_stream_profile_id)
    end
  end

  defp parse_window(attrs) do
    raw_from = fetch_val(attrs, :from_us)
    raw_to = fetch_val(attrs, :to_us)

    with {:ok, from_us} <- parse_non_neg_int(raw_from),
         {:ok, to_us} <- parse_non_neg_int(raw_to),
         true <- to_us > from_us do
      if to_us - from_us <= @max_window_us do
        {:ok, from_us, to_us}
      else
        {:error, :timeline_window_too_large}
      end
    else
      _ -> {:error, :invalid_timeline_window}
    end
  end

  defp parse_non_neg_int(val) when is_integer(val) and val >= 0, do: {:ok, val}

  defp parse_non_neg_int(val) when is_binary(val) do
    case Integer.parse(String.trim(val)) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_non_neg_int(_), do: :error

  defp parse_page(val) do
    case parse_pos_int(val) do
      {:ok, n} -> n
      :error -> 1
    end
  end

  defp parse_per_page(val) do
    case parse_pos_int(val) do
      {:ok, n} -> min(n, @max_per_page)
      :error -> @default_per_page
    end
  end

  defp parse_pos_int(val) when is_integer(val) and val >= 1, do: {:ok, val}

  defp parse_pos_int(val) when is_binary(val) do
    case Integer.parse(String.trim(val)) do
      {n, ""} when n >= 1 -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_pos_int(_), do: :error

  defp normalize_mode_value(val) when val in [:smart, "smart"], do: :smart
  defp normalize_mode_value(val) when val in [:basic, "basic"], do: :basic
  defp normalize_mode_value(_), do: :all

  defp normalize_category_value(val) when val in @all_categories, do: val

  defp normalize_category_value(val) when is_binary(val) do
    case String.downcase(String.trim(val)) do
      "person" -> :person
      "vehicle" -> :vehicle
      "animal" -> :animal
      "package" -> :package
      "motion" -> :motion
      "recording" -> :recording
      _ -> :all
    end
  end

  defp normalize_category_value(_), do: :all

  defp normalize_confidence(val) when is_number(val) and val >= 0.0 and val <= 1.0 do
    Float.round(val * 1.0, 4)
  end

  defp normalize_confidence(_), do: nil

  defp normalize_min_confidence(nil), do: nil
  defp normalize_min_confidence(""), do: nil

  defp normalize_min_confidence(val) when is_number(val) do
    cond do
      val <= 0 -> nil
      val > 1.0 and val <= 100.0 -> Float.round(val / 100.0, 4)
      val > 0.0 and val <= 1.0 -> Float.round(val * 1.0, 4)
      true -> nil
    end
  end

  defp normalize_min_confidence(val) when is_binary(val) do
    case Float.parse(String.trim(val)) do
      {num, ""} -> normalize_min_confidence(num)
      _ -> nil
    end
  end

  defp normalize_min_confidence(_), do: nil

  defp filter_by_min_confidence(clips, nil), do: clips

  defp filter_by_min_confidence(clips, min_confidence) do
    Enum.filter(clips, &confidence_matches?(&1, min_confidence))
  end

  defp confidence_matches?(_clip, nil), do: true

  defp confidence_matches?(%{smart_type: :smart, confidence: conf}, min_confidence)
       when is_number(conf) and is_number(min_confidence) do
    conf >= min_confidence
  end

  defp confidence_matches?(%{smart_type: :smart}, _min_confidence), do: false
  defp confidence_matches?(_basic_clip, _min_confidence), do: true

  defp entry_id(entry) do
    fetch_val(entry, :entry_id) || fetch_val(entry, :id)
  end

  defp normalize_atom(val) when is_atom(val), do: val

  defp normalize_atom(val) when is_binary(val) do
    case val do
      "present" -> :present
      "quarantined" -> :quarantined
      "reclaiming" -> :reclaiming
      "reclaimed" -> :reclaimed
      "missing" -> :missing
      "not_required" -> :not_required
      "awaiting_binding" -> :awaiting_binding
      "pending" -> :pending
      "failed_retryable" -> :failed_retryable
      "failed_terminal" -> :failed_terminal
      "verified" -> :verified
      "deleting" -> :deleting
      "deleted" -> :deleted
      _ -> nil
    end
  end

  defp normalize_atom(_), do: nil

  defp to_map(map) when is_map(map), do: map
  defp to_map(list) when is_list(list), do: Map.new(list)

  defp fetch_val(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, val} -> val
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp fetch_val(_, _), do: nil
end
