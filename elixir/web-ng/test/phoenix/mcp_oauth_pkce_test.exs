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
    assert RedirectURI.allowed?("http://127.0.0.1:43721/callback")
    assert RedirectURI.allowed?("http://localhost:8080/oauth")
    assert RedirectURI.allowed?("http://[::1]:9/")
    refute RedirectURI.loopback?("https://127.0.0.1/callback")
    refute RedirectURI.loopback?("http://example.com/callback")
    refute RedirectURI.loopback?("http://evil.127.0.0.1.example/callback")
    refute RedirectURI.loopback?("http://user@127.0.0.1/callback")
  end

  test "allowed? accepts exact first-party Antigravity HTTPS callback and rejects arbitrary HTTPS URIs" do
    assert RedirectURI.allowed?("https://antigravity.google/oauth-callback")
    assert RedirectURI.allowlisted_https?("https://antigravity.google/oauth-callback")

    for rejected <- [
          "https://evil.example/oauth-callback",
          "https://antigravity.google.evil.com/oauth-callback",
          "https://sub.antigravity.google/oauth-callback",
          "https://antigravity.google/other",
          "https://antigravity.google/oauth-callback/extra",
          "https://antigravity.google/oauth-callback?foo=bar",
          "https://antigravity.google/oauth-callback#frag",
          "https://user@antigravity.google/oauth-callback",
          "https://antigravity.google:8443/oauth-callback",
          "http://antigravity.google/oauth-callback",
          "https://antigravity.google/oauth-callback/../other",
          nil,
          ""
        ] do
      refute RedirectURI.allowed?(rejected), "expected #{inspect(rejected)} to be rejected"
    end
  end
end
