defmodule ServiceRadar.Edge.ReleaseFetchPolicy do
  @moduledoc """
  Shared outbound URL validation for release import and artifact mirroring.
  """

  alias ServiceRadar.Policies.OutboundURLPolicy, as: SharedOutboundURLPolicy

  @spec validate(String.t()) :: :ok | {:error, atom()}
  def validate(url) when is_binary(url) do
    case SharedOutboundURLPolicy.validate_https_public_url(url) do
      {:ok, _uri} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def validate(_url), do: {:error, :invalid_url}
end
