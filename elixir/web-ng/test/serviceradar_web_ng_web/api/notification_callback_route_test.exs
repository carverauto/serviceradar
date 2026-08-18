defmodule ServiceRadarWebNGWeb.Api.NotificationCallbackRouteTest do
  @moduledoc """
  That the callback routes are actually raw-body buffered (task 4.3.0b).

  `RawBodyReader` matches on `String.starts_with?`, and an unbuffered route does
  not fail loudly: the verifier is handed `""`, computes a signature over the
  empty string, and answers an ordinary 401 - indistinguishable from a wrong
  secret. So the concrete paths are asserted here rather than the prefix list
  being eyeballed.
  """

  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Api.RawBodyReader

  # web-ng's Bazel tier runs `ExUnit.configure(exclude: [:test], include: [:db_free])`,
  # so an untagged file runs ZERO tests in CI while reporting success. These need no
  # database - that is the point of the tag, not a workaround for one.
  @moduletag :db_free

  @providers ["slack"]

  test "every provider callback path is buffered" do
    for provider <- @providers do
      path = "/api/notifications/callbacks/" <> provider

      assert RawBodyReader.buffered?(path),
             "#{path} is not raw-body buffered; every signature check on it would fail"
    end
  end

  test "the bare callbacks path is NOT buffered, which is why routes carry a provider segment" do
    # Documents the trap rather than asserting a wish: the registered prefix ends
    # in a slash, so a route mounted at the bare path would silently lose its raw
    # body. The router therefore puts the provider in the path.
    refute RawBodyReader.buffered?("/api/notifications/callbacks")
  end

  test "the action-link routes are deliberately not buffered" do
    # They authorise with a capability token in the URL, not a signature over the
    # body, so they need no raw body and buffering them would retain request
    # bodies for no reason.
    refute RawBodyReader.buffered?("/api/notifications/actions/srn1.abc.def")
  end

  test "the northbound prefix is still buffered" do
    # This change adds a prefix; it must not have replaced one.
    assert RawBodyReader.buffered?("/api/northbound/action-callbacks/job-1")
  end
end
