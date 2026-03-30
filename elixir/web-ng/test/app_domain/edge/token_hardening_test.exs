defmodule ServiceRadarWebNG.Edge.TokenHardeningTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Edge.EnrollmentToken
  alias ServiceRadarWebNG.Edge.OnboardingToken

  @private_key "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="
  @public_key "A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg="

  test "onboarding tokens fail closed when the signing key is missing" do
    assert {:error, :missing_signing_key} =
             OnboardingToken.encode("pkg-123", "dl-123", "https://demo.serviceradar.cloud")
  end

  test "onboarding decode rejects legacy unsigned tokens" do
    payload =
      Base.url_encode64(~s({"pkg":"pkg-123","dl":"dl-123","api":"https://demo.serviceradar.cloud"}), padding: false)

    assert {:error, :unsupported_token_format} = OnboardingToken.decode("edgepkg-v1:" <> payload)
  end

  test "collector tokens are signed and round-trip" do
    assert {:ok, {token, token_hash, secret}} =
             EnrollmentToken.generate("collector-pkg-123",
               base_url: "https://demo.serviceradar.cloud",
               config_filename: "flowgger.toml",
               private_key: @private_key
             )

    assert is_binary(token_hash)
    assert is_binary(secret)
    assert String.starts_with?(token, "collectorpkg-v2:")

    assert {:ok, decoded} = EnrollmentToken.decode(token, public_key: @public_key)
    assert decoded.package_id == "collector-pkg-123"
    assert decoded.base_url == "https://demo.serviceradar.cloud"
    assert decoded.config_file == "flowgger.toml"
    assert EnrollmentToken.verify_secret(secret, token_hash)
  end

  test "collector token generation fails closed when the signing key is missing" do
    assert {:error, :missing_signing_key} =
             EnrollmentToken.generate("collector-pkg-123",
               base_url: "https://demo.serviceradar.cloud"
             )
  end

  test "collector decode rejects unsigned tokens" do
    payload =
      Base.url_encode64(~s({"u":"https://demo.serviceradar.cloud","p":"collector-pkg-123","t":"secret","e":1735689600}),
        padding: false
      )

    assert {:error, :unsupported_token_format} = EnrollmentToken.decode(payload)
  end
end
