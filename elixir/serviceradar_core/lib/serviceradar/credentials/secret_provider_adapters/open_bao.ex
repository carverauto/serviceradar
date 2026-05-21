defmodule ServiceRadar.Credentials.SecretProviderAdapters.OpenBao do
  @moduledoc """
  OpenBao/HashiCorp Vault HTTP adapter for credential broker resolution.

  The adapter supports KV v2 by default. Provider records supply non-secret
  connection metadata; the OpenBao token is read from an environment variable
  such as `OPENBAO_TOKEN` or `VAULT_TOKEN`.
  """

  @behaviour ServiceRadar.Credentials.SecretProviderAdapter

  @default_timeout_ms 5_000

  @impl true
  def resolve(reference, provider, opts) do
    with {:ok, endpoint} <- endpoint(provider),
         {:ok, token} <- token(provider, opts),
         {:ok, request} <- request(endpoint, reference, provider, token, opts),
         {:ok, response} <- do_request(request, opts),
         {:ok, body} <- decode_response(response),
         {:ok, data, metadata} <- secret_data(body, reference, provider),
         {:ok, value} <- secret_value(data, reference) do
      {:ok,
       %{
         value: value,
         cache_status: :disabled,
         lease_expires_at: lease_expires_at(body),
         metadata: Map.merge(%{"adapter" => "openbao"}, metadata)
       }}
    end
  end

  @impl true
  def test(reference, provider, opts) do
    case resolve(reference, provider, opts) do
      {:ok, _resolved} -> {:ok, %{status: :success, adapter: :openbao}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp endpoint(provider) do
    provider
    |> value(:endpoint_url)
    |> case do
      endpoint when is_binary(endpoint) and endpoint != "" ->
        {:ok, String.trim_trailing(endpoint, "/")}

      _ ->
        {:error, :missing_endpoint_url}
    end
  end

  defp token(provider, opts) do
    cond do
      present?(opts[:openbao_token]) ->
        {:ok, opts[:openbao_token]}

      present?(opts[:vault_token]) ->
        {:ok, opts[:vault_token]}

      present?(System.get_env(token_env(provider))) ->
        {:ok, System.fetch_env!(token_env(provider))}

      present?(System.get_env("OPENBAO_TOKEN")) ->
        {:ok, System.fetch_env!("OPENBAO_TOKEN")}

      present?(System.get_env("VAULT_TOKEN")) ->
        {:ok, System.fetch_env!("VAULT_TOKEN")}

      true ->
        {:error, :missing_provider_token}
    end
  end

  defp token_env(provider) do
    provider
    |> metadata_value("token_env")
    |> case do
      env when is_binary(env) and env != "" -> env
      _ -> "OPENBAO_TOKEN"
    end
  end

  defp request(endpoint, reference, provider, token, opts) do
    path = secret_path(reference, provider)
    version = value(reference, :external_secret_version)

    query =
      if kv_version(provider) == 2 and present?(version) do
        [version: version]
      else
        []
      end

    headers =
      maybe_namespace_header([{"x-vault-token", token}, {"accept", "application/json"}], provider)

    {:ok,
     [
       method: :get,
       url: endpoint <> path,
       headers: headers,
       params: query,
       receive_timeout: Keyword.get(opts, :receive_timeout, @default_timeout_ms)
     ]}
  end

  defp do_request(request, opts) do
    request_fun = Keyword.get(opts, :request_fun, &Req.request/1)

    case request_fun.(request) do
      {:ok, %{status: status} = response} when status in 200..299 -> {:ok, response}
      {:ok, %{status: 403}} -> {:error, :unauthorized}
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: 429}} -> {:error, :rate_limited}
      {:ok, %{status: status}} -> {:error, {:provider_http_error, status}}
      {:error, %Req.TransportError{reason: reason}} -> {:error, {:unreachable, reason}}
      {:error, reason} -> {:error, {:unreachable, reason}}
    end
  end

  defp decode_response(%{body: body}) when is_map(body), do: {:ok, body}

  defp decode_response(%{body: body}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _ -> {:error, :invalid_reference}
    end
  end

  defp decode_response(_response), do: {:error, :invalid_reference}

  defp secret_data(body, reference, provider) do
    if kv_version(provider) == 2 do
      data = get_in(body, ["data", "data"])
      metadata = get_in(body, ["data", "metadata"]) || %{}

      if is_map(data) do
        {:ok, data,
         %{
           "kv_version" => 2,
           "secret_ref" => value(reference, :external_secret_ref),
           "metadata" => metadata
         }}
      else
        {:error, :bad_field_mapping}
      end
    else
      case Map.get(body, "data") do
        data when is_map(data) ->
          {:ok, data,
           %{"kv_version" => 1, "secret_ref" => value(reference, :external_secret_ref)}}

        _ ->
          {:error, :bad_field_mapping}
      end
    end
  end

  defp secret_value(data, reference) do
    fields = value(reference, :external_secret_fields) || %{}

    cond do
      present?(fields["value"]) ->
        value_from_field(data, fields["value"])

      present?(fields[:value]) ->
        value_from_field(data, fields[:value])

      present?(fields["field"]) ->
        value_from_field(data, fields["field"])

      present?(fields[:field]) ->
        value_from_field(data, fields[:field])

      map_size(data) == 1 ->
        data |> Map.values() |> List.first() |> stringify_secret_value()

      true ->
        data
        |> map_selected_fields(fields)
        |> Jason.encode()
    end
  end

  defp value_from_field(data, field) do
    data
    |> value(field)
    |> stringify_secret_value()
  end

  defp stringify_secret_value(value) when is_binary(value) and value != "", do: {:ok, value}

  defp stringify_secret_value(value)
       when is_integer(value) or is_float(value) or is_boolean(value),
       do: {:ok, to_string(value)}

  defp stringify_secret_value(value) when is_map(value) or is_list(value), do: Jason.encode(value)
  defp stringify_secret_value(_value), do: {:error, :bad_field_mapping}

  defp map_selected_fields(data, fields) when map_size(fields) == 0, do: data

  defp map_selected_fields(data, fields) do
    fields
    |> Map.new(fn {target_field, source_field} ->
      {to_string(target_field), value(data, source_field)}
    end)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp secret_path(reference, provider) do
    ref =
      reference
      |> value(:external_secret_ref)
      |> to_string()
      |> String.trim()
      |> String.trim_leading("/")

    cond do
      String.starts_with?(ref, "v1/") ->
        "/" <> ref

      kv_version(provider) == 2 ->
        "/v1/#{mount(provider)}/data/#{strip_mount(ref, provider)}"

      true ->
        "/v1/#{mount(provider)}/#{strip_mount(ref, provider)}"
    end
  end

  defp strip_mount(ref, provider) do
    mount = mount(provider)

    ref
    |> String.replace_prefix("#{mount}/data/", "")
    |> String.replace_prefix("#{mount}/", "")
  end

  defp mount(provider), do: metadata_value(provider, "kv_mount") || "secret"

  defp kv_version(provider) do
    provider
    |> metadata_value("kv_version")
    |> case do
      1 -> 1
      "1" -> 1
      "kv1" -> 1
      _ -> 2
    end
  end

  defp maybe_namespace_header(headers, provider) do
    case metadata_value(provider, "namespace") do
      namespace when is_binary(namespace) and namespace != "" ->
        [{"x-vault-namespace", namespace} | headers]

      _ ->
        headers
    end
  end

  defp lease_expires_at(body) do
    case Map.get(body, "lease_duration") do
      seconds when is_integer(seconds) and seconds > 0 ->
        DateTime.utc_now()
        |> DateTime.add(seconds, :second)
        |> DateTime.truncate(:second)

      _ ->
        nil
    end
  end

  defp metadata_value(provider, key) do
    provider
    |> value(:metadata)
    |> case do
      metadata when is_map(metadata) -> value(metadata, key)
      _ -> nil
    end
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp value(_map, _key), do: nil

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
