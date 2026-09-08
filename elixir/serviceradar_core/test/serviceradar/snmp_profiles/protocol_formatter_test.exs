defmodule ServiceRadar.SNMPProfiles.ProtocolFormatterTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.SNMPProfiles.ProtocolFormatter

  test "formats compact mapper protocol strings" do
    assert ProtocolFormatter.version(:v3, allow_binary?: true) == "v3"
    assert ProtocolFormatter.auth_protocol(:sha256, style: :compact) == "SHA256"
    assert ProtocolFormatter.priv_protocol(:aes192c, style: :compact) == "AES192"
  end

  test "formats hyphenated agent protocol strings" do
    assert ProtocolFormatter.version(:v2c) == "v2c"
    assert ProtocolFormatter.security_level(:auth_priv) == "authPriv"
    assert ProtocolFormatter.auth_protocol(:sha256, style: :hyphenated) == "SHA-256"
    assert ProtocolFormatter.priv_protocol(:aes192c, style: :hyphenated) == "AES-192-C"
  end

  test "preserves binary mapper protocol values when allowed" do
    assert ProtocolFormatter.version("v1", allow_binary?: true) == "v1"

    assert ProtocolFormatter.auth_protocol("sha512", style: :compact, allow_binary?: true) ==
             "SHA512"

    assert ProtocolFormatter.priv_protocol("aes256", style: :compact, allow_binary?: true) ==
             "AES256"
  end
end
