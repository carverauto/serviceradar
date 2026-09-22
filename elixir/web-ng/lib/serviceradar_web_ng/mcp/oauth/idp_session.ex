defmodule ServiceRadarWebNG.Mcp.OAuth.IdPSession do
  @moduledoc """
  Confirms the identity-provider session bound to an MCP OAuth grant.

  Tests may replace this with `Application.put_env(:serviceradar_web_ng,
  :mcp_idp_session_checker, fun)`.
  """

  alias ServiceRadar.Identity.McpOAuthGrant

  @spec still_valid?(McpOAuthGrant.t()) :: boolean()
  def still_valid?(grant), do: match?({:ok, _}, check(grant))

  @spec check(McpOAuthGrant.t()) :: {:ok, String.t() | nil} | :error
  def check(%McpOAuthGrant{} = grant) do
    case Application.get_env(:serviceradar_web_ng, :mcp_idp_session_checker) do
      fun when is_function(fun, 1) -> normalize_checker(fun.(grant))
      _ -> default_check(grant)
    end
  end

  def check(_), do: :error

  defp normalize_checker(true), do: {:ok, nil}
  defp normalize_checker(:ok), do: {:ok, nil}
  defp normalize_checker({:ok, token}) when is_binary(token), do: {:ok, token}
  defp normalize_checker({:ok, _}), do: {:ok, nil}
  defp normalize_checker(_), do: :error

  defp default_check(%McpOAuthGrant{auth_method: :password}), do: {:ok, nil}

  defp default_check(%McpOAuthGrant{auth_method: method} = grant) when method in [:oidc, :saml] do
    refresh = grant.idp_refresh_token

    if is_binary(refresh) and refresh != "" do
      client = Application.fetch_env!(:serviceradar_web_ng, :mcp_idp_refresh_client)

      case client.refresh_tokens(refresh) do
        {:ok, tokens} ->
          {:ok, tokens["refresh_token"] || tokens[:refresh_token]}

        _ ->
          :error
      end
    else
      :error
    end
  end

  defp default_check(_), do: :error
end
