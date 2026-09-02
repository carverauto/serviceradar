defmodule ServiceRadarWebNG.Mcp.OAuth do
  @moduledoc """
  Constants and helpers for MCP authorization-code + PKCE.
  """

  @public_client_id "serviceradar-mcp"
  @allowed_scopes ~w(mcp read)
  @code_ttl_seconds 600
  @access_ttl_seconds 3600
  @default_refresh_ttl_seconds 8 * 3600

  @spec public_client_id() :: String.t()
  def public_client_id, do: @public_client_id

  @spec allowed_scopes() :: [String.t()]
  def allowed_scopes, do: @allowed_scopes

  @spec code_ttl_seconds() :: pos_integer()
  def code_ttl_seconds, do: @code_ttl_seconds

  @spec access_ttl_seconds() :: pos_integer()
  def access_ttl_seconds, do: @access_ttl_seconds

  @spec refresh_ttl_seconds() :: pos_integer()
  def refresh_ttl_seconds do
    Application.get_env(:serviceradar_web_ng, :mcp_refresh_ttl_seconds, @default_refresh_ttl_seconds)
  end

  @spec client_credentials_enabled?() :: boolean()
  def client_credentials_enabled? do
    Application.get_env(:serviceradar_web_ng, :mcp_client_credentials_enabled, true) != false
  end

  @spec issuer(Plug.Conn.t()) :: String.t()
  def issuer(%Plug.Conn{} = conn) do
    scheme = to_string(conn.scheme || "https")
    host = conn.host || "localhost"
    port = conn.port

    cond do
      scheme == "https" and port in [nil, 443] -> "#{scheme}://#{host}"
      scheme == "http" and port in [nil, 80] -> "#{scheme}://#{host}"
      is_integer(port) -> "#{scheme}://#{host}:#{port}"
      true -> "#{scheme}://#{host}"
    end
  end

  @spec mcp_resource(Plug.Conn.t()) :: String.t()
  def mcp_resource(conn), do: issuer(conn) <> "/mcp"

  @spec protected_resource_metadata_url(Plug.Conn.t()) :: String.t()
  def protected_resource_metadata_url(conn), do: issuer(conn) <> "/.well-known/oauth-protected-resource"

  @spec sha256_hex(binary()) :: String.t()
  def sha256_hex(value) when is_binary(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.encode16(case: :lower)
  end

  @spec random_token() :: String.t()
  def random_token do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  @spec normalize_scope(String.t() | [String.t()] | nil) :: {:ok, String.t()} | {:error, :invalid_scope}
  def normalize_scope(nil), do: {:ok, Enum.join(@allowed_scopes, " ")}

  def normalize_scope(scope) when is_binary(scope) do
    requested = String.split(scope, ~r/[\s,]+/, trim: true)

    if requested == [] or Enum.all?(requested, &(&1 in @allowed_scopes)) do
      granted = Enum.filter(@allowed_scopes, &(&1 in requested))
      granted = if granted == [], do: @allowed_scopes, else: granted
      {:ok, Enum.join(granted, " ")}
    else
      {:error, :invalid_scope}
    end
  end

  def normalize_scope(scopes) when is_list(scopes) do
    normalize_scope(Enum.join(scopes, " "))
  end

  def normalize_scope(_), do: {:error, :invalid_scope}

  @spec scope_includes_mcp?(String.t()) :: boolean()
  def scope_includes_mcp?(scope) when is_binary(scope) do
    "mcp" in String.split(scope, ~r/[\s,]+/, trim: true)
  end

  def scope_includes_mcp?(_), do: false

  @spec www_authenticate(Plug.Conn.t(), keyword()) :: String.t()
  def www_authenticate(conn, opts \\ []) do
    parts = [
      ~s(Bearer realm="mcp"),
      ~s(resource_metadata="#{protected_resource_metadata_url(conn)}")
    ]

    parts =
      case Keyword.get(opts, :error) do
        nil -> parts
        error -> parts ++ [~s(error="#{error}")]
      end

    parts =
      case Keyword.get(opts, :scope) do
        nil -> parts
        scope -> parts ++ [~s(scope="#{scope}")]
      end

    Enum.join(parts, ", ")
  end
end
