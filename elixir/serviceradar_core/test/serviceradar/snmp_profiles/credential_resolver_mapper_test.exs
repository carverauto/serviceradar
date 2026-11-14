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

    assert {:ok, mapped} =
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

  test "to_mapper_credentials refuses an unrecognised security level" do
    assert {:error, {:unknown_security_level, :banana}} =
             CredentialResolver.to_mapper_credentials(%{
               version: :v3,
               username: "serviceradar",
               security_level: :banana,
               auth_protocol: :sha,
               auth_password: "auth-secret",
               priv_protocol: :aes,
               priv_password: "auth-secret"
             })
  end

  test "to_mapper_credentials omits the level when absent" do
    assert {:ok, mapped} =
             CredentialResolver.to_mapper_credentials(%{version: :v2c, community: "public"})

    assert mapped["version"] == "v2c"
    refute Map.has_key?(mapped, "security_level")
  end
end
