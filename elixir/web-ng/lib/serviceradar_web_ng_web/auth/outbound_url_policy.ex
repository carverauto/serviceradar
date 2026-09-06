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
  socket on a GET/HEAD means the pooled connection died before the request
  was written, so one retry on a fresh connection is a transparent recovery.
  POST is never retried here: the token exchange owns its own retry.
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

  # Deliberately narrow: only a GET/HEAD whose socket was gone before the
  # request was written is safe to retry transparently. Anything else
  # (notably `:timeout`) fails fast so the caller maps it to a user-facing
  # error instead of stalling through backoff. POST is excluded on purpose:
  # `OIDCClient.exchange_tokens/3` already owns the single `:closed` retry
  # for the token exchange, and a second retry loop here would stack
  # attempts and backoff on logins. Retry chatter stays disabled because
  # the surviving `:closed` retry is routine pool hygiene, and an exhausted
  # fetch is already logged by the caller with context.
  defp retry_stale_connection?(%{method: method}, %Req.TransportError{reason: :closed}) do
    method in [:get, :head]
  end

  defp retry_stale_connection?(_request, _response_or_exception), do: false
end
