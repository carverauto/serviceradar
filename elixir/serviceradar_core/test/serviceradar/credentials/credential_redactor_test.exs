defmodule ServiceRadar.Credentials.CredentialRedactorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Credentials.CredentialRedactor

  test "redacts nested plaintext credential material but preserves secret references" do
    ref = "credentialref:network-credential-secret:018f3f56-1111-7222-8333-123456789abc"

    payload = %{
      "api_token_secret_ref" => ref,
      "credential_secret_ref" => ref,
      "api_token" => "PVEAPIToken=root@pam!sr=secret",
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
    assert redacted["api_token"] == "REDACTED"
    assert redacted["secret_payload"] == "REDACTED"
    assert Enum.at(redacted["nested"], 0)["passphrase"] == "REDACTED"
    assert Enum.at(redacted["nested"], 1)["notes"] == "safe"
    assert Enum.at(redacted["nested"], 2) == "REDACTED"

    refute inspect(redacted) =~ "PVEAPIToken="
    refute inspect(redacted) =~ "key-passphrase"
    refute inspect(redacted) =~ "PRIVATE KEY"
  end

  defp private_key_fixture do
    """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    QyNTUxOQAAACB5Qw8C1g64mHaVnq1m6+xR54Xq7gkPsFQj7u3lK4P4JAAAAJB0ZXN0dGVz
    dAAAAAtzc2gtZWQyNTUxOQAAACB5Qw8C1g64mHaVnq1m6+xR54Xq7gkPsFQj7u3lK4P4JAAA
    AEB0ZXN0LWtleS1tYXRlcmlhbAAAAAAAAAAA
    -----END OPENSSH PRIVATE KEY-----
    """
  end
end
