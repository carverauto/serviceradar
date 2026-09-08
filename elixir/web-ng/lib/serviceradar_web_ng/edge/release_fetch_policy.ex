defmodule ServiceRadarWebNG.Edge.ReleaseFetchPolicy do
  @moduledoc """
  Shared outbound URL validation for release import fetches.
  """

  alias ServiceRadar.Policies.OutboundURLPolicy, as: SharedOutboundURLPolicy

  @spec validate(String.t()) :: {:ok, URI.t()} | {:error, atom()}
  def validate(url) when is_binary(url) do
    SharedOutboundURLPolicy.validate_https_public_url(url)
  end

  def validate(_url), do: {:error, :invalid_url}

  @spec req_opts() :: keyword()
  def req_opts do
    [connect_options: [timeout: 5_000], receive_timeout: 10_000, redirect: false]
  end
end
