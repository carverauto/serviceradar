defmodule ServiceRadarWebNG.Mcp.OAuth.PkceTest do
  use ExUnit.Case, async: false

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

  test "operator-configured HTTPS redirect URIs are exact-matched and unsafe entries ignored" do
    prev = Application.get_env(:serviceradar_web_ng, :mcp_allowed_redirect_uris)

    Application.put_env(:serviceradar_web_ng, :mcp_allowed_redirect_uris, [
      "https://client.example.org/cb",
      "http://insecure.example.org/cb",
      "https://bad.example.org/cb?injected=1",
      "https://bad.example.org/cb#frag",
      "https://user@bad.example.org/cb"
    ])

    on_exit(fn ->
      if prev do
        Application.put_env(:serviceradar_web_ng, :mcp_allowed_redirect_uris, prev)
      else
        Application.delete_env(:serviceradar_web_ng, :mcp_allowed_redirect_uris)
      end
    end)

    assert RedirectURI.allowed?("https://client.example.org/cb")
    assert RedirectURI.allowed?("https://antigravity.google/oauth-callback")
    refute RedirectURI.allowed?("http://insecure.example.org/cb")
    refute RedirectURI.allowed?("https://bad.example.org/cb?injected=1")
    refute RedirectURI.allowed?("https://bad.example.org/cb#frag")
    refute RedirectURI.allowed?("https://user@bad.example.org/cb")
  end
end
