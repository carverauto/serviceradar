defmodule ServiceRadarWebNGWeb.CliPkce do
  @moduledoc """
  Request checks for `serviceradar-cli auth login --web`.

  The CLI sends `GET /api/v1/cli/auth/authorize` and then exchanges the
  returned code at `POST /api/v1/cli/auth/token`. The redirect is only
  allowed to be the CLI's own loopback callback, `http://127.0.0.1:<port>/cli/auth/callback`.
  """

  @callback_path "/cli/auth/callback"
  @client_id "serviceradar-cli"
  @challenge ~r/\A[A-Za-z0-9_-]{43}\z/
  @verifier ~r/\A[A-Za-z0-9~._-]{43,128}\z/

  def client_id, do: @client_id

  @doc """
  Returns `:ok` when the authorize query is one this server will consent,
  otherwise `{:error, :invalid_request}`.
  """
  def validate_authorize(params, allowed_scopes) when is_map(params) and is_list(allowed_scopes) do
    with :ok <- equals(params["response_type"], "code"),
         :ok <- equals(params["client_id"], @client_id),
         :ok <- equals(params["code_challenge_method"], "S256"),
         :ok <- challenge(params["code_challenge"]),
         :ok <- redirect_uri(params["redirect_uri"]),
         :ok <- state(params["state"]),
         :ok <- scope(params["scope"], allowed_scopes) do
      {:ok,
       %{
         client_id: @client_id,
         redirect_uri: params["redirect_uri"],
         code_challenge: params["code_challenge"],
         scope: params["scope"],
         state: params["state"]
       }}
    end
  end

  def validate_authorize(_, _), do: {:error, :invalid_request}

  def redirect_uri(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{
        scheme: "http",
        host: "127.0.0.1",
        path: @callback_path,
        userinfo: nil,
        query: nil,
        fragment: nil,
        port: port
      }
      when is_integer(port) and port > 0 and port < 65_536 ->
        # URI.parse fills in port 80 when the URI omits it. The CLI always
        # sends an explicit port, and a defaulted one is not that listener.
        if String.contains?(uri, ":" <> Integer.to_string(port)),
          do: :ok,
          else: {:error, :invalid_request}

      _ ->
        {:error, :invalid_request}
    end
  end

  def redirect_uri(_), do: {:error, :invalid_request}

  @doc """
  Compares a stored S256 challenge with the verifier the CLI sends back.
  """
  def challenge_matches?(challenge, verifier) when is_binary(challenge) and is_binary(verifier) do
    byte_size(challenge) == 43 and Regex.match?(@verifier, verifier) and
      secure_equal?(
        :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false),
        challenge
      )
  end

  def challenge_matches?(_, _), do: false

  defp challenge(value) when is_binary(value) do
    if Regex.match?(@challenge, value), do: :ok, else: {:error, :invalid_request}
  end

  defp challenge(_), do: {:error, :invalid_request}

  defp state(value) when is_binary(value) and value != "" and byte_size(value) <= 256, do: :ok
  defp state(_), do: {:error, :invalid_request}

  defp scope(value, allowed) when is_binary(value) and value != "" do
    requested = String.split(value, ~r/[\s,]+/, trim: true)

    if requested != [] and Enum.all?(requested, &(&1 in allowed)) do
      :ok
    else
      {:error, :invalid_scope}
    end
  end

  defp scope(_, _), do: {:error, :invalid_request}

  defp equals(value, expected) when value == expected, do: :ok
  defp equals(_, _), do: {:error, :invalid_request}

  defp secure_equal?(left, right) when byte_size(left) == byte_size(right) do
    Plug.Crypto.secure_compare(left, right)
  end

  defp secure_equal?(_, _), do: false
end
