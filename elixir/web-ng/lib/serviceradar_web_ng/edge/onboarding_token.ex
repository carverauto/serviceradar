defmodule ServiceRadarWebNG.Edge.OnboardingToken do
  @moduledoc false

  @token_prefix "edgepkg-v1:"

  @type payload :: %{
          required(:pkg) => String.t(),
          required(:dl) => String.t(),
          optional(:api) => String.t()
        }

  def encode(package_id, download_token, core_api_url \\ nil) do
    payload =
      %{pkg: normalize_required_string(package_id), dl: normalize_required_string(download_token)}
      |> maybe_put_api(core_api_url)

    with :ok <- validate_payload(payload),
         {:ok, json} <- Jason.encode(payload) do
      {:ok, @token_prefix <> Base.url_encode64(json, padding: false)}
    end
  end

  def decode(raw) when is_binary(raw) do
    raw = String.trim(raw)

    with true <- String.starts_with?(raw, @token_prefix),
         encoded <- String.replace_prefix(raw, @token_prefix, ""),
         {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, payload} <- Jason.decode(json),
         payload <- atomize_payload(payload),
         :ok <- validate_payload(payload) do
      {:ok, payload}
    else
      false -> {:error, :unsupported_token_format}
      :error -> {:error, :invalid_base64}
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
      {:error, _} = error -> error
    end
  end

  def decode(_), do: {:error, :unsupported_token_format}

  defp maybe_put_api(payload, nil), do: payload

  defp maybe_put_api(payload, api) when is_binary(api) do
    api = String.trim(api)
    if api == "", do: payload, else: Map.put(payload, :api, api)
  end

  defp maybe_put_api(payload, _), do: payload

  defp atomize_payload(%{} = payload) do
    %{
      pkg: Map.get(payload, "pkg", ""),
      dl: Map.get(payload, "dl", ""),
      api: Map.get(payload, "api")
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp validate_payload(%{pkg: pkg, dl: dl} = payload) do
    cond do
      not is_binary(pkg) or pkg == "" ->
        {:error, :missing_package_id}

      not is_binary(dl) or dl == "" ->
        {:error, :missing_download_token}

      Map.has_key?(payload, :api) and not is_binary(payload.api) ->
        {:error, :invalid_core_api_url}

      true ->
        :ok
    end
  end

  defp validate_payload(_), do: {:error, :invalid_payload}

  defp normalize_required_string(value) when is_binary(value), do: String.trim(value)
  defp normalize_required_string(_), do: ""
end
