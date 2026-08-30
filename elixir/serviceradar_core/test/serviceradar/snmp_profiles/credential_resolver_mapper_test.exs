defmodule ServiceRadar.SNMPProfiles.CredentialResolverMapperTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.SNMPProfiles.CredentialResolver

  test "to_mapper_credentials includes security_level and compact protocols" do
    mapped =
      CredentialResolver.to_mapper_credentials(%{
        version: :v3,
        username: "serviceradar",
        security_level: :auth_priv,
        auth_protocol: :sha,
        auth_password: "auth-secret",
        priv_protocol: :aes,
        priv_password: "auth-secret"
      })

    assert mapped["version"] == "v3"
    assert mapped["username"] == "serviceradar"
    assert mapped["security_level"] == "authPriv"
    assert mapped["auth_protocol"] == "SHA"
    assert mapped["privacy_protocol"] == "AES"
    assert mapped["auth_password"] == "auth-secret"
    assert mapped["privacy_password"] == "auth-secret"
  end
end
