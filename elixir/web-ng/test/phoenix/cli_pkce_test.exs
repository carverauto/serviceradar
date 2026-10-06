defmodule ServiceRadarWebNGWeb.CliPkceTest do
  @moduledoc """
  Allowlist for `serviceradar-cli auth login --web`.

  The authorize page and the token endpoint both refuse a redirect that is
  not the CLI's loopback callback. This is the check that keeps the browser
  consent page from becoming an open redirect.
  """
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.CliPkce

  @moduletag :db_free

  @allowed ["dashboard.publish", "plugin.publish", "plugins.manage", "edge.manage"]
  @loopback "http://127.0.0.1:4317/cli/auth/callback"

  test "accepts the CLI loopback callback and the scopes the CLI requests" do
    {verifier, challenge} = pkce_pair()

    assert {:ok, request} = CliPkce.validate_authorize(params(challenge), @allowed)
    assert request.redirect_uri == @loopback
    assert request.client_id == "serviceradar-cli"
    assert request.scope == "dashboard.publish edge.manage"
    assert request.state == "state-pkce-test"
    assert CliPkce.challenge_matches?(request.code_challenge, verifier)
  end

  test "rejects a redirect that can leave the CLI's loopback listener" do
    {_verifier, challenge} = pkce_pair()

    for uri <- [
          "https://127.0.0.1:4317/cli/auth/callback",
          "http://localhost:4317/cli/auth/callback",
          "http://192.0.2.1:4317/cli/auth/callback",
          "http://127.0.0.1/cli/auth/callback",
          "http://127.0.0.1:4317/cli/auth/callback?next=1",
          "http://127.0.0.1:4317/cli/auth/callback#frag",
          "http://user@127.0.0.1:4317/cli/auth/callback",
          "http://127.0.0.1:4317/cli/auth/callback/extra",
          "http://127.0.0.1:4317/other"
        ] do
      assert {:error, :invalid_request} =
               CliPkce.validate_authorize(params(challenge, %{"redirect_uri" => uri}), @allowed)
    end
  end

  test "rejects a scope the instance does not allow" do
    {_verifier, challenge} = pkce_pair()

    assert {:error, :invalid_scope} =
             CliPkce.validate_authorize(params(challenge, %{"scope" => "admin"}), @allowed)
  end

  test "a verifier matches only the challenge derived from it" do
    {verifier, challenge} = pkce_pair()
    {other, _other_challenge} = pkce_pair()

    assert CliPkce.challenge_matches?(challenge, verifier)
    refute CliPkce.challenge_matches?(challenge, other)
    refute CliPkce.challenge_matches?(challenge, "short")
    refute CliPkce.challenge_matches?("not-a-challenge", verifier)
  end

  defp params(challenge, overrides \\ %{}) do
    Map.merge(
      %{
        "response_type" => "code",
        "client_id" => "serviceradar-cli",
        "redirect_uri" => @loopback,
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "state" => "state-pkce-test",
        "scope" => "dashboard.publish edge.manage"
      },
      overrides
    )
  end

  defp pkce_pair do
    verifier = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    challenge = :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)
    {verifier, challenge}
  end
end
