defmodule ServiceRadar.Credentials.CredentialRedactorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Credentials.CredentialRedactor

  test "redacts nested plaintext credential material but preserves secret references" do
    ref = "credentialref:network-credential-secret:018f3f56-1111-7222-8333-123456789abc"

    payload = %{
      "api_token_secret_ref" => ref,
      "credential_secret_ref" => ref,
      "credential_grant_ref" => "credentialref:network-credential-grant:opaque.sig",
      "external_secret_ref" => "secret-server/folder/prod-password",
      "api_token" => "PVEAPIToken=root@pam!sr=secret",
      "authorization" => "Bearer super-secret",
      "cookie" => "session=super-secret",
      "download_token" => "one-time-secret",
      "secret_payload" => Jason.encode!(%{"private_key" => private_key_fixture()}),
      "nested" => [
        %{"passphrase" => "key-passphrase"},
        %{"notes" => "safe"},
        private_key_fixture()
      ]
    }

    redacted = CredentialRedactor.redact(payload)

    assert redacted["api_token_secret_ref"] == ref
    assert redacted["credential_secret_ref"] == ref
    assert redacted["credential_grant_ref"] == "credentialref:network-credential-grant:opaque.sig"
    assert redacted["external_secret_ref"] == "REDACTED"
    assert redacted["api_token"] == "REDACTED"
    assert redacted["authorization"] == "REDACTED"
    assert redacted["cookie"] == "REDACTED"
    assert redacted["download_token"] == "REDACTED"
    assert redacted["secret_payload"] == "REDACTED"
    assert Enum.at(redacted["nested"], 0)["passphrase"] == "REDACTED"
    assert Enum.at(redacted["nested"], 1)["notes"] == "safe"
    assert Enum.at(redacted["nested"], 2) == "REDACTED"

    refute inspect(redacted) =~ "PVEAPIToken="
    refute inspect(redacted) =~ "key-passphrase"
    refute inspect(redacted) =~ "PRIVATE KEY"
  end

  defp private_key_fixture do
    private_key_fixture_header() <>
      """
      b3BlbnNzaC10ZXN0LWtleS1tYXRlcmlhbA==
      #{private_key_fixture_footer()}
      """
  end

  defp private_key_fixture_header, do: "-----BEGIN OPENSSH " <> "PRIVATE KEY-----\n"
  defp private_key_fixture_footer, do: "-----END OPENSSH " <> "PRIVATE KEY-----"
end
