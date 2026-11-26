defmodule ServiceRadarWebNGWeb.Camera.VantageDisplay do
  @moduledoc """
  Defensive formatter and sanitizer for Vantage observation `display_contract`
  metadata rendered on timeline markers, bounding-box overlays, and clip modal
  previews.

  Strips all UI-code keys (`@forbidden_keys`), resolves dotted attribute paths
  without dynamic atom creation, allowlists colors and icons, and falls back
  cleanly when `display_contract` is empty (`%{}`).
  """

  alias ServiceRadar.Camera.Thumbnail

  @forbidden_keys MapSet.new(~w(
    html raw_html javascript js component component_ref live_view react ui_code
  ))

  @path_regex ~r/\A[A-Za-z0-9_][A-Za-z0-9_-]*(?:\.[A-Za-z0-9_-]+)*\z/
  @hex_color_regex ~r/\A#[0-9a-fA-F]{6}\z/
  @safe_url_regex ~r/\A(?:\/(?!\/)|https?:\/\/)/i
  @max_path_segments 8
  @max_facts 12
  @max_badges 8
  @max_value_length 240

  @color_tokens %{
    "amber" => %{
      hex: "#f59e0b",
      badge_class: "bg-amber-600/85",
      marker_class: "bg-amber-400",
      border_class: "border-amber-400/80"
    },
    "sky" => %{
      hex: "#0ea5e9",
      badge_class: "bg-sky-600/85",
      marker_class: "bg-sky-400",
      border_class: "border-sky-400/80"
    },
    "emerald" => %{
      hex: "#10b981",
      badge_class: "bg-emerald-600/85",
      marker_class: "bg-emerald-400",
      border_class: "border-emerald-400/80"
    },
    "cyan" => %{
      hex: "#06b6d4",
      badge_class: "bg-cyan-600/85",
      marker_class: "bg-cyan-400",
      border_class: "border-cyan-400/80"
    },
    "violet" => %{
      hex: "#8b5cf6",
      badge_class: "bg-violet-600/85",
      marker_class: "bg-violet-400",
      border_class: "border-violet-400/80"
    },
    "rose" => %{
      hex: "#f43f5e",
      badge_class: "bg-rose-600/85",
      marker_class: "bg-rose-400",
      border_class: "border-rose-400/80"
    },
    "slate" => %{
      hex: "#64748b",
      badge_class: "bg-slate-600/85",
      marker_class: "bg-slate-400",
      border_class: "border-slate-400/80"
    }
  }

  @default_color @color_tokens["amber"]

  @allowed_icons MapSet.new(~w(
    hero-tag
    hero-truck
    hero-shield-check
    hero-exclamation-triangle
    hero-sparkles
    hero-eye
    hero-camera
    hero-bolt
    hero-cube
    hero-user
    hero-identification
  ))

  @default_icon "hero-tag"

  @doc """
  Recursively removes `@forbidden_keys` from any `display_contract` structure
  and normalizes map keys to strings.
  """
  @spec sanitize_contract(term()) :: map()
  def sanitize_contract(%{} = contract), do: sanitize_map(contract)
  def sanitize_contract(_), do: %{}

  @doc """
  Extracts a dotted path safely from an observation struct or map.

  Never creates atoms dynamically and returns `nil` for invalid or missing paths.
  """
  @spec extract_path(map() | struct(), String.t()) :: term()
  def extract_path(record, path) when (is_map(record) or is_struct(record)) and is_binary(path) do
    trimmed = String.trim(path)

    if Regex.match?(@path_regex, trimmed) do
      segments = String.split(trimmed, ".")

      if length(segments) <= @max_path_segments do
        walk_segments(record, segments)
      end
    end
  end

  def extract_path(_record, _path), do: nil

  @doc """
  Resolves a sanitized color specification (`hex`, `badge_class`, `marker_class`, `border_class`).
  """
  @spec resolve_color(term()) :: map()
  def resolve_color(raw) when is_binary(raw) do
    trimmed = String.trim(raw)
    down = String.downcase(trimmed)

    cond do
      Map.has_key?(@color_tokens, down) ->
        Map.fetch!(@color_tokens, down)

      Regex.match?(@hex_color_regex, trimmed) ->
        Map.put(@default_color, :hex, trimmed)

      true ->
        @default_color
    end
  end

  def resolve_color(_), do: @default_color

  @doc """
  Resolves a sanitized Heroicon name from the closed allowlist.
  """
  @spec resolve_icon(term(), term()) :: String.t()
  def resolve_icon(raw_icon, category \\ nil) do
    candidate =
      case raw_icon do
        icon when is_binary(icon) -> String.trim(icon)
        _ -> nil
      end

    cond do
      is_binary(candidate) and MapSet.member?(@allowed_icons, candidate) ->
        candidate

      is_binary(category) and String.contains?(String.downcase(category), "plate") ->
        "hero-identification"

      is_binary(category) and String.contains?(String.downcase(category), "vehicle") ->
        "hero-truck"

      true ->
        @default_icon
    end
  end

  @doc """
  Sanitizes a thumbnail or crop URL, allowing only single-slash relative `/`
  paths or `http://` / `https://` URLs without control characters.

  Returns `nil` for unsafe URL schemes (such as `javascript:` or `data:`),
  protocol-relative `//` URLs, or blank/non-string values.
  """
  @spec sanitize_url(term()) :: String.t() | nil
  def sanitize_url(url) when is_binary(url) do
    trimmed = String.trim(url)

    if trimmed != "" and
         not String.contains?(trimmed, ["\r", "\n", "\0"]) and
         Regex.match?(@safe_url_regex, trimmed) do
      trimmed
    end
  end

  def sanitize_url(_), do: nil

  @doc """
  Formats a `VantageObservation` (or normalized map) together with its sanitized
  `VantagePipeline.display_contract` into safe UI display metadata.
  """
  @spec format_observation(map() | struct(), term(), String.t() | nil) :: map()
  def format_observation(observation, raw_contract \\ %{}, camera_source_id \\ nil) when is_map(observation) do
    contract = sanitize_contract(raw_contract)

    id = stringify_id(read_field(observation, "id") || read_field(observation, "vantage_observation_id"))
    cam_id = stringify_id(camera_source_id || read_field(observation, "camera_source_id"))

    category =
      to_string(read_field(observation, "category") || read_field(observation, "observation_category") || "observation")

    raw_label = read_field(observation, "label") || read_field(observation, "observation_label")
    confidence = normalize_confidence(read_field(observation, "confidence") || read_field(observation, "score"))
    ts_us = read_field(observation, "timeline_ts_us")
    time_basis = to_string(read_field(observation, "time_basis") || "received")
    source_mode = to_string(read_field(observation, "source_mode") || "recorded_block")
    pipeline_id = read_field(observation, "pipeline_id")
    signal_schema_id = read_field(observation, "signal_schema_id")
    display_contract_id = read_field(observation, "display_contract_id")
    bbox = normalize_bbox(read_field(observation, "bbox"))
    has_crop = read_field(observation, "has_crop") == true

    crop_url =
      if has_crop and is_binary(cam_id) and cam_id != "" and is_binary(id) and id != "" do
        sanitize_url(Thumbnail.vantage_crop_url(cam_id, id))
      end

    color_spec =
      resolve_color(
        contract["color"] ||
          contract["badge_color"] ||
          get_in(contract, ["overlay", "color"]) ||
          get_in(contract, ["badge", "color"])
      )

    icon = resolve_icon(contract["icon"] || get_in(contract, ["badge", "icon"]), category)

    contract_label =
      case contract["label_path"] do
        path when is_binary(path) -> extract_path(observation, path)
        _ -> nil
      end

    display_label =
      format_scalar(contract_label) ||
        format_scalar(raw_label) ||
        category

    {summary, facts, badges} = extract_widgets(observation, contract)

    facts =
      if facts == [] do
        default_facts(observation)
      else
        facts
      end

    %{
      id: id,
      camera_source_id: cam_id,
      label: display_label,
      category: category,
      confidence: confidence,
      timeline_ts_us: ts_us,
      time_basis: time_basis,
      source_mode: source_mode,
      bbox: bbox,
      pipeline_id: pipeline_id && to_string(pipeline_id),
      signal_schema_id: signal_schema_id && to_string(signal_schema_id),
      display_contract_id: display_contract_id && to_string(display_contract_id),
      color_hex: color_spec.hex,
      badge_class: color_spec.badge_class,
      marker_class: color_spec.marker_class,
      border_class: color_spec.border_class,
      icon: icon,
      has_crop: has_crop,
      crop_url: crop_url,
      summary: summary,
      facts: Enum.take(facts, @max_facts),
      badges: Enum.take(badges, @max_badges)
    }
  end

  defp extract_widgets(observation, contract) do
    widgets = List.wrap(contract["widgets"])

    summary =
      Enum.find_value(widgets, fn
        %{"type" => "summary"} = w ->
          msg =
            case w["message"] do
              path when is_binary(path) -> extract_path(observation, path) || path
              _ -> nil
            end

          format_scalar(msg)

        _ ->
          nil
      end)

    facts =
      widgets
      |> Enum.filter(&(is_map(&1) and &1["type"] == "facts"))
      |> Enum.flat_map(fn w ->
        w
        |> Map.get("fields", [])
        |> List.wrap()
        |> Enum.reduce([], fn field, acc ->
          with %{"label" => lbl, "path" => path} <- field,
               true <- is_binary(lbl) and is_binary(path),
               val when not is_nil(val) <- extract_path(observation, path),
               str when is_binary(str) <- format_scalar(val) do
            [%{label: truncate_text(lbl), value: str} | acc]
          else
            _ -> acc
          end
        end)
        |> Enum.reverse()
      end)

    badges =
      widgets
      |> Enum.filter(&(is_map(&1) and &1["type"] == "badges"))
      |> Enum.flat_map(fn w ->
        w
        |> Map.get("fields", [])
        |> List.wrap()
        |> Enum.reduce([], fn field, acc ->
          with %{"label" => lbl, "path" => path} <- field,
               true <- is_binary(lbl) and is_binary(path),
               val when not is_nil(val) <- extract_path(observation, path),
               str when is_binary(str) <- format_scalar(val) do
            tone = if is_binary(field["tone"]), do: field["tone"], else: "neutral"
            [%{label: truncate_text(lbl), value: str, tone: tone} | acc]
          else
            _ -> acc
          end
        end)
        |> Enum.reverse()
      end)

    {summary, facts, badges}
  end

  defp default_facts(observation) do
    attrs =
      case read_field(observation, "attributes") do
        %{} = map -> map
        _ -> %{}
      end

    attrs
    |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
    |> Enum.reduce([], fn {k, v}, acc ->
      key_str = to_string(k)

      if MapSet.member?(@forbidden_keys, String.downcase(key_str)) do
        acc
      else
        case format_scalar(v) do
          nil -> acc
          val_str -> [%{label: humanize_key(key_str), value: val_str} | acc]
        end
      end
    end)
    |> Enum.reverse()
    |> Enum.take(@max_facts)
  end

  defp humanize_key(key) do
    key
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp sanitize_map(map) do
    Enum.reduce(map, %{}, fn {k, v}, acc ->
      key_str = to_string(k)

      if MapSet.member?(@forbidden_keys, String.downcase(key_str)) do
        acc
      else
        Map.put(acc, key_str, sanitize_value(v))
      end
    end)
  end

  defp sanitize_value(%{} = map), do: sanitize_map(map)
  defp sanitize_value(list) when is_list(list), do: Enum.map(list, &sanitize_value/1)
  defp sanitize_value(val), do: val

  defp walk_segments(nil, _segments), do: nil
  defp walk_segments(value, []), do: value

  defp walk_segments(current, [seg | rest]) when is_map(current) do
    if MapSet.member?(@forbidden_keys, String.downcase(seg)) do
      nil
    else
      case fetch_map_segment(current, seg) do
        {:ok, next} -> walk_segments(next, rest)
        :error -> nil
      end
    end
  end

  defp walk_segments(current, [seg | rest]) when is_list(current) do
    case Integer.parse(seg) do
      {idx, ""} when idx >= 0 ->
        case Enum.fetch(current, idx) do
          {:ok, next} -> walk_segments(next, rest)
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp walk_segments(_current, _segments), do: nil

  defp fetch_map_segment(map, seg) do
    case Map.fetch(map, seg) do
      {:ok, val} ->
        {:ok, val}

      :error ->
        try do
          atom_key = String.to_existing_atom(seg)
          Map.fetch(map, atom_key)
        rescue
          ArgumentError -> :error
        end
    end
  end

  defp read_field(map, key) when is_map(map) and is_binary(key) do
    case fetch_map_segment(map, key) do
      {:ok, val} -> val
      :error -> nil
    end
  end

  defp stringify_id(nil), do: nil
  defp stringify_id(""), do: nil
  defp stringify_id(val), do: to_string(val)

  defp normalize_confidence(val) when is_number(val), do: Float.round(max(min(val * 1.0, 1.0), 0.0), 4)

  defp normalize_confidence(_), do: nil

  defp normalize_bbox([x1, y1, x2, y2]) when is_number(x1) and is_number(y1) and is_number(x2) and is_number(y2) do
    [x1 * 1.0, y1 * 1.0, x2 * 1.0, y2 * 1.0]
  end

  defp normalize_bbox(%{} = map) do
    x1 = read_field(map, "x1") || read_field(map, "bbox_x1")
    y1 = read_field(map, "y1") || read_field(map, "bbox_y1")
    x2 = read_field(map, "x2") || read_field(map, "bbox_x2")
    y2 = read_field(map, "y2") || read_field(map, "bbox_y2")

    if is_number(x1) and is_number(y1) and is_number(x2) and is_number(y2) do
      [x1 * 1.0, y1 * 1.0, x2 * 1.0, y2 * 1.0]
    end
  end

  defp normalize_bbox(_), do: nil

  defp format_scalar(nil), do: nil

  defp format_scalar(val) when is_binary(val) do
    trimmed = String.trim(val)
    if trimmed == "", do: nil, else: truncate_text(trimmed)
  end

  defp format_scalar(val) when is_boolean(val), do: to_string(val)
  defp format_scalar(val) when is_integer(val), do: Integer.to_string(val)
  defp format_scalar(val) when is_float(val), do: Float.to_string(Float.round(val, 4))
  defp format_scalar(val) when is_atom(val), do: Atom.to_string(val)
  defp format_scalar(_), do: nil

  defp truncate_text(text) when byte_size(text) > @max_value_length, do: String.slice(text, 0, @max_value_length)

  defp truncate_text(text), do: text
end
