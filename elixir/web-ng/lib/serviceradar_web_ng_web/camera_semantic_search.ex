defmodule ServiceRadarWebNGWeb.CameraSemanticSearch do
  @moduledoc """
  Shared input validation, RBAC, Vantage provider invocation, and result
  normalization for camera semantic clip search across HTTP API and LiveView
  surfaces (`Stage 4.1`–`4.3`).

  Search and frame overlays are served only by the Vantage provider through
  `ServiceRadarWebNG.Vantage.Client`. When the provider is not enabled, both fail
  closed with `{:error, :vantage_unavailable}`.
  """

  alias Ash.Error.Forbidden
  alias ServiceRadar.Camera.RecordingAccessAudit
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Camera.Thumbnail
  alias ServiceRadar.Identity.RBAC, as: CoreRBAC
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNG.Vantage.Client, as: VantageClient

  @search_permissions ["devices.view", "devices.cameras.recordings.view"]
  @allowed_object_classes ~w(person vehicle bicycle animal package)
  @color_pattern ~r/\A[a-z]{1,32}\z/
  @max_query_chars 256
  @default_limit 20
  @max_limit 50
  @default_window_us 86_400_000_000
  @max_window_us 31 * 86_400 * 1_000_000
  @max_window_overlay_frames 500

  @spec search_permissions() :: [String.t()]
  def search_permissions, do: @search_permissions

  @spec allowed_object_classes() :: [String.t()]
  def allowed_object_classes, do: @allowed_object_classes

  @doc """
  Pure in-memory permission check safe for disconnected `mount/3` (zero DB queries).
  """
  @spec can_search?(Scope.t() | map() | nil) :: boolean()
  def can_search?(%Scope{user: user, permissions: %MapSet{} = permissions}) when not is_nil(user) do
    CoreRBAC.Catalog.holds?(permissions, "devices.view") and
      CoreRBAC.Catalog.holds?(permissions, "devices.cameras.recordings.view")
  end

  def can_search?(_), do: false

  @spec authorize(Scope.t() | nil) :: {:ok, Scope.t()} | {:error, :unauthorized | :forbidden}
  def authorize(%Scope{user: user} = scope) when not is_nil(user) do
    case RBAC.authorize_current(scope, @search_permissions) do
      {:ok, refreshed_scope} -> {:ok, refreshed_scope}
      {:error, _reason} -> {:error, :forbidden}
    end
  end

  def authorize(_), do: {:error, :unauthorized}

  @doc """
  Validates user-supplied search query parameters and builds normalized parameters
  for the Vantage `semantic_search` RPC.
  """
  @spec validate_params(map()) :: {:ok, map()} | {:error, atom()}
  def validate_params(params) when is_map(params) do
    with {:ok, query} <- validate_query(fetch_param(params, [{"q", :q}, {"query", :query}])),
         {:ok, camera_source_id} <-
           validate_optional_uuid(fetch_param(params, [{"camera_source_id", :camera_source_id}])),
         {:ok, from_us, to_us} <-
           validate_time_bounds(
             fetch_param(params, [{"from", :from}, {"from_us", :from_us}]),
             fetch_param(params, [{"to", :to}, {"to_us", :to_us}])
           ),
         {:ok, object_class} <-
           validate_object_class(fetch_param(params, [{"object_class", :object_class}])),
         {:ok, color} <-
           validate_color(fetch_param(params, [{"color", :color}, {"dominant_color", :dominant_color}])),
         {:ok, limit} <- validate_limit(fetch_param(params, [{"limit", :limit}])) do
      normalized =
        %{
          q: query,
          query: query,
          limit: limit
        }
        |> maybe_put(:camera_source_id, camera_source_id)
        |> maybe_put(:camera_source_ids, if(camera_source_id, do: [camera_source_id]))
        |> maybe_put(:from_us, from_us)
        |> maybe_put(:to_us, to_us)
        |> maybe_put(:object_class, object_class)
        |> maybe_put(:color, color)
        |> maybe_put(:dominant_color, color)

      {:ok, normalized}
    end
  end

  def validate_params(_), do: {:error, :invalid_request}

  @doc """
  Executes an authorized semantic clip search and normalizes results with
  canonical timeline deep-link paths.
  """
  @spec execute(Scope.t() | nil, map(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute(scope, raw_params, opts \\ []) when is_list(opts) do
    authorize_fn = Keyword.get(opts, :authorize_fn, &authorize/1)
    search_fn = Keyword.get(opts, :search_fn)
    core_opts = Keyword.get(opts, :core_opts, [])

    with {:ok, refreshed_scope} <- authorize_fn.(scope),
         {:ok, search_params} <- validate_params(raw_params) do
      call_opts = Keyword.put(core_opts, :scope, refreshed_scope)

      raw_result =
        cond do
          is_function(search_fn, 2) ->
            search_fn.(search_params, call_opts)

          vantage_rpc_enabled?(opts) ->
            execute_via_vantage(refreshed_scope, search_params, opts)

          true ->
            {:error, :vantage_unavailable}
        end

      case raw_result do
        {:ok, payload} ->
          {:ok, format_response(search_params.query, payload)}

        {:error, %Forbidden{}} ->
          {:error, :forbidden}

        {:error, reason} ->
          {:error, normalize_error_reason(reason)}
      end
    end
  end

  @doc """
  Loads normalized bounding-box overlay detections for a specific visual frame.

  When `ServiceRadarWebNG.Vantage.Client.enabled?()` is `true`, enforces RBAC and
  camera source authorization in `web-ng` before calling `vantage.rpc.frame_overlay.v1`.
  Otherwise returns `{:error, :vantage_unavailable}`.
  """
  @spec get_frame_overlay(Scope.t() | nil, String.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def get_frame_overlay(scope, camera_source_id, visual_frame_id, opts \\ [])
      when is_binary(camera_source_id) and is_binary(visual_frame_id) and is_list(opts) do
    if vantage_rpc_enabled?(opts) do
      authorize_fn = Keyword.get(opts, :authorize_fn, &authorize/1)

      with {:ok, refreshed_scope} <- authorize_fn.(scope),
           {:ok, cam_uuid} <- cast_uuid(camera_source_id, :invalid_camera_source_id),
           {:ok, frame_uuid} <- cast_uuid(visual_frame_id, :invalid_visual_frame_id),
           {:ok, authorized_by_id} <- load_authorized_sources_map(refreshed_scope, opts),
           :ok <- ensure_camera_authorized(cam_uuid, authorized_by_id) do
        vantage_opts = Keyword.get(opts, :vantage_opts, [])

        VantageClient.frame_overlay(
          %{camera_source_id: cam_uuid, visual_frame_id: frame_uuid},
          vantage_opts
        )
      end
    else
      {:error, :vantage_unavailable}
    end
  end

  @doc """
  Loads overlay detections for every frame with detections in a timeline window.

  Served only by the Vantage provider (`vantage.rpc.frame_overlay.v1`) after RBAC
  and camera source authorization in web-ng; returns
  `{:error, :vantage_unavailable}` when the provider is not enabled.
  """
  @spec list_window_overlays(Scope.t() | nil, String.t(), integer(), integer(), String.t() | nil, keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def list_window_overlays(scope, camera_source_id, from_us, to_us, stream_profile_id, opts \\ [])
      when is_binary(camera_source_id) and is_integer(from_us) and is_integer(to_us) and is_list(opts) do
    if vantage_rpc_enabled?(opts) do
      authorize_fn = Keyword.get(opts, :authorize_fn, &authorize/1)

      with {:ok, refreshed_scope} <- authorize_fn.(scope),
           {:ok, cam_uuid} <- cast_uuid(camera_source_id, :invalid_camera_source_id),
           {:ok, authorized_by_id} <- load_authorized_sources_map(refreshed_scope, opts),
           :ok <- ensure_camera_authorized(cam_uuid, authorized_by_id) do
        VantageClient.frame_overlay_window(
          %{
            camera_source_id: cam_uuid,
            from_us: from_us,
            to_us: to_us,
            stream_profile_id: normalize_optional_id(stream_profile_id),
            limit: @max_window_overlay_frames
          },
          Keyword.get(opts, :vantage_opts, [])
        )
      end
    else
      {:error, :vantage_unavailable}
    end
  end

  defp vantage_rpc_enabled?(opts) do
    Keyword.get_lazy(opts, :vantage_rpc_enabled, &VantageClient.enabled?/0) == true
  end

  defp execute_via_vantage(scope, search_params, opts) do
    with {:ok, authorized_by_id} <- load_authorized_sources_map(scope, opts),
         {:ok, target_sources} <- select_target_sources(authorized_by_id, search_params) do
      authorized_ids = target_sources |> Map.keys() |> Enum.sort()

      if authorized_ids == [] do
        with :ok <-
               record_vantage_search_audit(
                 scope,
                 search_params,
                 %{},
                 map_size(authorized_by_id),
                 0,
                 0,
                 opts
               ) do
          {:ok, %{results: []}}
        end
      else
        vantage_opts = Keyword.get(opts, :vantage_opts, [])

        rpc_params =
          search_params
          |> Map.put(:authorized_camera_source_ids, authorized_ids)
          |> Map.put(:camera_sources, target_sources)

        with {:ok, payload} <- VantageClient.semantic_search(rpc_params, vantage_opts),
             results = List.wrap(Map.get(payload, :results, [])),
             audit_meta = Map.get(payload, :audit_meta, %{}),
             :ok <-
               record_vantage_search_audit(
                 scope,
                 search_params,
                 audit_meta,
                 map_size(authorized_by_id),
                 length(authorized_ids),
                 length(results),
                 opts
               ) do
          {:ok, payload}
        end
      end
    end
  end

  defp load_authorized_sources_map(scope, opts) do
    source_reader = Keyword.get(opts, :source_reader)

    raw_result =
      cond do
        is_function(source_reader, 1) -> source_reader.(scope)
        is_function(source_reader, 0) -> source_reader.()
        true -> Ash.read(Source, scope: scope)
      end

    with {:ok, rows} <- raw_result do
      list = if is_struct(rows, Ash.Page.Keyset), do: rows.results, else: List.wrap(rows)

      by_id =
        Enum.reduce(list, %{}, fn row, acc ->
          case cast_uuid(fetch_val(row, :id), :invalid_camera_source_id) do
            {:ok, uuid} ->
              Map.put(acc, uuid, %{
                display_name: fetch_val(row, :display_name),
                device_uid: fetch_val(row, :device_uid)
              })

            _ ->
              acc
          end
        end)

      {:ok, by_id}
    end
  end

  defp select_target_sources(authorized_by_id, %{camera_source_id: cam_id}) when is_binary(cam_id) do
    if Map.has_key?(authorized_by_id, cam_id) do
      {:ok, Map.take(authorized_by_id, [cam_id])}
    else
      {:error, :forbidden}
    end
  end

  defp select_target_sources(authorized_by_id, _search_params), do: {:ok, authorized_by_id}

  defp ensure_camera_authorized(cam_uuid, authorized_by_id) do
    if Map.has_key?(authorized_by_id, cam_uuid) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp cast_uuid(val, error_reason) when is_binary(val) do
    case Ecto.UUID.cast(String.trim(val)) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, error_reason}
    end
  end

  defp cast_uuid(_, error_reason), do: {:error, error_reason}

  defp record_vantage_search_audit(scope, search_params, audit_meta, authorized_count, filtered_count, result_count, opts) do
    meta = if is_map(audit_meta), do: audit_meta, else: %{}
    now_us = System.system_time(:microsecond)

    window_end_us =
      fetch_int(meta, :window_end_us) ||
        Map.get(search_params, :to_us) ||
        now_us

    window_start_us =
      case fetch_int(meta, :window_start_us) || Map.get(search_params, :from_us) do
        start_us when is_integer(start_us) and start_us < window_end_us -> start_us
        _ -> max(window_end_us - @default_window_us, 0)
      end

    window_end_us =
      if window_end_us > window_start_us, do: window_end_us, else: window_start_us + 1

    query_text = Map.get(search_params, :query) || Map.get(search_params, :q) || ""

    query_sha256 =
      fetch_val(meta, :query_sha256) ||
        :sha256
        |> :crypto.hash(String.downcase(String.trim(query_text)))
        |> Base.encode16(case: :lower)

    details = %{
      "query_text" => fetch_val(meta, :query_text) || query_text,
      "query_sha256" => query_sha256,
      "model_id" => fetch_val(meta, :model_id),
      "model_version" => fetch_val(meta, :model_version),
      "authorized_camera_count" => fetch_int(meta, :authorized_camera_count) || authorized_count,
      "filtered_camera_count" => fetch_int(meta, :filtered_camera_count) || filtered_count,
      "object_class_filter" => Map.get(search_params, :object_class),
      "dominant_color_filter" => Map.get(search_params, :dominant_color) || Map.get(search_params, :color),
      "result_count" => fetch_int(meta, :result_count) || result_count,
      "provider" => "vantage_rpc"
    }

    audit_attrs = %{
      event_kind: :semantic_search,
      actor_id: resolve_actor_id(scope),
      camera_source_id: Map.get(search_params, :camera_source_id),
      stream_profile_id: fetch_val(meta, :stream_profile_id),
      window_start_us: window_start_us,
      window_end_us: window_end_us,
      details: details
    }

    audit_writer = Keyword.get(opts, :audit_writer)

    cond do
      is_function(audit_writer, 1) ->
        case audit_writer.(audit_attrs) do
          {:ok, _} -> :ok
          :ok -> :ok
          {:error, _} = err -> err
        end

      Keyword.get(opts, :skip_db_audit, false) == true ->
        :ok

      true ->
        case RecordingAccessAudit.record(audit_attrs) do
          {:ok, _audit} -> :ok
          {:error, _} = err -> err
        end
    end
  end

  defp resolve_actor_id(%Scope{user: user}) when is_map(user) do
    case fetch_val(user, :id) || fetch_val(user, :email) do
      nil -> "unknown"
      val -> to_string(val)
    end
  end

  defp resolve_actor_id(_), do: "unknown"

  defp fetch_int(map, key) when is_map(map) do
    case fetch_val(map, key) do
      val when is_integer(val) -> val
      _ -> nil
    end
  end

  @doc """
  Formats a raw Core search response (list of hits or map wrapper) into the canonical
  Web-NG API and LiveView search result structure.
  """
  @spec format_response(String.t(), list() | map()) :: map()
  def format_response(query, raw_payload) do
    {raw_hits, top_basis, top_uncertainty} =
      case raw_payload do
        hits when is_list(hits) ->
          {hits, nil, nil}

        map when is_map(map) ->
          hits = fetch_val(map, :results) || fetch_val(map, :hits) || []
          {hits, fetch_val(map, :time_basis), fetch_val(map, :time_uncertainty)}

        _ ->
          {[], nil, nil}
      end

    normalized_hits = Enum.map(raw_hits, &normalize_hit/1)

    basis =
      stringify_basis(
        top_basis ||
          Enum.find_value(normalized_hits, & &1.time_basis) ||
          "received"
      )

    uncertainty =
      stringify_uncertainty(
        top_uncertainty ||
          Enum.find_value(normalized_hits, & &1.time_uncertainty) ||
          "unmeasured"
      )

    %{
      query: query,
      time_basis: basis,
      time_uncertainty: uncertainty,
      results: normalized_hits
    }
  end

  @doc """
  Normalizes a single semantic search hit and attaches `timeline_path`.
  """
  @spec normalize_hit(map()) :: map()
  def normalize_hit(hit) when is_map(hit) do
    camera_source_id = to_string(fetch_val(hit, :camera_source_id) || "")
    visual_frame_id = to_string(fetch_val(hit, :visual_frame_id) || "")

    best_ts_us =
      fetch_val(hit, :best_timeline_ts_us) ||
        fetch_val(hit, :peak_timeline_ts_us) ||
        fetch_val(hit, :timeline_ts_us) ||
        0

    clip_start_us =
      fetch_val(hit, :clip_start_us) ||
        fetch_val(hit, :hit_start_us) ||
        best_ts_us

    clip_end_us =
      fetch_val(hit, :clip_end_us) ||
        fetch_val(hit, :hit_end_us) ||
        max(clip_start_us + 2_000_000, best_ts_us)

    raw_score =
      fetch_val(hit, :score) ||
        fetch_val(hit, :similarity) ||
        fetch_val(hit, :peak_similarity) ||
        0.0

    score = if is_number(raw_score), do: Float.round(raw_score * 1.0, 4), else: 0.0

    raw_label = fetch_val(hit, :camera_display_name) || fetch_val(hit, :display_name)

    camera_display_name =
      if is_binary(raw_label) and String.trim(raw_label) != "" do
        String.trim(raw_label)
      else
        "Unknown camera (historical revision unavailable)"
      end

    time_basis = stringify_basis(fetch_val(hit, :time_basis) || "received")
    time_uncertainty = stringify_uncertainty(fetch_val(hit, :time_uncertainty) || "unmeasured")

    region_kind =
      to_string(
        fetch_val(hit, :region_kind) ||
          fetch_val(hit, :embedding_kind) ||
          "scene"
      )

    dominant_colors =
      hit
      |> fetch_val(:dominant_colors)
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 == ""))

    bbox = normalize_bbox(fetch_val(hit, :bbox) || fetch_val(hit, :bbox_norm))

    frame_detections =
      hit
      |> fetch_val(:frame_detections)
      |> List.wrap()
      |> Enum.filter(&is_map/1)

    caption_text =
      case fetch_val(hit, :caption_text) do
        text when is_binary(text) ->
          trimmed = String.trim(text)
          if trimmed == "", do: nil, else: trimmed

        _ ->
          nil
      end

    action_tags =
      hit
      |> fetch_val(:action_tags)
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 == ""))

    match_sources =
      hit
      |> fetch_val(:match_sources)
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 == ""))

    catalog_entry_id = normalize_optional_id(fetch_val(hit, :catalog_entry_id))
    has_block_thumbnail = normalize_optional_boolean(fetch_val(hit, :has_block_thumbnail))

    timeline_path =
      build_timeline_path(
        camera_source_id,
        clip_start_us,
        clip_end_us,
        best_ts_us,
        visual_frame_id
      )

    thumbnail_url = build_thumbnail_url(camera_source_id, catalog_entry_id, has_block_thumbnail)

    %{
      catalog_entry_id: catalog_entry_id,
      visual_frame_id: if(visual_frame_id == "", do: nil, else: visual_frame_id),
      camera_source_id: camera_source_id,
      camera_display_name: camera_display_name,
      device_uid: fetch_val(hit, :device_uid),
      stream_profile_id: fetch_val(hit, :stream_profile_id),
      clip_start_us: clip_start_us,
      clip_end_us: clip_end_us,
      best_timeline_ts_us: best_ts_us,
      time_basis: time_basis,
      time_uncertainty: time_uncertainty,
      score: score,
      region_kind: region_kind,
      object_class: fetch_val(hit, :object_class),
      dominant_colors: dominant_colors,
      bbox: bbox,
      frame_detections: frame_detections,
      has_block_thumbnail: has_block_thumbnail,
      thumbnail_url: thumbnail_url,
      caption_text: caption_text,
      action_tags: action_tags,
      match_sources: match_sources,
      timeline_path: timeline_path
    }
  end

  @doc """
  Builds the recording block thumbnail URL for a hit, or `nil` when the hit has
  no catalog entry or reports that its block has no thumbnail.
  """
  @spec build_thumbnail_url(String.t() | nil, String.t() | nil, boolean() | nil) :: String.t() | nil
  def build_thumbnail_url(camera_source_id, catalog_entry_id, has_block_thumbnail) do
    source_id = normalize_optional_id(camera_source_id)
    entry_id = normalize_optional_id(catalog_entry_id)

    if is_binary(source_id) and is_binary(entry_id) and has_block_thumbnail != false do
      Thumbnail.block_url(source_id, entry_id)
    end
  end

  @spec build_timeline_path(
          String.t(),
          integer(),
          integer(),
          integer(),
          String.t() | nil
        ) :: String.t()
  def build_timeline_path(camera_source_id, clip_start_us, clip_end_us, best_timeline_ts_us, visual_frame_id) do
    "/cameras/#{camera_source_id}/recordings?mode=timeline&from=#{clip_start_us}&to=#{clip_end_us}&seek=#{best_timeline_ts_us}&highlight_frame=#{visual_frame_id}"
  end

  defp normalize_bbox([x1, y1, x2, y2]) when is_number(x1) and is_number(y1) and is_number(x2) and is_number(y2) do
    [x1 * 1.0, y1 * 1.0, x2 * 1.0, y2 * 1.0]
  end

  defp normalize_bbox(%{} = map) do
    x1 = fetch_val(map, :x1) || fetch_val(map, :bbox_x1)
    y1 = fetch_val(map, :y1) || fetch_val(map, :bbox_y1)
    x2 = fetch_val(map, :x2) || fetch_val(map, :bbox_x2)
    y2 = fetch_val(map, :y2) || fetch_val(map, :bbox_y2)

    if is_number(x1) and is_number(y1) and is_number(x2) and is_number(y2) do
      [x1 * 1.0, y1 * 1.0, x2 * 1.0, y2 * 1.0]
    end
  end

  defp normalize_bbox(_), do: nil

  defp validate_query(raw) when is_binary(raw) do
    trimmed = String.trim(raw)
    len = String.length(trimmed)

    if String.valid?(trimmed) and len >= 1 and len <= @max_query_chars do
      {:ok, trimmed}
    else
      {:error, :invalid_query}
    end
  end

  defp validate_query(_), do: {:error, :invalid_query}

  defp validate_optional_uuid(val) when val in [nil, ""], do: {:ok, nil}

  defp validate_optional_uuid(val) when is_binary(val) do
    case Ecto.UUID.cast(String.trim(val)) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_camera_source_id}
    end
  end

  defp validate_optional_uuid(_), do: {:error, :invalid_camera_source_id}

  defp validate_time_bounds(raw_from, raw_to) do
    with {:ok, from_us} <- parse_optional_non_neg_int(raw_from, :invalid_time_window),
         {:ok, to_us} <- parse_optional_non_neg_int(raw_to, :invalid_time_window) do
      cond do
        is_integer(from_us) and is_integer(to_us) and to_us <= from_us ->
          {:error, :invalid_time_window}

        is_integer(from_us) and is_integer(to_us) and to_us - from_us > @max_window_us ->
          {:error, :window_too_large}

        true ->
          {:ok, from_us, to_us}
      end
    end
  end

  defp parse_optional_non_neg_int(val, _err) when val in [nil, ""], do: {:ok, nil}
  defp parse_optional_non_neg_int(val, _err) when is_integer(val) and val >= 0, do: {:ok, val}

  defp parse_optional_non_neg_int(val, err) when is_binary(val) do
    case Integer.parse(String.trim(val)) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, err}
    end
  end

  defp parse_optional_non_neg_int(_, err), do: {:error, err}

  defp validate_object_class(val) when val in [nil, "", "all"], do: {:ok, nil}

  defp validate_object_class(val) when is_binary(val) do
    normalized = val |> String.trim() |> String.downcase()

    if normalized in @allowed_object_classes do
      {:ok, normalized}
    else
      {:error, :invalid_object_class}
    end
  end

  defp validate_object_class(_), do: {:error, :invalid_object_class}

  defp validate_color(val) when val in [nil, "", "all"], do: {:ok, nil}

  defp validate_color(val) when is_binary(val) do
    normalized = val |> String.trim() |> String.downcase()

    if Regex.match?(@color_pattern, normalized) do
      {:ok, normalized}
    else
      {:error, :invalid_color}
    end
  end

  defp validate_color(_), do: {:error, :invalid_color}

  defp validate_limit(val) when val in [nil, ""], do: {:ok, @default_limit}

  defp validate_limit(val) when is_integer(val) do
    if val >= 1 and val <= @max_limit, do: {:ok, val}, else: {:error, :invalid_limit}
  end

  defp validate_limit(val) when is_binary(val) do
    case Integer.parse(String.trim(val)) do
      {n, ""} when n >= 1 and n <= @max_limit -> {:ok, n}
      _ -> {:error, :invalid_limit}
    end
  end

  defp validate_limit(_), do: {:error, :invalid_limit}

  defp normalize_error_reason(reason)
       when reason in [
              :forbidden,
              :permission_revoked,
              :unauthorized_camera,
              :camera_not_authorized,
              :camera_source_not_found
            ], do: :forbidden

  defp normalize_error_reason(reason)
       when reason in [:search_embedder_unavailable, :embedder_unavailable, :embedder_timeout, :nats_unavailable],
       do: :search_embedder_unavailable

  defp normalize_error_reason({reason, _detail}), do: normalize_error_reason(reason)
  defp normalize_error_reason(other), do: other

  defp stringify_basis(val) when val in [:camera_reported, "camera_reported"], do: "camera_reported"

  defp stringify_basis(_), do: "received"

  defp stringify_uncertainty(nil), do: "unmeasured"
  defp stringify_uncertainty(:unmeasured), do: "unmeasured"
  defp stringify_uncertainty(val) when is_integer(val), do: "#{val} us"
  defp stringify_uncertainty(val), do: to_string(val)

  defp fetch_param(params, pairs) do
    Enum.find_value(pairs, fn {str_key, atom_key} ->
      case Map.fetch(params, str_key) do
        {:ok, val} -> val
        :error -> Map.get(params, atom_key)
      end
    end)
  end

  defp fetch_val(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, val} -> val
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)

  defp normalize_optional_id(val) when is_binary(val) do
    trimmed = String.trim(val)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_optional_id(_), do: nil

  defp normalize_optional_boolean(val) when is_boolean(val), do: val
  defp normalize_optional_boolean(_), do: nil
end
