defmodule ServiceRadar.Camera.RelaySourceResolver do
  @moduledoc """
  Resolves relay command payloads against normalized camera inventory.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.StreamProfile

  require Ash.Query

  @type relay_payload :: map()
  @type fetcher_result :: {:ok, struct() | map()} | {:error, term()}
  @type profile_fetcher :: (Ecto.UUID.t(), Ecto.UUID.t() -> fetcher_result)

  @spec resolve_start_payload(relay_payload(), keyword()) ::
          {:ok, relay_payload()} | {:error, String.t()}
  def resolve_start_payload(payload, opts \\ []) when is_map(payload) do
    if present?(Map.get(payload, :source_url)) do
      {:ok, Map.update!(payload, :source_url, &sanitize_source_url/1)}
    else
      resolve_from_inventory(payload, opts)
    end
  end

  defp resolve_from_inventory(payload, opts) do
    with {:ok, camera_source_id} <- require_uuid(payload, :camera_source_id),
         {:ok, stream_profile_id} <- require_uuid(payload, :stream_profile_id),
         {:ok, profile} <- fetch_profile(camera_source_id, stream_profile_id, opts),
         {:ok, source_url} <- require_source_url(profile) do
      {:ok,
       payload
       |> put_if_missing(:source_url, sanitize_source_url(source_url))
       |> put_if_missing(:rtsp_transport, field(profile, :rtsp_transport))
       |> put_if_missing(:codec_hint, field(profile, :codec_hint))
       |> put_if_missing(:container_hint, field(profile, :container_hint))
       |> put_if_missing(:insecure_skip_verify, insecure_skip_verify(profile, source_url))}
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

  defp require_source_url(profile) do
    source_url =
      field(profile, :source_url_override) ||
        profile
        |> field(:camera_source)
        |> field(:source_url)

    if present?(source_url) do
      {:ok, source_url}
    else
      {:error, "camera relay source_url is not available in inventory"}
    end
  end

  defp require_uuid(payload, key) do
    case Map.get(payload, key) do
      value when is_binary(value) and value != "" ->
        case Ecto.UUID.cast(value) do
          {:ok, uuid} -> {:ok, uuid}
          :error -> {:error, "#{key} must be a UUID when source_url is omitted"}
        end

      _ ->
        {:error, "#{key} is required when source_url is omitted"}
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

  defp field(nil, _key), do: nil
  defp field(value, key) when is_map(value), do: Map.get(value, key)
  defp field(_value, _key), do: nil

  defp insecure_skip_verify(profile, source_url) do
    if truthy?(field(profile, :insecure_skip_verify)) or
         truthy?(metadata_value(profile, "insecure_skip_verify")) or
         truthy?(profile |> field(:camera_source) |> metadata_value("insecure_skip_verify")) or
         protect_bootstrap_rtsps?(profile, source_url) do
      true
    end
  end

  defp protect_bootstrap_rtsps?(profile, source_url) when is_binary(source_url) do
    source = field(profile, :camera_source)

    String.starts_with?(String.downcase(String.trim(source_url)), "rtsps://") and
      (metadata_value(profile, "source") == "protect-bootstrap" or
         metadata_contains?(profile, "plugin_id", "unifi-protect") or
         metadata_contains?(source, "plugin_id", "unifi-protect"))
  end

  defp protect_bootstrap_rtsps?(_profile, _source_url), do: false

  defp metadata_contains?(value, key, needle) do
    case metadata_value(value, key) do
      metadata_value when is_binary(metadata_value) ->
        metadata_value
        |> String.downcase()
        |> String.contains?(needle)

      _ ->
        false
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
  defp metadata_atom_key("plugin_id"), do: :plugin_id
  defp metadata_atom_key("source"), do: :source
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

  defp sanitize_source_url(value) when is_binary(value) do
    trimmed = String.trim(value)

    trimmed
    |> URI.parse()
    |> strip_enable_srtp()
    |> URI.to_string()
    |> String.trim_trailing("?")
  end

  defp sanitize_source_url(value), do: value

  defp strip_enable_srtp(%URI{query: nil} = uri), do: uri

  defp strip_enable_srtp(%URI{query: query} = uri) do
    params =
      query
      |> URI.decode_query()
      |> Map.delete("enableSrtp")

    %{uri | query: if(map_size(params) == 0, do: nil, else: URI.encode_query(params))}
  end
end
