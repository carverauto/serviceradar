defmodule ServiceRadarWebNGWeb.Auth.OutboundURLPolicy do
  @moduledoc """
  Shared outbound URL validation for auth-related metadata/JWKS fetches.
  """

  alias ServiceRadar.Policies.OutboundURLPolicy, as: SharedOutboundURLPolicy

  @doc """
  Validates a URL string and returns a normalized URI if allowed.
  """
  def validate(url) when is_binary(url) do
    SharedOutboundURLPolicy.validate_https_public_url(url)
  end

  def validate(_), do: {:error, :invalid_url}

  @doc """
  Conservative request options for outbound metadata/JWKS calls.
  """
  def req_opts do
    [connect_options: [timeout: 5_000], receive_timeout: 10_000, redirect: false]
  end
end
