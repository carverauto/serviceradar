defmodule ServiceRadarWebNG.Mcp.OAuth.IdPSessionTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Identity.McpOAuthGrant
  alias ServiceRadarWebNG.Mcp.OAuth.IdPSession

  defmodule RefreshClient do
    @moduledoc false
    @behaviour ServiceRadarWebNG.Mcp.OAuth.IdPRefreshClient

    @impl true
    def refresh_tokens("synthetic-refresh"), do: {:ok, %{"refresh_token" => "synthetic-rotated-refresh"}}

    def refresh_tokens(_refresh_token), do: {:error, :invalid_refresh_token}
  end

  setup do
    previous_checker = Application.get_env(:serviceradar_web_ng, :mcp_idp_session_checker)
    previous_client = Application.fetch_env!(:serviceradar_web_ng, :mcp_idp_refresh_client)

    Application.delete_env(:serviceradar_web_ng, :mcp_idp_session_checker)
    Application.put_env(:serviceradar_web_ng, :mcp_idp_refresh_client, RefreshClient)

    on_exit(fn ->
      restore_env(:mcp_idp_session_checker, previous_checker)
      Application.put_env(:serviceradar_web_ng, :mcp_idp_refresh_client, previous_client)
    end)

    :ok
  end

  test "refreshes an OIDC session through the configured client" do
    grant = %McpOAuthGrant{auth_method: :oidc, idp_refresh_token: "synthetic-refresh"}

    assert IdPSession.check(grant) == {:ok, "synthetic-rotated-refresh"}
  end

  test "rejects an OIDC session when the configured client rejects its refresh token" do
    grant = %McpOAuthGrant{auth_method: :oidc, idp_refresh_token: "synthetic-invalid-refresh"}

    assert IdPSession.check(grant) == :error
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
