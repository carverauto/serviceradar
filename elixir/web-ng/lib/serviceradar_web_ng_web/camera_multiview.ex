defmodule ServiceRadarWebNGWeb.CameraMultiview do
  @moduledoc false

  alias ServiceRadar.Camera.RelaySession
  alias ServiceRadar.Camera.Source, as: CameraSource

  require Ash.Query

  @source_limit 96

  def open_preview_tiles(scope, count) when is_integer(count) and count > 0 do
    scope
    |> load_relay_candidates(@source_limit)
    |> open_preview_candidates(scope, count)
  end

  def open_preview_tiles(_scope, _count), do: []

  def open_source_preview(scope, camera_source_id) when is_binary(camera_source_id) do
    case CameraSource.get_by_id(camera_source_id, load: [:stream_profiles], scope: scope) do
      {:ok, source} ->
        source
        |> candidate_from_source()
        |> case do
          nil -> %{label: "Camera", detail: "Primary stream", session: nil, error: "No relay-capable stream profile"}
          candidate -> open_tile(candidate, scope)
        end

      {:error, reason} ->
        %{label: "Camera", detail: "Primary stream", session: nil, error: format_error(reason)}
    end
  end

  def open_source_preview(_scope, _camera_source_id),
    do: %{label: "Camera", detail: "Primary stream", session: nil, error: "Invalid camera source"}

  def load_relay_candidates(scope, limit \\ @source_limit) do
    case Application.get_env(:serviceradar_web_ng, :camera_relay_candidate_loader) do
      loader when is_function(loader, 2) ->
        loader.(scope, limit)

      _other ->
        load_relay_candidates_from_db(scope, limit)
    end
  end

  defp load_relay_candidates_from_db(scope, limit) do
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
        |> Enum.map(&candidate_from_source/1)
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
  def format_error(reason) when is_binary(reason), do: reason
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

  defp candidate_from_source(%{id: source_id, stream_profiles: profiles} = source) when is_list(profiles) do
    profile =
      profiles
      |> Enum.filter(&relay_eligible?/1)
      |> Enum.sort_by(&profile_preference/1)
      |> List.first()

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
          insecure_skip_verify:
            insecure_skip_verify?(profile) or insecure_skip_verify?(source) or
              protect_bootstrap_rtsps?(source, profile),
          session: nil,
          error: nil
        }
    end
  end

  defp candidate_from_source(_source), do: nil

  defp relay_eligible?(%{relay_eligible: false}), do: false
  defp relay_eligible?(_profile), do: true

  defp profile_preference(profile) do
    label =
      [
        Map.get(profile, :profile_name),
        Map.get(profile, :vendor_profile_id)
      ]
      |> first_present()
      |> to_string()
      |> String.downcase()

    cond do
      String.contains?(label, "low") -> 0
      String.contains?(label, "medium") -> 1
      String.contains?(label, "main") -> 2
      String.contains?(label, "high") -> 3
      String.contains?(label, "package") -> 4
      true -> 5
    end
  end

  defp assigned_for_relay?(source) do
    present?(Map.get(source, :assigned_agent_id)) and present?(Map.get(source, :assigned_gateway_id))
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

  defp protect_bootstrap_rtsps?(source, profile) do
    source_url =
      [
        Map.get(source, :source_url),
        Map.get(profile, :source_url)
      ]
      |> first_present()
      |> to_string()
      |> String.trim()
      |> String.downcase()

    String.starts_with?(source_url, "rtsps://") and
      (metadata_value(source, "source") == "protect-bootstrap" or
         metadata_value(profile, "source") == "protect-bootstrap" or
         metadata_contains?(source, "plugin_id", "unifi-protect") or
         metadata_contains?(profile, "plugin_id", "unifi-protect"))
  end

  defp metadata_contains?(value, key, needle) do
    value
    |> metadata_value(key)
    |> to_string()
    |> String.downcase()
    |> String.contains?(needle)
  end
end
