defmodule ServiceRadarWebNGWeb.Auth.OIDCStrategy do
  @moduledoc """
  Dynamic OIDC strategy that reads configuration from AuthSettings.

  This module provides OIDC configuration to Ueberauth at runtime,
  allowing admins to configure OIDC providers through the UI without
  requiring application restarts.

  ## Usage

  The strategy is configured in config.exs but reads actual values
  from the AuthSettings resource at runtime via the ConfigCache.

  ## Supported Providers

  Any OIDC-compliant provider with a discovery URL, including:
  - Google Workspace
  - Azure AD / Entra ID
  - Okta
  - Auth0
  - Keycloak
  """

  alias ServiceRadarWebNGWeb.Auth.ConfigCache

  @doc """
  Returns the current OIDC configuration from AuthSettings.

  Returns nil if OIDC is not configured or not enabled.
  """
  def get_config do
    case ConfigCache.get_settings() do
      {:ok, settings} ->
        if oidc_enabled?(settings) do
          build_config(settings)
        else
          nil
        end

      {:error, _} ->
        nil
    end
  end

  @doc """
  Checks if OIDC is enabled in the current configuration.
  """
  def enabled? do
    case ConfigCache.get_settings() do
      {:ok, settings} -> oidc_enabled?(settings)
      _ -> false
    end
  end

  @doc """
  Returns the OIDC discovery URL for fetching provider metadata.
  """
  def discovery_url do
    case ConfigCache.get_settings() do
      {:ok, %{oidc_discovery_url: url}} when is_binary(url) and url != "" -> url
      _ -> nil
    end
  end

  @doc """
  Returns the configured scopes as a list.
  """
  def scopes do
    case ConfigCache.get_settings() do
      {:ok, %{oidc_scopes: scopes}} when is_binary(scopes) ->
        scopes |> String.split() |> Enum.map(&String.trim/1)

      _ ->
        ["openid", "email", "profile"]
    end
  end

  @doc """
  Returns claim mappings for extracting user attributes from ID token.
  """
  def claim_mappings do
    case ConfigCache.get_settings() do
      {:ok, %{claim_mappings: mappings}} when is_map(mappings) -> mappings
      _ -> %{"email" => "email", "name" => "name", "sub" => "sub"}
    end
  end

  # Private functions

  defp oidc_enabled?(%{is_enabled: true, mode: :active_sso, provider_type: :oidc}), do: true
  defp oidc_enabled?(_), do: false

  defp build_config(settings) do
    %{
      client_id: settings.oidc_client_id,
      client_secret: settings.oidc_client_secret_encrypted,
      discovery_url: settings.oidc_discovery_url,
      scopes: parse_scopes(settings.oidc_scopes),
      redirect_uri: build_redirect_uri()
    }
  end

  defp parse_scopes(nil), do: ["openid", "email", "profile"]
  defp parse_scopes(""), do: ["openid", "email", "profile"]

  defp parse_scopes(scopes) when is_binary(scopes) do
    scopes |> String.split() |> Enum.map(&String.trim/1)
  end

  defp build_redirect_uri do
    base_url = Application.get_env(:serviceradar_web_ng, :base_url, "http://localhost:4000")
    "#{base_url}/auth/oidc/callback"
  end
end
