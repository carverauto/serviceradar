defmodule ServiceRadar.Observability.OutboundFeedPolicy do
  @moduledoc """
  Shared outbound URL validation for observability feed and dataset refreshes.
  """

  alias ServiceRadar.Edge.ReleaseFetchPolicy

  @spec validate(String.t()) :: :ok | {:error, atom()}
  def validate(url), do: ReleaseFetchPolicy.validate(url)

  @spec req_opts(pos_integer()) :: keyword()
  def req_opts(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    [
      receive_timeout: timeout_ms,
      retry: false,
      finch: ServiceRadar.Finch
    ]
  end

  def req_opts(_timeout_ms), do: req_opts(20_000)

  @spec format_reason(term()) :: String.t()
  def format_reason(:disallowed_host), do: "feed URL host is not allowed"
  def format_reason(:disallowed_scheme), do: "feed URL must use https"
  def format_reason(:dns_resolution_failed), do: "feed URL host could not be resolved"
  def format_reason(:invalid_url), do: "feed URL is invalid"
  def format_reason(reason) when is_binary(reason), do: reason
  def format_reason(reason), do: inspect(reason)
end
