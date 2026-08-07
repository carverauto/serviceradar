defmodule ServiceRadarWebNGWeb.Auth.OIDCClientRetryTest do
  @moduledoc """
  Pins which transport failures the OIDC token exchange is willing to retry.

  The authorization code is single-use, so the retry must stay narrow. `:closed`
  means a pooled keep-alive connection was already gone when the request tried to
  use it -- the request never reached the provider, so a retry on a fresh
  connection is safe and turns a user-visible login failure into a transparent
  recovery.

  Anything else could mean the provider *did* process the exchange. Retrying
  those would burn the code and return `invalid_grant`, trading one failure
  message for another while doubling how long the user waits.
  """

  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Auth.OIDCClient

  test "retries a closed pooled connection" do
    assert OIDCClient.stale_connection?(%Req.TransportError{reason: :closed})
  end

  test "does not retry a timeout - the provider may have processed the exchange" do
    refute OIDCClient.stale_connection?(%Req.TransportError{reason: :timeout})
  end

  test "does not retry connection refused - a fresh connection fails the same way" do
    refute OIDCClient.stale_connection?(%Req.TransportError{reason: :econnrefused})
  end

  test "does not retry non-transport failures" do
    refute OIDCClient.stale_connection?(:dns_resolution_failed)
    refute OIDCClient.stale_connection?(:disallowed_host)
    refute OIDCClient.stale_connection?(%RuntimeError{message: "boom"})
    refute OIDCClient.stale_connection?(nil)
  end
end
