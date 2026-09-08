defmodule ServiceRadarWebNGWeb.Helpers.InterfaceTypes do
  @moduledoc """
  Maps IANA ifType values to human-readable interface type names.

  Based on IANA Interface Types registry:
  https://www.iana.org/assignments/ianaiftype-mib/ianaiftype-mib

  Common ifType values are mapped to user-friendly names.
  Unknown types fall back to the original value.
  """

  @type_map %{
    # Ethernet types
    "ethernetCsmacd" => "Ethernet",
    "fastEther" => "Fast Ethernet",
    "fastEtherFX" => "Fast Ethernet FX",
    "gigabitEthernet" => "Gigabit Ethernet",
    "ethernet3Mbit" => "Ethernet 3Mbit",

    # Loopback and virtual
    "softwareLoopback" => "Loopback",
    "tunnel" => "Tunnel",
    "l2vlan" => "VLAN",
    "bridge" => "Bridge",
    "propVirtual" => "Virtual",

    # WAN/Serial types
    "ppp" => "PPP",
    "slip" => "SLIP",
    "hdlc" => "HDLC",
    "frameRelay" => "Frame Relay",
    "atm" => "ATM",
    "sonet" => "SONET",
    "sdsl" => "SDSL",
    "adsl" => "ADSL",
    "adsl2" => "ADSL2",
    "adsl2plus" => "ADSL2+",
    "vdsl" => "VDSL",
    "vdsl2" => "VDSL2",

    # Wireless
    "ieee80211" => "WiFi (802.11)",
    "ieee80216WMAN" => "WiMAX",

    # Fibre Channel
    "fibreChannel" => "Fibre Channel",

    # Legacy types
    "iso88023Csmacd" => "Ethernet (802.3)",
    "iso88024TokenBus" => "Token Bus",
    "iso88025TokenRing" => "Token Ring",
    "fddi" => "FDDI",
    "lapb" => "LAPB",
    "sdlc" => "SDLC",

    # Management/Other
    "other" => "Other",
    "regular1822" => "BBN 1822",
    "propPointToPointSerial" => "Serial P2P",
    "ds1" => "DS1/T1",
    "e1" => "E1",
    "ds3" => "DS3/T3",
    "sip" => "SMDS SIP",
    "primaryISDN" => "ISDN PRI",
    "basicISDN" => "ISDN BRI",
    "propMultiplexor" => "Multiplexor",
    "ieee8023adLag" => "Link Aggregation",
    "voiceOverIp" => "VoIP",
    "voiceEncap" => "Voice Encap",
    "voiceOverFrameRelay" => "Voice over FR",
    "voiceOverAtm" => "Voice over ATM",
    "atmSubInterface" => "ATM Sub-IF",
    "stackToStack" => "Stack-to-Stack",
    "virtualIpAddress" => "Virtual IP",

    # Infiniband
    "infiniband" => "InfiniBand",

    # IEEE types by number (some systems report numeric names)
    "6" => "Ethernet",
    "24" => "Loopback",
    "131" => "Tunnel",
    "135" => "VLAN",
    "53" => "Virtual",
    "1" => "Other"
  }

  @doc """
  Returns a human-readable name for the given interface type.

  ## Examples

      iex> InterfaceTypes.humanize("ethernetCsmacd")
      "Ethernet"

      iex> InterfaceTypes.humanize("softwareLoopback")
      "Loopback"

      iex> InterfaceTypes.humanize("unknownType123")
      "unknownType123"

  """
  @spec humanize(String.t() | nil) :: String.t()
  def humanize(nil), do: "—"
  def humanize(""), do: "—"

  def humanize(type) when is_binary(type) do
    Map.get(@type_map, type, type)
  end

  def humanize(type) when is_integer(type) do
    Map.get(@type_map, Integer.to_string(type), "Type #{type}")
  end

  def humanize(_), do: "—"

  @doc """
  Returns the full mapping of ifType names to human-readable names.
  Useful for documentation or UI display of all known types.
  """
  @spec all_mappings() :: map()
  def all_mappings, do: @type_map

  @doc """
  Checks if the given type is a known/mapped type.
  """
  @spec known?(String.t() | nil) :: boolean()
  def known?(nil), do: false
  def known?(type), do: Map.has_key?(@type_map, type)
end
