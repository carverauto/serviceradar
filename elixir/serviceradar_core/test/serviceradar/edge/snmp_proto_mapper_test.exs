defmodule ServiceRadar.Edge.SNMPProtoMapperTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.SNMPProtoMapper

  test "maps SNMP version values to proto enums" do
    assert SNMPProtoMapper.version("v1") == :SNMP_VERSION_V1
    assert SNMPProtoMapper.version(:v2c) == :SNMP_VERSION_V2C
    assert SNMPProtoMapper.version("unknown") == :SNMP_VERSION_UNSPECIFIED
  end

  test "maps security and auth protocol values to proto enums" do
    assert SNMPProtoMapper.security_level("authPriv") == :SNMP_SECURITY_LEVEL_AUTH_PRIV
    assert SNMPProtoMapper.security_level(:auth_no_priv) == :SNMP_SECURITY_LEVEL_AUTH_NO_PRIV
    assert SNMPProtoMapper.auth_protocol("SHA-256") == :SNMP_AUTH_PROTOCOL_SHA256
    assert SNMPProtoMapper.auth_protocol("SHA256") == :SNMP_AUTH_PROTOCOL_SHA256
    assert SNMPProtoMapper.auth_protocol(:sha512) == :SNMP_AUTH_PROTOCOL_SHA512
  end

  test "maps privacy protocol and data type values to proto enums" do
    assert SNMPProtoMapper.priv_protocol("AES-192-C") == :SNMP_PRIV_PROTOCOL_AES192C
    assert SNMPProtoMapper.priv_protocol("AES192") == :SNMP_PRIV_PROTOCOL_AES192
    assert SNMPProtoMapper.priv_protocol(:aes256c) == :SNMP_PRIV_PROTOCOL_AES256C
    assert SNMPProtoMapper.data_type("counter") == :SNMP_DATA_TYPE_COUNTER
    assert SNMPProtoMapper.data_type(:timeticks) == :SNMP_DATA_TYPE_TIMETICKS
  end
end
