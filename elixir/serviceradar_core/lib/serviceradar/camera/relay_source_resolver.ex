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
       |> put_if_missing(:container_hint, field(profile, :container_hint))}
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

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(value), do: value not in [nil, ""]

  defp format_error(%Ash.Error.Invalid{} = error), do: Ash.Error.to_error_class(error).message
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp sanitize_source_url(value) when is_binary(value) do
    trimmed = String.trim(value)

    case URI.parse(trimmed) do
      %URI{} = uri ->
        sanitized =
          uri
          |> strip_enable_srtp()
          |> URI.to_string()
          |> String.trim_trailing("?")

        sanitized

      _other ->
        trimmed
    end
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
