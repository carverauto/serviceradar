defmodule ServiceRadar.SNMPProfiles.BuiltinTemplates do
  @moduledoc """
  Built-in OID templates for common SNMP monitoring scenarios.

  These templates are organized by vendor and provide pre-configured OID sets
  for common monitoring use cases. Templates are seeded into the database
  with `is_builtin: true` to distinguish them from user-created templates.

  ## Vendor Categories

  - **Standard** - MIB-II standard OIDs that work across all SNMP devices
  - **Cisco** - Cisco-specific enterprise OIDs
  - **Juniper** - Juniper Networks enterprise OIDs
  - **Arista** - Arista Networks enterprise OIDs

  ## Usage

  ```elixir
  # Get all built-in templates
  templates = BuiltinTemplates.all()

  # Seed templates into database (schema is determined by DB connection's search_path)
  BuiltinTemplates.seed!(tenant_schema, actor)
  ```
  """

  alias ServiceRadar.SNMPProfiles.SNMPOIDTemplate

  @doc """
  Returns all built-in OID templates.
  """
  @spec all() :: [map()]
  def all do
    standard_templates() ++ cisco_templates() ++ juniper_templates() ++ arista_templates()
  end

  @doc """
  Returns all built-in OID templates with generated IDs.
  This is used by the UI to reference templates.
  """
  @spec all_templates() :: [map()]
  def all_templates do
    all()
    |> Enum.map(fn template ->
      # Generate a stable ID based on vendor and name
      slug = template.name
             |> String.downcase()
             |> String.replace(~r/[^a-z0-9]+/, "-")
             |> String.trim("-")
      id = "#{String.downcase(template.vendor)}-#{slug}"
      Map.put(template, :id, id)
    end)
  end

  @doc """
  Returns the list of supported vendors with display information.
  """
  @spec vendors() :: [map()]
  def vendors do
    [
      %{id: "standard", name: "Standard"},
      %{id: "cisco", name: "Cisco"},
      %{id: "juniper", name: "Juniper"},
      %{id: "arista", name: "Arista"}
    ]
  end

  @doc """
  Returns templates for a specific vendor.
  """
  @spec for_vendor(String.t()) :: [map()]
  def for_vendor("Standard"), do: standard_templates()
  def for_vendor("standard"), do: standard_templates()
  def for_vendor("Cisco"), do: cisco_templates()
  def for_vendor("cisco"), do: cisco_templates()
  def for_vendor("Juniper"), do: juniper_templates()
  def for_vendor("juniper"), do: juniper_templates()
  def for_vendor("Arista"), do: arista_templates()
  def for_vendor("arista"), do: arista_templates()
  def for_vendor(_), do: []

  @doc """
  Seeds all built-in templates into the database.
  Skips templates that already exist.

  The tenant schema is determined by the DB connection's search_path in tenant-unaware mode.
  """
  @spec seed!(String.t(), map()) :: {:ok, integer()} | {:error, term()}
  def seed!(tenant_schema, actor) do
    templates = all()

    results =
      Enum.map(templates, fn template ->
        attrs = Map.put(template, :is_builtin, true)

        SNMPOIDTemplate
        |> Ash.Changeset.for_create(:create, attrs, actor: actor, tenant: tenant_schema)
        |> Ash.create(actor: actor)
        |> classify_seed_result()
      end)

    created = Enum.count(results, &(&1 == :created))
    {:ok, created}
  end

  defp classify_seed_result({:ok, _}), do: :created
  defp classify_seed_result({:error, %Ash.Error.Invalid{errors: errors}}), do: classify_ash_error(errors)
  defp classify_seed_result({:error, _}), do: :error

  defp classify_ash_error(errors) do
    # Check if it's a uniqueness error (template already exists)
    if Enum.any?(errors, &match?(%Ash.Error.Changes.InvalidChanges{}, &1)), do: :exists, else: :error
  end

  # Standard MIB-II Templates
  defp standard_templates do
    [
      %{
        name: "System Information",
        description: "Basic system identification and uptime (MIB-II system group)",
        vendor: "Standard",
        category: "System",
        oids: [
          %{oid: ".1.3.6.1.2.1.1.1.0", name: "sysDescr", data_type: "string", scale: 1.0, delta: false},
          %{oid: ".1.3.6.1.2.1.1.3.0", name: "sysUpTime", data_type: "counter", scale: 0.01, delta: false},
          %{oid: ".1.3.6.1.2.1.1.5.0", name: "sysName", data_type: "string", scale: 1.0, delta: false},
          %{oid: ".1.3.6.1.2.1.1.6.0", name: "sysLocation", data_type: "string", scale: 1.0, delta: false},
          %{oid: ".1.3.6.1.2.1.1.4.0", name: "sysContact", data_type: "string", scale: 1.0, delta: false}
        ]
      },
      %{
        name: "Interface Statistics",
        description: "Network interface traffic and status counters (MIB-II interfaces group)",
        vendor: "Standard",
        category: "Network",
        oids: [
          %{oid: ".1.3.6.1.2.1.2.2.1.10", name: "ifInOctets", data_type: "counter", scale: 1.0, delta: true},
          %{oid: ".1.3.6.1.2.1.2.2.1.16", name: "ifOutOctets", data_type: "counter", scale: 1.0, delta: true},
          %{oid: ".1.3.6.1.2.1.2.2.1.8", name: "ifOperStatus", data_type: "gauge", scale: 1.0, delta: false},
          %{oid: ".1.3.6.1.2.1.2.2.1.5", name: "ifSpeed", data_type: "gauge", scale: 1.0, delta: false},
          %{oid: ".1.3.6.1.2.1.2.2.1.7", name: "ifAdminStatus", data_type: "gauge", scale: 1.0, delta: false},
          %{oid: ".1.3.6.1.2.1.2.2.1.14", name: "ifInErrors", data_type: "counter", scale: 1.0, delta: true},
          %{oid: ".1.3.6.1.2.1.2.2.1.20", name: "ifOutErrors", data_type: "counter", scale: 1.0, delta: true}
        ]
      },
      %{
        name: "High-Capacity Interface Statistics",
        description: "64-bit interface counters for high-speed interfaces (IF-MIB)",
        vendor: "Standard",
        category: "Network",
        oids: [
          %{oid: ".1.3.6.1.2.1.31.1.1.1.6", name: "ifHCInOctets", data_type: "counter", scale: 1.0, delta: true},
          %{oid: ".1.3.6.1.2.1.31.1.1.1.10", name: "ifHCOutOctets", data_type: "counter", scale: 1.0, delta: true},
          %{oid: ".1.3.6.1.2.1.31.1.1.1.7", name: "ifHCInUcastPkts", data_type: "counter", scale: 1.0, delta: true},
          %{oid: ".1.3.6.1.2.1.31.1.1.1.11", name: "ifHCOutUcastPkts", data_type: "counter", scale: 1.0, delta: true},
          %{oid: ".1.3.6.1.2.1.31.1.1.1.15", name: "ifHighSpeed", data_type: "gauge", scale: 1_000_000.0, delta: false}
        ]
      },
      %{
        name: "IP Statistics",
        description: "IP layer traffic and forwarding statistics (IP-MIB)",
        vendor: "Standard",
        category: "Network",
        oids: [
          %{oid: ".1.3.6.1.2.1.4.3.0", name: "ipInReceives", data_type: "counter", scale: 1.0, delta: true},
          %{oid: ".1.3.6.1.2.1.4.10.0", name: "ipOutRequests", data_type: "counter", scale: 1.0, delta: true},
          %{oid: ".1.3.6.1.2.1.4.8.0", name: "ipInDiscards", data_type: "counter", scale: 1.0, delta: true},
          %{oid: ".1.3.6.1.2.1.4.6.0", name: "ipForwDatagrams", data_type: "counter", scale: 1.0, delta: true}
        ]
      },
      %{
        name: "TCP Statistics",
        description: "TCP connection and segment counters (TCP-MIB)",
        vendor: "Standard",
        category: "Network",
        oids: [
          %{oid: ".1.3.6.1.2.1.6.9.0", name: "tcpCurrEstab", data_type: "gauge", scale: 1.0, delta: false},
          %{oid: ".1.3.6.1.2.1.6.10.0", name: "tcpInSegs", data_type: "counter", scale: 1.0, delta: true},
          %{oid: ".1.3.6.1.2.1.6.11.0", name: "tcpOutSegs", data_type: "counter", scale: 1.0, delta: true},
          %{oid: ".1.3.6.1.2.1.6.12.0", name: "tcpRetransSegs", data_type: "counter", scale: 1.0, delta: true}
        ]
      },
      %{
        name: "SNMP Statistics",
        description: "SNMP agent statistics and error counters (SNMPv2-MIB)",
        vendor: "Standard",
        category: "System",
        oids: [
          %{oid: ".1.3.6.1.2.1.11.1.0", name: "snmpInPkts", data_type: "counter", scale: 1.0, delta: true},
          %{oid: ".1.3.6.1.2.1.11.2.0", name: "snmpOutPkts", data_type: "counter", scale: 1.0, delta: true},
          %{oid: ".1.3.6.1.2.1.11.8.0", name: "snmpInBadVersions", data_type: "counter", scale: 1.0, delta: true},
          %{oid: ".1.3.6.1.2.1.11.4.0", name: "snmpInBadCommunityNames", data_type: "counter", scale: 1.0, delta: true}
        ]
      }
    ]
  end

  # Cisco Enterprise Templates
  defp cisco_templates do
    [
      %{
        name: "CPU and Memory",
        description: "Cisco CPU utilization and memory pool statistics",
        vendor: "Cisco",
        category: "Performance",
        oids: [
          %{oid: ".1.3.6.1.4.1.9.9.109.1.1.1.1.3.1", name: "cpmCPUTotal5sec", data_type: "gauge", scale: 1.0, delta: false},
          %{oid: ".1.3.6.1.4.1.9.9.109.1.1.1.1.4.1", name: "cpmCPUTotal1min", data_type: "gauge", scale: 1.0, delta: false},
          %{oid: ".1.3.6.1.4.1.9.9.109.1.1.1.1.5.1", name: "cpmCPUTotal5min", data_type: "gauge", scale: 1.0, delta: false},
          %{oid: ".1.3.6.1.4.1.9.9.48.1.1.1.5.1", name: "ciscoMemoryPoolUsed", data_type: "gauge", scale: 1.0, delta: false},
          %{oid: ".1.3.6.1.4.1.9.9.48.1.1.1.6.1", name: "ciscoMemoryPoolFree", data_type: "gauge", scale: 1.0, delta: false}
        ]
      },
      %{
        name: "Environment Sensors",
        description: "Cisco environmental monitoring (temperature, fans, power)",
        vendor: "Cisco",
        category: "Environment",
        oids: [
          %{oid: ".1.3.6.1.4.1.9.9.13.1.3.1.3", name: "ciscoEnvMonTemperatureValue", data_type: "gauge", scale: 1.0, delta: false},
          %{oid: ".1.3.6.1.4.1.9.9.13.1.3.1.6", name: "ciscoEnvMonTemperatureState", data_type: "gauge", scale: 1.0, delta: false},
          %{oid: ".1.3.6.1.4.1.9.9.13.1.4.1.3", name: "ciscoEnvMonFanState", data_type: "gauge", scale: 1.0, delta: false},
          %{oid: ".1.3.6.1.4.1.9.9.13.1.5.1.3", name: "ciscoEnvMonSupplyState", data_type: "gauge", scale: 1.0, delta: false}
        ]
      },
      %{
        name: "BGP Neighbors",
        description: "Cisco BGP peer state and prefix counters",
        vendor: "Cisco",
        category: "Routing",
        oids: [
          %{oid: ".1.3.6.1.4.1.9.9.187.1.2.5.1.3", name: "cbgpPeerState", data_type: "gauge", scale: 1.0, delta: false},
          %{oid: ".1.3.6.1.4.1.9.9.187.1.2.5.1.6", name: "cbgpPeerPrefixAccepted", data_type: "gauge", scale: 1.0, delta: false},
          %{oid: ".1.3.6.1.4.1.9.9.187.1.2.5.1.7", name: "cbgpPeerPrefixDenied", data_type: "counter", scale: 1.0, delta: true},
          %{oid: ".1.3.6.1.4.1.9.9.187.1.2.5.1.11", name: "cbgpPeerPrefixAdvertised", data_type: "gauge", scale: 1.0, delta: false}
        ]
      },
      %{
        name: "Stack Status",
        description: "Cisco StackWise/VSS stack member status",
        vendor: "Cisco",
        category: "Platform",
        oids: [
          %{oid: ".1.3.6.1.4.1.9.9.500.1.2.1.1.1", name: "cswSwitchNumCurrent", data_type: "gauge", scale: 1.0, delta: false},
          %{oid: ".1.3.6.1.4.1.9.9.500.1.2.1.1.6", name: "cswSwitchState", data_type: "gauge", scale: 1.0, delta: false},
          %{oid: ".1.3.6.1.4.1.9.9.500.1.2.1.1.7", name: "cswSwitchMacAddress", data_type: "string", scale: 1.0, delta: false}
        ]
      }
    ]
  end

  # Juniper Enterprise Templates
  defp juniper_templates do
    [
      %{
        name: "CPU and Memory",
        description: "Juniper routing engine CPU and memory utilization",
        vendor: "Juniper",
        category: "Performance",
        oids: [
          %{oid: ".1.3.6.1.4.1.2636.3.1.13.1.8", name: "jnxOperatingCPU", data_type: "gauge", scale: 1.0, delta: false},
          %{oid: ".1.3.6.1.4.1.2636.3.1.13.1.11", name: "jnxOperatingBuffer", data_type: "gauge", scale: 1.0, delta: false},
          %{oid: ".1.3.6.1.4.1.2636.3.1.13.1.15", name: "jnxOperatingMemory", data_type: "gauge", scale: 1.0, delta: false},
          %{oid: ".1.3.6.1.4.1.2636.3.1.13.1.5", name: "jnxOperatingDRAMSize", data_type: "gauge", scale: 1.0, delta: false}
        ]
      },
      %{
        name: "Environment Sensors",
        description: "Juniper environmental monitoring",
        vendor: "Juniper",
        category: "Environment",
        oids: [
          %{oid: ".1.3.6.1.4.1.2636.3.1.13.1.7", name: "jnxOperatingTemp", data_type: "gauge", scale: 1.0, delta: false},
          %{oid: ".1.3.6.1.4.1.2636.3.1.13.1.6", name: "jnxOperatingState", data_type: "gauge", scale: 1.0, delta: false},
          %{oid: ".1.3.6.1.4.1.2636.3.4.1.1.1", name: "jnxFanOperatingState", data_type: "gauge", scale: 1.0, delta: false},
          %{oid: ".1.3.6.1.4.1.2636.3.4.2.1.1", name: "jnxPowerSupplyOperatingState", data_type: "gauge", scale: 1.0, delta: false}
        ]
      },
      %{
        name: "BGP Neighbors",
        description: "Juniper BGP peer statistics",
        vendor: "Juniper",
        category: "Routing",
        oids: [
          %{oid: ".1.3.6.1.4.1.2636.5.1.1.2.1.1.1.2", name: "jnxBgpM2PeerState", data_type: "gauge", scale: 1.0, delta: false},
          %{oid: ".1.3.6.1.4.1.2636.5.1.1.2.6.2.1.7", name: "jnxBgpM2PrefixInPrefixes", data_type: "gauge", scale: 1.0, delta: false},
          %{oid: ".1.3.6.1.4.1.2636.5.1.1.2.6.2.1.8", name: "jnxBgpM2PrefixInPrefixesAccepted", data_type: "gauge", scale: 1.0, delta: false},
          %{oid: ".1.3.6.1.4.1.2636.5.1.1.2.6.2.1.10", name: "jnxBgpM2PrefixOutPrefixes", data_type: "gauge", scale: 1.0, delta: false}
        ]
      },
      %{
        name: "Firewall Counters",
        description: "Juniper firewall filter statistics",
        vendor: "Juniper",
        category: "Security",
        oids: [
          %{oid: ".1.3.6.1.4.1.2636.3.5.2.1.4", name: "jnxFWCounterPacketCount", data_type: "counter", scale: 1.0, delta: true},
          %{oid: ".1.3.6.1.4.1.2636.3.5.2.1.5", name: "jnxFWCounterByteCount", data_type: "counter", scale: 1.0, delta: true}
        ]
      }
    ]
  end

  # Arista Enterprise Templates
  defp arista_templates do
    [
      %{
        name: "Environment Sensors",
        description: "Arista environmental monitoring (temperature, fans, power)",
        vendor: "Arista",
        category: "Environment",
        oids: [
          %{oid: ".1.3.6.1.4.1.30065.3.12.1.1.1.3", name: "aristaEnvMonTempSensorValue", data_type: "gauge", scale: 0.1, delta: false},
          %{oid: ".1.3.6.1.4.1.30065.3.12.1.1.1.5", name: "aristaEnvMonTempSensorState", data_type: "gauge", scale: 1.0, delta: false},
          %{oid: ".1.3.6.1.4.1.30065.3.12.1.2.1.3", name: "aristaEnvMonFanState", data_type: "gauge", scale: 1.0, delta: false},
          %{oid: ".1.3.6.1.4.1.30065.3.12.1.3.1.3", name: "aristaEnvMonPowerSupplyState", data_type: "gauge", scale: 1.0, delta: false}
        ]
      },
      %{
        name: "Queue Statistics",
        description: "Arista interface queue counters",
        vendor: "Arista",
        category: "Network",
        oids: [
          %{oid: ".1.3.6.1.4.1.30065.3.15.1.2.1.5", name: "aristaQosQueueStatDropPackets", data_type: "counter", scale: 1.0, delta: true},
          %{oid: ".1.3.6.1.4.1.30065.3.15.1.2.1.6", name: "aristaQosQueueStatDropBytes", data_type: "counter", scale: 1.0, delta: true},
          %{oid: ".1.3.6.1.4.1.30065.3.15.1.2.1.7", name: "aristaQosQueueStatSentPackets", data_type: "counter", scale: 1.0, delta: true},
          %{oid: ".1.3.6.1.4.1.30065.3.15.1.2.1.8", name: "aristaQosQueueStatSentBytes", data_type: "counter", scale: 1.0, delta: true}
        ]
      },
      %{
        name: "MLAG Status",
        description: "Arista Multi-Chassis Link Aggregation status",
        vendor: "Arista",
        category: "Platform",
        oids: [
          %{oid: ".1.3.6.1.4.1.30065.3.16.1.1.0", name: "aristaMlagDomainId", data_type: "string", scale: 1.0, delta: false},
          %{oid: ".1.3.6.1.4.1.30065.3.16.1.2.0", name: "aristaMlagLocalStatus", data_type: "gauge", scale: 1.0, delta: false},
          %{oid: ".1.3.6.1.4.1.30065.3.16.1.3.0", name: "aristaMlagPeerLinkStatus", data_type: "gauge", scale: 1.0, delta: false}
        ]
      }
    ]
  end
end
