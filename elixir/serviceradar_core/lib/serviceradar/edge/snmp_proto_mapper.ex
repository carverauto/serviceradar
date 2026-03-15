defmodule ServiceRadar.Edge.SNMPProtoMapper do
  @moduledoc false

  alias ServiceRadar.SNMPProfiles.ProtocolFormatter

  @version_enums %{
    v1: :SNMP_VERSION_V1,
    v2c: :SNMP_VERSION_V2C,
    v3: :SNMP_VERSION_V3
  }

  @security_level_enums %{
    no_auth_no_priv: :SNMP_SECURITY_LEVEL_NO_AUTH_NO_PRIV,
    auth_no_priv: :SNMP_SECURITY_LEVEL_AUTH_NO_PRIV,
    auth_priv: :SNMP_SECURITY_LEVEL_AUTH_PRIV
  }

  @auth_protocol_enums %{
    md5: :SNMP_AUTH_PROTOCOL_MD5,
    sha: :SNMP_AUTH_PROTOCOL_SHA,
    sha224: :SNMP_AUTH_PROTOCOL_SHA224,
    sha256: :SNMP_AUTH_PROTOCOL_SHA256,
    sha384: :SNMP_AUTH_PROTOCOL_SHA384,
    sha512: :SNMP_AUTH_PROTOCOL_SHA512
  }

  @priv_protocol_enums %{
    des: :SNMP_PRIV_PROTOCOL_DES,
    aes: :SNMP_PRIV_PROTOCOL_AES,
    aes192: :SNMP_PRIV_PROTOCOL_AES192,
    aes256: :SNMP_PRIV_PROTOCOL_AES256,
    aes192c: :SNMP_PRIV_PROTOCOL_AES192C,
    aes256c: :SNMP_PRIV_PROTOCOL_AES256C
  }

  @data_type_enums %{
    counter: :SNMP_DATA_TYPE_COUNTER,
    gauge: :SNMP_DATA_TYPE_GAUGE,
    boolean: :SNMP_DATA_TYPE_BOOLEAN,
    bytes: :SNMP_DATA_TYPE_BYTES,
    string: :SNMP_DATA_TYPE_STRING,
    float: :SNMP_DATA_TYPE_FLOAT,
    timeticks: :SNMP_DATA_TYPE_TIMETICKS
  }

  @spec version(atom() | String.t() | nil) :: atom()
  def version(value) do
    value
    |> ProtocolFormatter.normalize_version()
    |> then(&Map.get(@version_enums, &1, :SNMP_VERSION_UNSPECIFIED))
  end

  @spec security_level(atom() | String.t() | nil) :: atom()
  def security_level(value) do
    value
    |> ProtocolFormatter.normalize_security_level()
    |> then(&Map.get(@security_level_enums, &1, :SNMP_SECURITY_LEVEL_UNSPECIFIED))
  end

  @spec auth_protocol(atom() | String.t() | nil) :: atom()
  def auth_protocol(value) do
    value
    |> ProtocolFormatter.normalize_auth_protocol()
    |> then(&Map.get(@auth_protocol_enums, &1, :SNMP_AUTH_PROTOCOL_UNSPECIFIED))
  end

  @spec priv_protocol(atom() | String.t() | nil) :: atom()
  def priv_protocol(value) do
    value
    |> ProtocolFormatter.normalize_priv_protocol()
    |> then(&Map.get(@priv_protocol_enums, &1, :SNMP_PRIV_PROTOCOL_UNSPECIFIED))
  end

  @spec data_type(atom() | String.t() | nil) :: atom()
  def data_type(value) do
    value
    |> normalize_data_type()
    |> then(&Map.get(@data_type_enums, &1, :SNMP_DATA_TYPE_UNSPECIFIED))
  end

  defp normalize_data_type(value) when is_atom(value), do: value

  defp normalize_data_type(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "counter" -> :counter
      "gauge" -> :gauge
      "boolean" -> :boolean
      "bytes" -> :bytes
      "string" -> :string
      "float" -> :float
      "timeticks" -> :timeticks
      _ -> nil
    end
  end

  defp normalize_data_type(_), do: nil
end
