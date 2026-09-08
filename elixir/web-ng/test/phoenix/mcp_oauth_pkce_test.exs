defmodule ServiceRadarWebNG.Mcp.OAuth.PkceTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Mcp.OAuth.Pkce
  alias ServiceRadarWebNG.Mcp.OAuth.RedirectURI

  @moduletag :db_free

  test "S256 challenge matches RFC 7636 example shape" do
    verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    challenge = Pkce.challenge_s256(verifier)
    assert Pkce.valid_s256?(verifier, challenge)
    refute Pkce.valid_s256?(verifier <> "x", challenge)
    refute Pkce.valid_s256?(verifier, "plain")
  end

  test "loopback URIs accept any port and path" do
    assert RedirectURI.loopback?("http://127.0.0.1:43721/callback")
    assert RedirectURI.loopback?("http://localhost/oauth")
    assert RedirectURI.loopback?("http://[::1]:9/")
    refute RedirectURI.loopback?("https://127.0.0.1/callback")
    refute RedirectURI.loopback?("http://example.com/callback")
    refute RedirectURI.loopback?("http://evil.127.0.0.1.example/callback")
    refute RedirectURI.loopback?("http://user@127.0.0.1/callback")
  end
end
