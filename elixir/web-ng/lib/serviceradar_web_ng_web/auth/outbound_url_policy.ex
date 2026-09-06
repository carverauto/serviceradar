defmodule ServiceRadarWebNGWeb.Auth.OutboundURLPolicy do
  @moduledoc """
  Shared outbound URL validation for auth-related metadata/JWKS fetches.
  """

  alias ServiceRadar.Policies.OutboundURLPolicy, as: SharedOutboundURLPolicy

  @doc """
  Validates a URL string and returns a normalized URI if allowed.
  """
  def validate(url, opts \\ [])

  def validate(url, opts) when is_binary(url) do
    SharedOutboundURLPolicy.validate_https_public_url(url, opts)
  end

  def validate(_, _opts), do: {:error, :invalid_url}

  @doc """
  Conservative request options for outbound metadata/JWKS calls.

  Retries are scoped to stale pooled connections only. Req's default retry
  policy (`:safe_transient`, up to 3 retries with backoff) turns one 10s
  receive timeout into ~47s of user-facing latency and logs a
  `** (Req.TransportError) timeout` warning per attempt, which reads like a
  crash in the logs but is routine retry chatter. A timeout means the
  upstream is slow, so retrying only makes the user wait longer; a `:closed`
  socket means the pooled connection died before the request was written,
  so one retry on a fresh connection is a transparent recovery.
  """
  def req_opts do
    [
      connect_options: [timeout: 5_000],
      receive_timeout: 10_000,
      redirect: false,
      retry: &retry_stale_connection?/2,
      retry_log_level: false
    ]
  end

  # Deliberately narrow, mirroring `OIDCClient.stale_connection?/1` for the
  # token exchange: only a socket that was gone before the request was
  # written is safe to retry transparently. Anything else (notably
  # `:timeout`) fails fast so the caller maps it to a user-facing error
  # instead of stalling through backoff. Retry chatter stays disabled
  # because the surviving `:closed` retry is routine pool hygiene, and an
  # exhausted fetch is already logged by the caller with context.
  defp retry_stale_connection?(_request, %Req.TransportError{reason: :closed}), do: true
  defp retry_stale_connection?(_request, _response_or_exception), do: false
end
