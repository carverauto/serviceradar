defmodule ServiceRadarWebNGWeb.DashboardFrameChannel.Events do
  @moduledoc """
  Live OCSF event subscriptions for dashboard packages that declare
  `events.subscribe`.

  EventWriter broadcasts a summary of every persisted event row on
  `ServiceRadar.Events.PubSub.rows_topic/0`. A dashboard channel subscribes to
  that topic once, matches each summary against the renderer's filters, and
  pushes only matching events.

  Delivery is authorized per row: before pushing, the channel reads the matched
  event ids through the `ServiceRadar.Monitoring.OcsfEvent` read policy as the
  viewer, and only rows that read returns are delivered. The policy is a filter,
  so a capability-style `Ash.can?` answers "allowed" for every role (the read
  merely returns nothing); reading the rows is what applies it.
  """

  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Identity.RBAC, as: CoreRBAC
  alias ServiceRadar.Monitoring.OcsfEvent

  require Ash.Query

  # Summaries are broadcast right after insert; bound the id lookup to recent
  # chunks of the hypertable.
  @visibility_window_seconds 3_600

  @capability "events.subscribe"
  @max_subscriptions 8
  @max_events_per_push 200
  @max_metadata_keys 8
  @max_metadata_depth 6
  @metadata_segment_regex ~r/\A[A-Za-z0-9_-]{1,64}\z/
  @camera_observation_permissions ["devices.view", "devices.cameras.recordings.view"]

  def capability, do: @capability
  def max_subscriptions, do: @max_subscriptions

  @doc """
  Validates a subscription request and returns its normalized filter.
  """
  def subscribe(scope, capabilities, subscriptions, params) when is_map(params) do
    with :ok <- require_capability(capabilities),
         :ok <- authorize(scope),
         {:ok, id} <- subscription_id(params["id"]),
         :ok <- ensure_capacity(subscriptions, id),
         {:ok, filter} <- normalize_filter(params["filter"]) do
      {:ok, id, filter}
    end
  end

  @doc """
  Returns the ids among `events` that the viewer's own read of `ocsf_events`
  returns, enforcing fail-closed camera observation RBAC and `Source` scoping.
  """
  def visible_ids(%{user: user} = scope, events) when not is_nil(user) and is_list(events) do
    ids = events |> Enum.map(& &1["id"]) |> Enum.filter(&is_binary/1) |> Enum.uniq()

    if ids == [] do
      MapSet.new()
    else
      since = DateTime.shift(DateTime.utc_now(), second: -@visibility_window_seconds)

      OcsfEvent
      |> Ash.Query.for_read(:read, %{}, actor: user)
      |> Ash.Query.filter(id in ^ids and time >= ^since)
      |> Ash.Query.select([:id, :log_provider, :log_name, :metadata, :device])
      |> Ash.read()
      |> case do
        {:ok, rows} -> filter_visible_rows(rows, scope, events)
        {:error, _reason} -> MapSet.new()
      end
    end
  end

  def visible_ids(_scope, _events), do: MapSet.new()

  defp filter_visible_rows([], _scope, _events), do: MapSet.new()

  defp filter_visible_rows(rows, scope, events) do
    summaries_by_id =
      Enum.reduce(events, %{}, fn event, acc ->
        case event do
          %{"id" => id} when is_binary(id) -> Map.put(acc, id, event)
          _ -> acc
        end
      end)

    has_camera_event? =
      Enum.any?(rows, fn row ->
        summary = Map.get(summaries_by_id, to_string(row.id), %{})
        camera_observation_event?(row, summary)
      end)

    authorized_camera_ids =
      if has_camera_event? do
        resolve_authorized_camera_ids(scope)
      end

    Enum.reduce(rows, MapSet.new(), fn row, acc ->
      row_id = to_string(row.id)
      summary = Map.get(summaries_by_id, row_id, %{})

      if camera_observation_event?(row, summary) do
        if camera_event_authorized?(row, authorized_camera_ids) do
          MapSet.put(acc, row_id)
        else
          acc
        end
      else
        MapSet.put(acc, row_id)
      end
    end)
  end

  defp camera_observation_event?(row, summary) do
    provider = row_or_summary_string(Map.get(row, :log_provider), summary["log_provider"])
    log_name = row_or_summary_string(Map.get(row, :log_name), summary["log_name"])
    row_sr = persisted_service_radar_meta(row)
    sum_sr = summary_service_radar_meta(summary)

    provider == "serviceradar.vantage" or
      (is_binary(log_name) and
         (String.starts_with?(log_name, "camera.vantage.") or
            String.starts_with?(log_name, "camera.analysis."))) or
      Map.get(row_sr, "source_type") == "camera_vantage" or
      Map.get(sum_sr, "source_type") == "camera_vantage" or
      present_string?(Map.get(row_sr, "camera_source_id")) or
      present_string?(Map.get(sum_sr, "camera_source_id")) or
      present_string?(summary["camera_source_id"])
  end

  defp camera_event_authorized?(_row, nil), do: false

  defp camera_event_authorized?(row, %MapSet{} = authorized_camera_ids) do
    case row |> persisted_service_radar_meta() |> Map.get("camera_source_id") do
      cam_id when is_binary(cam_id) ->
        case Ecto.UUID.cast(String.trim(cam_id)) do
          {:ok, cam_uuid} -> MapSet.member?(authorized_camera_ids, cam_uuid)
          :error -> false
        end

      _ ->
        false
    end
  end

  defp resolve_authorized_camera_ids(scope) do
    permissions = scope_permissions(scope)

    if Enum.all?(@camera_observation_permissions, &CoreRBAC.Catalog.holds?(permissions, &1)) do
      Source
      |> Ash.Query.for_read(:read, %{}, scope: scope)
      |> Ash.Query.select([:id])
      |> Ash.read(scope: scope)
      |> case do
        {:ok, sources} ->
          explicit_allow = extract_explicit_allowed_camera_ids(scope)

          Enum.reduce(sources, MapSet.new(), fn source, acc ->
            id = to_string(source.id)

            if is_nil(explicit_allow) or MapSet.member?(explicit_allow, id) do
              MapSet.put(acc, id)
            else
              acc
            end
          end)

        {:error, _reason} ->
          nil
      end
    end
  end

  defp scope_permissions(%{permissions: %MapSet{} = permissions}), do: permissions
  defp scope_permissions(%{user: user}) when not is_nil(user), do: CoreRBAC.permissions_for_user(user)
  defp scope_permissions(_), do: MapSet.new()

  defp extract_explicit_allowed_camera_ids(scope) when is_map(scope) do
    candidates = [
      Map.get(scope, :authorized_camera_source_ids),
      case Map.get(scope, :user) do
        %{} = user -> Map.get(user, :authorized_camera_source_ids)
        _ -> nil
      end
    ]

    case Enum.find(candidates, &(is_list(&1) or match?(%MapSet{}, &1))) do
      nil ->
        nil

      items ->
        Enum.reduce(items, MapSet.new(), fn item, acc ->
          case Ecto.UUID.cast(to_string(item)) do
            {:ok, uuid} -> MapSet.put(acc, uuid)
            :error -> acc
          end
        end)
    end
  end

  defp extract_explicit_allowed_camera_ids(_scope), do: nil

  defp persisted_service_radar_meta(row) do
    case Map.get(row, :metadata) do
      %{"service_radar" => %{} = sr} -> sr
      _ -> %{}
    end
  end

  defp summary_service_radar_meta(summary) when is_map(summary) do
    case summary["metadata"] do
      %{"service_radar" => %{} = sr} -> sr
      _ -> %{}
    end
  end

  defp summary_service_radar_meta(_), do: %{}

  defp row_or_summary_string(row_val, _sum_val) when is_binary(row_val) and row_val != "", do: row_val
  defp row_or_summary_string(_row_val, sum_val) when is_binary(sum_val) and sum_val != "", do: sum_val
  defp row_or_summary_string(_, _), do: nil

  defp present_string?(val) when is_binary(val), do: String.trim(val) != ""
  defp present_string?(_), do: false

  @doc """
  Returns `[{subscription_id, events}]` for every subscription that matched at
  least one summary, capped per push.
  """
  def match(subscriptions, summaries) when is_map(subscriptions) and is_list(summaries) do
    subscriptions
    |> Enum.map(fn {id, filter} ->
      {id, summaries |> Enum.filter(&matches?(filter, &1)) |> Enum.take(@max_events_per_push)}
    end)
    |> Enum.reject(fn {_id, events} -> events == [] end)
  end

  @doc false
  def matches?(filter, summary) do
    Enum.all?(filter, fn {key, expected} -> field_matches?(key, expected, summary) end)
  end

  def format_error(:capability_not_approved), do: "dashboard capability is not approved: events.subscribe"
  def format_error(:permission_denied), do: "You are not authorized to read events."
  def format_error(:invalid_subscription_id), do: "A subscription id is required."
  def format_error(:too_many_subscriptions), do: "At most #{@max_subscriptions} event subscriptions are allowed."
  def format_error({:invalid_filter, key}), do: "Unsupported event filter: #{key}"
  def format_error(_reason), do: "Event subscription failed."

  defp require_capability(capabilities) do
    if @capability in List.wrap(capabilities), do: :ok, else: {:error, :capability_not_approved}
  end

  # Row visibility is enforced at delivery (visible_ids/2); subscribing only
  # needs a signed-in viewer.
  defp authorize(%{user: user}) when not is_nil(user), do: :ok

  defp authorize(_scope), do: {:error, :permission_denied}

  defp subscription_id(id) when is_binary(id) do
    case String.trim(id) do
      "" -> {:error, :invalid_subscription_id}
      trimmed when byte_size(trimmed) <= 64 -> {:ok, trimmed}
      _long -> {:error, :invalid_subscription_id}
    end
  end

  defp subscription_id(_id), do: {:error, :invalid_subscription_id}

  defp ensure_capacity(subscriptions, id) do
    if Map.has_key?(subscriptions, id) or map_size(subscriptions) < @max_subscriptions,
      do: :ok,
      else: {:error, :too_many_subscriptions}
  end

  @doc """
  Normalizes a renderer-supplied filter. Keys are matched as strings; no atoms
  are created from input.
  """
  def normalize_filter(nil), do: {:ok, %{}}

  def normalize_filter(%{} = filter) do
    Enum.reduce_while(filter, {:ok, %{}}, fn {raw_key, value}, {:ok, acc} ->
      key = to_string(raw_key)

      cond do
        key == "metadata" ->
          merge_metadata_filter(acc, value, key)

        String.starts_with?(key, "metadata.") ->
          path_str = String.replace_prefix(key, "metadata.", "")
          merge_dotted_metadata_filter(acc, path_str, value, raw_key)

        true ->
          case normalize_entry(key, value) do
            {:ok, normalized} -> {:cont, {:ok, Map.put(acc, key, normalized)}}
            :error -> {:halt, {:error, {:invalid_filter, raw_key}}}
          end
      end
    end)
  end

  def normalize_filter(_filter), do: {:error, {:invalid_filter, "filter"}}

  defp merge_metadata_filter(acc, %{} = value, err_key) when map_size(value) > 0 do
    case flatten_metadata_entries(value, [], []) do
      {:ok, predicates} ->
        merged = Map.get(acc, "metadata", []) ++ predicates

        if length(merged) <= @max_metadata_keys do
          {:cont, {:ok, Map.put(acc, "metadata", merged)}}
        else
          {:halt, {:error, {:invalid_filter, err_key}}}
        end

      :error ->
        {:halt, {:error, {:invalid_filter, err_key}}}
    end
  end

  defp merge_metadata_filter(_acc, %{} = empty, err_key) when map_size(empty) == 0 do
    {:halt, {:error, {:invalid_filter, err_key}}}
  end

  defp merge_metadata_filter(_acc, _value, err_key), do: {:halt, {:error, {:invalid_filter, err_key}}}

  defp merge_dotted_metadata_filter(acc, path_str, value, err_key) do
    with {:ok, segments} <- split_metadata_path(path_str, 0),
         true <- scalar?(value),
         merged = Map.get(acc, "metadata", []) ++ [{segments, to_string(value)}],
         true <- length(merged) <= @max_metadata_keys do
      {:cont, {:ok, Map.put(acc, "metadata", merged)}}
    else
      _ -> {:halt, {:error, {:invalid_filter, err_key}}}
    end
  end

  defp flatten_metadata_entries(%{} = map, prefix, acc) when map_size(map) > 0 do
    map
    |> Enum.reduce_while({:ok, acc}, fn {raw_k, v}, {:ok, cur_acc} ->
      k_str = to_string(raw_k)

      case split_metadata_path(k_str, length(prefix)) do
        {:ok, segs} ->
          full_path = prefix ++ segs

          cond do
            scalar?(v) ->
              next_acc = [{full_path, to_string(v)} | cur_acc]

              if length(next_acc) <= @max_metadata_keys do
                {:cont, {:ok, next_acc}}
              else
                {:halt, :error}
              end

            is_map(v) and map_size(v) > 0 ->
              case flatten_metadata_entries(v, full_path, cur_acc) do
                {:ok, nested_acc} -> {:cont, {:ok, nested_acc}}
                :error -> {:halt, :error}
              end

            true ->
              {:halt, :error}
          end

        _ ->
          {:halt, :error}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      :error -> :error
    end
  end

  defp flatten_metadata_entries(_map, _prefix, _acc), do: :error

  defp split_metadata_path(path, base_depth) when is_binary(path) and path != "" do
    segments = String.split(path, ".")

    if segments != [] and
         base_depth + length(segments) <= @max_metadata_depth and
         Enum.all?(segments, &Regex.match?(@metadata_segment_regex, &1)) do
      {:ok, segments}
    else
      :error
    end
  end

  defp split_metadata_path(_, _), do: :error

  defp normalize_entry(key, value) when key in ["log_provider", "log_name", "device_uid", "camera_source_id"],
    do: string_set(value)

  defp normalize_entry("class_uid", value), do: integer_set(value)

  defp normalize_entry("min_severity_id", value) when is_integer(value), do: {:ok, value}

  defp normalize_entry(_key, _value), do: :error

  defp string_set(value) when is_binary(value), do: {:ok, MapSet.new([value])}

  defp string_set(values) when is_list(values) and values != [] do
    if Enum.all?(values, &is_binary/1), do: {:ok, MapSet.new(values)}, else: :error
  end

  defp string_set(_value), do: :error

  defp integer_set(value) when is_integer(value), do: {:ok, MapSet.new([value])}

  defp integer_set(values) when is_list(values) and values != [] do
    if Enum.all?(values, &is_integer/1), do: {:ok, MapSet.new(values)}, else: :error
  end

  defp integer_set(_value), do: :error

  defp scalar?(value), do: is_binary(value) or is_number(value) or is_boolean(value)

  defp field_matches?("device_uid", expected, summary), do: MapSet.member?(expected, get_in(summary, ["device", "uid"]))

  defp field_matches?("camera_source_id", %MapSet{} = expected, summary) do
    cam_id =
      summary["camera_source_id"] ||
        case summary["metadata"] do
          %{"service_radar" => %{"camera_source_id" => id}} -> id
          _ -> nil
        end

    is_binary(cam_id) and MapSet.member?(expected, cam_id)
  end

  defp field_matches?("min_severity_id", minimum, summary) do
    case summary["severity_id"] do
      severity when is_integer(severity) -> severity >= minimum
      _other -> false
    end
  end

  defp field_matches?("metadata", expected, summary) when is_list(expected) do
    metadata = summary["metadata"]

    is_map(metadata) and
      Enum.all?(expected, fn {segments, expected_str} ->
        case fetch_metadata_scalar(metadata, segments) do
          {:ok, actual_str} -> actual_str == expected_str
          :error -> false
        end
      end)
  end

  defp field_matches?(key, %MapSet{} = expected, summary), do: MapSet.member?(expected, summary[key])

  defp fetch_metadata_scalar(%{} = map, [seg]) do
    case Map.fetch(map, seg) do
      {:ok, val} ->
        if scalar?(val), do: {:ok, to_string(val)}, else: :error

      :error ->
        :error
    end
  end

  defp fetch_metadata_scalar(%{} = map, [seg | rest]) do
    case Map.fetch(map, seg) do
      {:ok, %{} = nested} -> fetch_metadata_scalar(nested, rest)
      _ -> :error
    end
  end

  defp fetch_metadata_scalar(_other, _segments), do: :error
end
