defmodule ServiceRadarWebNG.PkceTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Pkce

  @moduletag :db_free

  # RFC 7636 Appendix B
  @rfc_verifier "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
  @rfc_challenge "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

  test "S256 challenge matches RFC 7636 appendix B" do
    assert Pkce.challenge_s256(@rfc_verifier) == @rfc_challenge
  end

  test "generated verifier is 43-char base64url without padding" do
    verifier = Pkce.generate_verifier()

    assert byte_size(verifier) == 43
    assert verifier =~ ~r/^[A-Za-z0-9_-]+$/
    refute String.contains?(verifier, "=")
  end

  test "generated verifiers are unique" do
    assert Pkce.generate_verifier() != Pkce.generate_verifier()
  end
end
