defmodule ServiceRadarWebNGWeb.CameraMultiview do
  @moduledoc false

  alias ServiceRadar.Camera.RelayPubSub
  alias ServiceRadar.Camera.RelaySession
  alias ServiceRadar.Camera.RelaySourceFailure
  alias ServiceRadar.Camera.Source, as: CameraSource

  require Ash.Query

  @source_limit 96
  @quality_options ["auto", "low", "medium", "high"]
  # Tiles follow relay state broadcasts; this timer is only a fallback for a
  # missed broadcast and for a session that never leaves `opening`, which
  # stale_pending_session?/1 times out after 45s. Tiles used to re-read their
  # session from the database every second, per tile, per viewer.
  @default_fallback_refresh_ms 15_000

  def quality_options, do: @quality_options

  def normalize_quality(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()
    if normalized in @quality_options, do: normalized, else: "auto"
  end

  def normalize_quality(value) when is_atom(value), do: value |> Atom.to_string() |> normalize_quality()
  def normalize_quality(_), do: "auto"

  def open_preview_tiles(scope, count, opts \\ [])

  def open_preview_tiles(scope, count, opts) when is_integer(count) and count > 0 and is_list(opts) do
    quality = opts |> Keyword.get(:quality, "auto") |> normalize_quality()
    loader_opts = Keyword.merge(opts, quality: quality, layout_count: count)

    scope
    |> load_relay_candidates(@source_limit, loader_opts)
    |> open_preview_candidates(scope, count)
  end

  def open_preview_tiles(_scope, _count, _opts), do: []

  def open_source_preview(scope, camera_source_id, opts \\ [])

  def open_source_preview(scope, camera_source_id, opts) when is_binary(camera_source_id) and is_list(opts) do
    quality = opts |> Keyword.get(:quality, "high") |> normalize_quality()
    profile_id = Keyword.get(opts, :stream_profile_id)

    case CameraSource.get_by_id(camera_source_id, load: [:stream_profiles], scope: scope) do
      {:ok, source} ->
        source
        |> candidate_from_source(quality: quality, stream_profile_id: profile_id, layout_count: 1)
        |> case do
          nil -> %{label: "Camera", detail: "Primary stream", session: nil, error: preview_unavailable_reason(source)}
          candidate -> open_tile(candidate, scope)
        end

      {:error, reason} ->
        %{label: "Camera", detail: "Primary stream", session: nil, error: format_error(reason)}
    end
  end

  def open_source_preview(_scope, _camera_source_id, _opts),
    do: %{label: "Camera", detail: "Primary stream", session: nil, error: "Invalid camera source"}

  def load_relay_candidates(scope, limit \\ @source_limit, opts \\ []) do
    case Application.get_env(:serviceradar_web_ng, :camera_relay_candidate_loader) do
      loader when is_function(loader, 3) ->
        loader.(scope, limit, opts)

      loader when is_function(loader, 2) ->
        loader.(scope, limit)

      _other ->
        load_relay_candidates_from_db(scope, limit, opts)
    end
  end

  defp load_relay_candidates_from_db(scope, limit, opts) do
    query =
      CameraSource
      |> Ash.Query.for_read(:read)
      |> Ash.Query.load(:stream_profiles)
      |> Ash.Query.sort(inserted_at: :asc)
      |> Ash.Query.limit(limit)

    case Ash.read(query, scope: scope) do
      {:ok, results} ->
        results
        |> page_results()
        |> Enum.map(&candidate_from_source(&1, opts))
        |> Enum.reject(&is_nil/1)

      {:error, _reason} ->
        []
    end
  end

  defp open_preview_candidates(candidates, scope, count) when is_list(candidates) do
    {opened, failed} =
      Enum.reduce_while(candidates, {[], []}, fn candidate, {opened, failed} ->
        tile = open_tile(candidate, scope)

        if session_id(tile) do
          opened = [tile | opened]

          if length(opened) >= count do
            {:halt, {opened, failed}}
          else
            {:cont, {opened, failed}}
          end
        else
          {:cont, {opened, [tile | failed]}}
        end
      end)

    Enum.take(Enum.reverse(opened, Enum.reverse(failed)), count)
  end

  defp open_preview_candidates(_candidates, _scope, _count), do: []

  @doc """
  Subscribes the calling LiveView to relay state for the tile's session, once.
  `subscribed` is the set of session ids already subscribed; returns it updated.
  """
  def subscribe_relay_state(subscribed, tile) do
    case session_id(tile) do
      session_id when is_binary(session_id) ->
        if MapSet.member?(subscribed, session_id) do
          subscribed
        else
          :ok = RelayPubSub.subscribe(session_id)
          MapSet.put(subscribed, session_id)
        end

      _ ->
        subscribed
    end
  end

  @doc "Fallback refresh interval for camera tiles (`:camera_relay_poll_interval_ms`)."
  def fallback_refresh_ms do
    case Application.get_env(:serviceradar_web_ng, :camera_relay_poll_interval_ms, @default_fallback_refresh_ms) do
      value when is_integer(value) and value > 0 -> value
      _other -> @default_fallback_refresh_ms
    end
  end

  def refresh_tile_session(scope, tile) when is_map(tile) do
    case session_id(tile) do
      session_id when is_binary(session_id) ->
        case fetch_session(scope, session_id) do
          {:ok, nil} -> Map.put(tile, :session, nil)
          {:ok, session} -> refresh_or_retry_session(scope, tile, session)
          {:error, reason} -> Map.put(tile, :error, format_error(reason))
        end

      _ ->
        tile
    end
  end

  def refresh_tile_session(_scope, tile), do: tile

  def session_id(%{session: %{id: session_id}}) when is_binary(session_id), do: session_id
  def session_id(_tile), do: nil

  def format_error({:agent_offline, agent_id}) when is_binary(agent_id), do: "Assigned agent #{agent_id} is offline"

  def format_error({:agent_offline, _agent_id}), do: "Assigned agent is offline"
  def format_error(:forbidden), do: "Not authorized for camera relay access"
  def format_error(:invalid_uuid), do: "Invalid camera relay request"
  def format_error(reason) when is_binary(reason), do: RelaySourceFailure.describe(reason) || reason
  def format_error(reason), do: inspect(reason)

  defp open_tile(candidate, scope) do
    opts = maybe_put_insecure_skip_verify([scope: scope], candidate)

    case relay_session_manager().request_open(
           candidate.camera_source_id,
           candidate.stream_profile_id,
           opts
         ) do
      {:ok, session} ->
        Map.put(candidate, :session, session)

      {:error, reason} ->
        candidate
        |> Map.put(:session, nil)
        |> Map.put(:error, format_error(reason))
    end
  end

  defp refresh_or_retry_session(scope, tile, session) do
    cond do
      stale_pending_session?(session) and not Map.get(tile, :relay_retry_attempted, false) ->
        tile
        |> Map.put(:session, nil)
        |> Map.put(:relay_retry_attempted, true)
        |> open_tile(scope)

      stale_pending_session?(session) ->
        tile
        |> Map.put(:session, nil)
        |> Map.put(:error, "Relay opening timed out")

      true ->
        Map.put(tile, :session, session)
    end
  end

  defp candidate_from_source(%{id: source_id, stream_profiles: profiles} = source, opts) when is_list(profiles) do
    quality = opts |> Keyword.get(:quality, "auto") |> normalize_quality()
    layout_count = Keyword.get(opts, :layout_count)
    requested_profile_id = Keyword.get(opts, :stream_profile_id)
    profile = select_profile_for_quality(profiles, quality, layout_count, requested_profile_id)

    cond do
      is_nil(profile) ->
        nil

      not assigned_for_relay?(source) ->
        nil

      unavailable?(source) ->
        nil

      true ->
        %{
          camera_source_id: source_id,
          stream_profile_id: profile.id,
          label: camera_label(source),
          detail: profile_label(profile),
          source_status: Map.get(source, :availability_status),
          insecure_skip_verify: insecure_skip_verify?(profile) or insecure_skip_verify?(source),
          session: nil,
          error: nil
        }
    end
  end

  defp candidate_from_source(_source, _opts), do: nil

  @doc """
  Selects the best relay-eligible stream profile for the requested `quality`
  (`"auto" | "low" | "medium" | "high"`) and optional `layout_count` /
  explicit `requested_profile_id`.
  """
  def select_profile_for_quality(profiles, quality \\ "auto", layout_count \\ nil, requested_profile_id \\ nil)

  def select_profile_for_quality(profiles, quality, layout_count, requested_profile_id) when is_list(profiles) do
    eligible = Enum.filter(profiles, &relay_eligible?/1)

    explicit =
      if is_binary(requested_profile_id) and String.trim(requested_profile_id) != "" do
        Enum.find(eligible, &(to_string(Map.get(&1, :id)) == String.trim(requested_profile_id)))
      end

    explicit ||
      eligible
      |> Enum.sort_by(&profile_preference(&1, effective_quality(quality, layout_count)))
      |> List.first()
  end

  def select_profile_for_quality(_profiles, _quality, _layout_count, _requested_profile_id), do: nil

  defp effective_quality("auto", layout_count) when is_integer(layout_count) and layout_count <= 4, do: "medium"
  defp effective_quality("auto", _layout_count), do: "low"
  defp effective_quality(quality, _layout_count), do: normalize_quality(quality)

  defp relay_eligible?(%{relay_eligible: false}), do: false
  defp relay_eligible?(_profile), do: true

  defp profile_preference(profile, quality) do
    label =
      [
        Map.get(profile, :profile_name),
        Map.get(profile, :vendor_profile_id)
      ]
      |> first_present()
      |> to_string()
      |> String.downcase()

    tier =
      cond do
        String.contains?(label, "high") -> :high
        String.contains?(label, "main") -> :main
        String.contains?(label, "medium") or String.contains?(label, "med") -> :medium
        String.contains?(label, "low") or String.contains?(label, "sub") -> :low
        String.contains?(label, "package") -> :package
        true -> :other
      end

    case quality do
      "high" ->
        Map.get(%{high: 0, main: 1, medium: 2, low: 3, package: 4, other: 5}, tier, 5)

      "medium" ->
        Map.get(%{medium: 0, main: 1, high: 2, low: 3, package: 4, other: 5}, tier, 5)

      _low ->
        Map.get(%{low: 0, medium: 1, main: 2, high: 3, package: 4, other: 5}, tier, 5)
    end
  end

  # Only the agent is required: the stored gateway is a hint, and core resolves
  # the agent's live control-session gateway when it opens the relay.
  defp assigned_for_relay?(source), do: present?(Map.get(source, :assigned_agent_id))

  defp preview_unavailable_reason(source) do
    if assigned_for_relay?(source),
      do: "No relay-capable stream profile",
      else: "Camera source has no assigned agent"
  end

  defp unavailable?(source) do
    status =
      source
      |> Map.get(:availability_status)
      |> to_string()
      |> String.downcase()

    status in ["offline", "unavailable", "disabled"]
  end

  defp camera_label(source) do
    first_present([
      Map.get(source, :display_name),
      Map.get(source, :vendor_camera_id),
      Map.get(source, :device_uid),
      "Camera"
    ])
  end

  defp profile_label(profile) do
    first_present([
      Map.get(profile, :profile_name),
      Map.get(profile, :vendor_profile_id),
      "Primary stream"
    ])
  end

  defp fetch_session(scope, session_id) do
    fetcher =
      Application.get_env(
        :serviceradar_web_ng,
        :camera_relay_session_fetcher,
        fn id, opts -> RelaySession.get_by_id(id, opts) end
      )

    fetcher.(session_id, scope: scope)
  end

  defp relay_session_manager do
    Application.get_env(
      :serviceradar_web_ng,
      :camera_relay_session_manager,
      ServiceRadar.Camera.RelaySessionManager
    )
  end

  defp page_results(%Ash.Page.Keyset{results: results}), do: results
  defp page_results(%Ash.Page.Offset{results: results}), do: results
  defp page_results(results) when is_list(results), do: results
  defp page_results(_), do: []

  defp first_present(values) do
    Enum.find_value(values, fn value ->
      if present?(value), do: to_string(value)
    end)
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_value), do: true

  defp maybe_put_insecure_skip_verify(opts, %{insecure_skip_verify: true}) do
    Keyword.put(opts, :insecure_skip_verify, true)
  end

  defp maybe_put_insecure_skip_verify(opts, _candidate), do: opts

  defp stale_pending_session?(%{status: status, media_ingest_id: media_ingest_id} = session)
       when status in [:requested, :opening, "requested", "opening"] do
    not present?(media_ingest_id) and older_than?(Map.get(session, :updated_at), 45)
  end

  defp stale_pending_session?(_session), do: false

  defp older_than?(%NaiveDateTime{} = value, seconds) do
    NaiveDateTime.diff(NaiveDateTime.utc_now(), value, :second) > seconds
  end

  defp older_than?(%DateTime{} = value, seconds) do
    DateTime.diff(DateTime.utc_now(), value, :second) > seconds
  end

  defp older_than?(_value, _seconds), do: false

  defp insecure_skip_verify?(value) do
    truthy?(Map.get(value, :insecure_skip_verify)) or
      truthy?(metadata_value(value, "insecure_skip_verify"))
  end

  defp metadata_value(value, key) do
    value
    |> Map.get(:metadata)
    |> case do
      metadata when is_map(metadata) -> Map.get(metadata, key) || Map.get(metadata, :insecure_skip_verify)
      _metadata -> nil
    end
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("1"), do: true
  defp truthy?(1), do: true
  defp truthy?(_value), do: false
end
