defmodule ServiceRadar.SNMPProfiles.ProtocolFormatterTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.SNMPProfiles.ProtocolFormatter

  # The names core offers and the spelling it sends for each. The Go agent's and
  # mapper's tests read the same file and fail on a name they do not accept, so
  # this half only has to prove the file is what core really offers and sends.
  @contract Path.expand(
              "../../../../../go/pkg/agent/snmp/testdata/snmpv3_protocol_contract.json",
              __DIR__
            )
  @external_resource @contract

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

  test "offers exactly the names in the contract shared with the Go agent" do
    contract = @contract |> File.read!() |> Jason.decode!()

    assert offered(
             ProtocolFormatter.security_level_options(),
             &ProtocolFormatter.security_level/1
           ) ==
             contract["security_levels"]

    assert offered(
             ProtocolFormatter.auth_protocol_options(),
             &ProtocolFormatter.auth_protocol(&1, style: :hyphenated)
           ) == contract["auth_protocols"]

    assert offered(
             ProtocolFormatter.priv_protocol_options(),
             &ProtocolFormatter.priv_protocol(&1, style: :hyphenated)
           ) == contract["priv_protocols"]
  end

  # Credentials stored while the form was free text carry these spellings, and
  # the resolver reads them through the same functions, so each must keep
  # resolving to the option an operator would now pick.
  test "resolves every stored spelling to the option it means" do
    for {spellings, normalize, stored_value, option} <- [
          {["authPriv", "auth_priv", " authPriv ", :auth_priv],
           &ProtocolFormatter.normalize_security_level/1,
           &ProtocolFormatter.security_level_value/1, {:auth_priv, "authPriv"}},
          {["noAuthNoPriv", "no_auth_no_priv"], &ProtocolFormatter.normalize_security_level/1,
           &ProtocolFormatter.security_level_value/1, {:no_auth_no_priv, "noAuthNoPriv"}},
          {["SHA256", "SHA-256", "sha256", "sha-256", :sha256],
           &ProtocolFormatter.normalize_auth_protocol/1, &ProtocolFormatter.auth_protocol_value/1,
           {:sha256, "SHA256"}},
          {["SHA", "sha1", "SHA-1"], &ProtocolFormatter.normalize_auth_protocol/1,
           &ProtocolFormatter.auth_protocol_value/1, {:sha, "SHA"}},
          {["AES", "aes128", "AES-128"], &ProtocolFormatter.normalize_priv_protocol/1,
           &ProtocolFormatter.priv_protocol_value/1, {:aes, "AES"}},
          {["AES192", "AES-192", "aes192"], &ProtocolFormatter.normalize_priv_protocol/1,
           &ProtocolFormatter.priv_protocol_value/1, {:aes192, "AES192"}},
          {["AES-192-C", "aes192c", "AES192C", :aes192c],
           &ProtocolFormatter.normalize_priv_protocol/1, &ProtocolFormatter.priv_protocol_value/1,
           {:aes192c, "AES-192-C"}}
        ],
        spelling <- spellings do
      assert {normalize.(spelling), stored_value.(spelling)} == option, inspect(spelling)
    end
  end

  test "does not resolve a name that is not an SNMPv3 level or protocol" do
    for unknown <- ["authpriv", "AuthPriv", "SHA3", "AES512", "", nil, :sha3] do
      assert ProtocolFormatter.security_level_value(unknown) == nil, inspect(unknown)
      assert ProtocolFormatter.auth_protocol_value(unknown) == nil, inspect(unknown)
      assert ProtocolFormatter.priv_protocol_value(unknown) == nil, inspect(unknown)
    end
  end

  test "a new credential starts on authPriv with SHA-256 and AES-128" do
    assert ProtocolFormatter.default_option(:security_level).value == "authPriv"
    assert ProtocolFormatter.default_option(:auth_protocol).value == "SHA256"
    assert ProtocolFormatter.default_option(:priv_protocol).value == "AES"
  end

  defp offered(options, wire) do
    Enum.map(options, &%{"value" => &1.value, "wire" => wire.(&1.id)})
  end
end
