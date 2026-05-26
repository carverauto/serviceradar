defmodule ServiceRadar.Integrations.ArmisClient do
  @moduledoc """
  Shared helpers for Armis API authentication and authenticated requests.
  """

  require Logger

  @access_token_path "/api/v1/access_token/"

  @type token_state :: %{
          token: String.t(),
          token_refreshed: boolean()
        }

  @spec token_state(String.t()) :: token_state()
  def token_state(token) when is_binary(token) do
    %{token: token, token_refreshed: false}
  end

  @spec fetch_access_token(struct() | map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def fetch_access_token(source, opts \\ []) do
    fetcher = Keyword.get(opts, :token_fetcher, &default_token_fetcher/1)
    fetcher.(source)
  end

  @spec authenticated_request(
          struct() | map(),
          token_state(),
          function(),
          String.t(),
          atom(),
          term(),
          keyword(),
          keyword()
        ) :: {:ok, map(), token_state()} | {:error, term(), token_state()}
  def authenticated_request(
        source,
        token_state,
        request,
        path,
        method,
        body,
        request_opts,
        opts \\ []
      ) do
    case request_with_token(token_state.token, request, path, method, body, request_opts) do
      {:ok, %{status: 401} = response} ->
        maybe_refresh_and_retry(
          source,
          token_state,
          request,
          path,
          method,
          body,
          request_opts,
          opts,
          response
        )

      {:ok, response} ->
        {:ok, response, token_state}

      {:error, reason} ->
        {:error, reason, token_state}
    end
  end

  defp maybe_refresh_and_retry(
         _source,
         %{token_refreshed: true} = token_state,
         _request,
         _path,
         _method,
         _body,
         _request_opts,
         _opts,
         response
       ) do
    {:ok, response, token_state}
  end

  defp maybe_refresh_and_retry(
         source,
         token_state,
         request,
         path,
         method,
         body,
         request_opts,
         opts,
         response
       ) do
    Logger.warning("Armis request unauthorized; refreshing access token",
      integration_source_id: inspect(Map.get(source, :id)),
      endpoint: Map.get(source, :endpoint),
      path: path
    )

    case fetch_access_token(source, opts) do
      {:ok, refreshed_token} ->
        refreshed_state = %{token_state | token: refreshed_token, token_refreshed: true}

        case request_with_token(refreshed_token, request, path, method, body, request_opts) do
          {:ok, response} -> {:ok, response, refreshed_state}
          {:error, reason} -> {:error, reason, refreshed_state}
        end

      {:error, reason} ->
        Logger.warning("Failed to refresh Armis access token",
          integration_source_id: inspect(Map.get(source, :id)),
          endpoint: Map.get(source, :endpoint),
          path: path,
          reason: inspect(reason)
        )

        refresh_error = {
          :token_refresh_failed,
          reason,
          {:unexpected_status, 401, Map.get(response, :body)}
        }

        {:error, refresh_error, %{token_state | token_refreshed: true}}
    end
  end

  defp request_with_token(token, request, path, method, body, request_opts) do
    request.(path, method, request_headers(token), body, request_opts)
  end

  defp default_token_fetcher(source) do
    credentials = credentials(source)

    case armis_secret_key(credentials) do
      secret_key when is_binary(secret_key) and secret_key != "" ->
        fetch_access_token_with_secret(source, secret_key)

      _ ->
        {:error, :missing_secret_key}
    end
  end

  defp fetch_access_token_with_secret(source, secret_key) do
    body = %{"secret_key" => secret_key}

    case default_form_request(
           @access_token_path,
           :post,
           %{
             "content-type" => "application/x-www-form-urlencoded",
             "accept" => "application/json"
           },
           body,
           request_options(source)
         ) do
      {:ok, %{status: status, body: %{"data" => %{"access_token" => token}}}}
      when status in 200..299 and is_binary(token) and token != "" ->
        {:ok, token}

      {:ok, %{status: status, body: %{"data" => %{"access_token" => token}}}}
      when status in 200..299 and is_binary(token) ->
        {:error, :missing_access_token}

      {:ok, %{status: status, body: body}} ->
        {:error, {:token_request_failed, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp credentials(source) do
    source
    |> Map.get(:credentials, %{})
    |> case do
      %Ash.NotLoaded{} -> %{}
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp armis_secret_key(credentials) do
    Enum.find_value(
      ["secret_key", :secret_key, "api_secret", :api_secret],
      "",
      fn key ->
        case Map.get(credentials, key) do
          value when is_binary(value) ->
            value = String.trim(value)
            if value == "", do: nil, else: value

          _ ->
            nil
        end
      end
    )
  end

  defp request_headers(token) do
    %{
      "Authorization" => authorization_header(token),
      "Content-Type" => "application/json",
      "Accept" => "application/json"
    }
  end

  defp authorization_header(token) when is_binary(token) do
    token = String.trim(token)

    if Regex.match?(~r/^[A-Za-z]+\s+\S+/, token) do
      token
    else
      "Bearer #{token}"
    end
  end

  defp request_options(source) do
    [base_url: Map.fetch!(source, :endpoint)]
  end

  defp default_form_request(path, method, headers, body, opts) do
    request =
      [method: method, url: path, form: body, headers: Enum.to_list(headers)]
      |> Req.new()
      |> Req.merge(opts)

    case Req.request(request) do
      {:ok, %Req.Response{status: status, body: response_body}} ->
        {:ok, %{status: status, body: response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
