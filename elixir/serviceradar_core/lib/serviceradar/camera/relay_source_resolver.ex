defmodule ServiceRadar.Camera.RelaySourceResolver do
  @moduledoc """
  Completes a `camera.open_relay` payload from normalized camera inventory.

  Core holds no stream address (design D1 of the
  `resolve-camera-stream-sources-at-edge` change). The payload instead names
  the plugin assignment that discovered the camera and the vendor ids its
  plugin needs, as `source_resolver`; the agent asks that assignment to derive
  the address when the stream opens. A `source_url` a caller passes in is
  dropped, never forwarded.

  A source no plugin assignment is recorded as discovering cannot be resolved
  at the edge and fails with the relay failure class `source_resolver_missing`
  (design D5), before anything is dispatched.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.StreamProfile
  alias ServiceRadar.Inventory.DeviceLifecycle

  require Ash.Query

  @type relay_payload :: map()
  @type fetcher_result :: {:ok, struct() | map()} | {:error, term()}
  @type profile_fetcher :: (Ecto.UUID.t(), Ecto.UUID.t() -> fetcher_result)

  @source_resolver_missing "source_resolver_missing"

  @spec resolve_start_payload(relay_payload(), keyword()) ::
          {:ok, relay_payload()} | {:error, String.t()}
  def resolve_start_payload(payload, opts \\ []) when is_map(payload) do
    payload = Map.delete(payload, :source_url)

    with {:ok, camera_source_id} <- require_uuid(payload, :camera_source_id),
         {:ok, stream_profile_id} <- require_uuid(payload, :stream_profile_id),
         {:ok, profile} <- fetch_profile(camera_source_id, stream_profile_id, opts),
         :ok <- ensure_source_active(profile, opts),
         {:ok, source_resolver} <- source_resolver(profile) do
      {:ok,
       payload
       |> Map.put(:source_resolver, source_resolver)
       |> put_if_missing(:rtsp_transport, field(profile, :rtsp_transport))
       |> put_if_missing(:codec_hint, field(profile, :codec_hint))
       |> put_if_missing(:container_hint, field(profile, :container_hint))
       |> put_if_missing(:insecure_skip_verify, insecure_skip_verify(profile))}
    end
  end

  defp fetch_profile(camera_source_id, stream_profile_id, opts) do
    fetcher = Keyword.get(opts, :camera_profile_fetcher) || (&fetch_profile_from_inventory/2)

    case fetcher.(camera_source_id, stream_profile_id) do
      {:ok, nil} -> {:error, "camera relay profile not found"}
      {:ok, profile} -> {:ok, profile}
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  defp fetch_profile_from_inventory(camera_source_id, stream_profile_id) do
    StreamProfile
    |> Ash.Query.for_read(:for_relay, %{id: stream_profile_id, camera_source_id: camera_source_id})
    |> Ash.Query.load(:camera_source)
    |> Ash.read_one(actor: SystemActor.system(:camera_relay_source_resolver))
  end

  # The agent needs the discovering assignment and the vendor camera id; the vendor
  # profile id is optional (a camera's default stream has none).
  defp source_resolver(profile) do
    source = field(profile, :camera_source)
    assignment_id = field(source, :discovery_assignment_id)
    vendor_camera_id = field(source, :vendor_camera_id)

    if present?(assignment_id) and present?(vendor_camera_id) do
      {:ok,
       maybe_put(
         %{plugin_assignment_id: to_string(assignment_id), vendor_camera_id: vendor_camera_id},
         :vendor_profile_id,
         field(profile, :vendor_profile_id)
       )}
    else
      {:error, @source_resolver_missing}
    end
  end

  defp ensure_source_active(profile, opts) do
    device_uid =
      profile
      |> field(:camera_source)
      |> field(:device_uid)

    if source_active?(device_uid, opts) do
      :ok
    else
      {:error, "camera source device is inactive"}
    end
  end

  defp source_active?(device_uid, opts) do
    case Keyword.get(opts, :device_lifecycle_active?) do
      fun when is_function(fun, 1) ->
        fun.(device_uid)

      _ ->
        lifecycle_opts =
          case Keyword.get(opts, :actor) do
            nil -> []
            actor -> [actor: actor]
          end

        DeviceLifecycle.active?(device_uid, lifecycle_opts)
    end
  end

  defp require_uuid(payload, key) do
    case Map.get(payload, key) do
      value when is_binary(value) and value != "" ->
        case Ecto.UUID.cast(value) do
          {:ok, uuid} -> {:ok, uuid}
          :error -> {:error, "#{key} must be a UUID"}
        end

      _ ->
        {:error, "#{key} is required"}
    end
  end

  defp put_if_missing(payload, _key, value) when value in [nil, ""], do: payload

  defp put_if_missing(payload, key, value) do
    if present?(Map.get(payload, key)) do
      payload
    else
      Map.put(payload, key, value)
    end
  end

  defp maybe_put(map, _key, value) when value in [nil, ""], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp field(nil, _key), do: nil

  defp field(value, key) when is_map(value) do
    case Map.get(value, key) do
      %Ash.NotLoaded{} -> nil
      field_value -> field_value
    end
  end

  defp field(_value, _key), do: nil

  defp insecure_skip_verify(profile) do
    if truthy?(field(profile, :insecure_skip_verify)) or
         truthy?(metadata_value(profile, "insecure_skip_verify")) or
         truthy?(profile |> field(:camera_source) |> metadata_value("insecure_skip_verify")) do
      true
    end
  end

  defp metadata_value(value, key) do
    value
    |> field(:metadata)
    |> case do
      metadata when is_map(metadata) ->
        Map.get(metadata, key) || Map.get(metadata, metadata_atom_key(key))

      _metadata ->
        nil
    end
  end

  defp metadata_atom_key("insecure_skip_verify"), do: :insecure_skip_verify
  defp metadata_atom_key(_key), do: nil

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("1"), do: true
  defp truthy?(1), do: true
  defp truthy?(_value), do: false

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(value), do: value not in [nil, ""]

  defp format_error(%Ash.Error.Invalid{} = error), do: Ash.Error.to_error_class(error).message
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
