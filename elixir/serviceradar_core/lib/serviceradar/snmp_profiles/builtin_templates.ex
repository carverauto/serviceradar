defmodule ServiceRadar.SNMPProfiles.BuiltinTemplates do
  @moduledoc """
  Built-in OID templates for common SNMP monitoring scenarios.

  The catalog is organized by vendor:

  - **Standard** - MIB-II / IF-MIB OIDs that work across SNMP devices
  - **Cisco** - Cisco-specific enterprise OIDs
  - **Juniper** - Juniper Networks enterprise OIDs
  - **Arista** - Arista Networks enterprise OIDs

  ## Seeded templates

  The Standard templates are product data. `seed/1` writes them into
  `platform.snmp_oid_templates` with `is_builtin: true` under the fixed ids
  declared here, so an SNMP profile can reference them in `oid_template_ids`
  and every install shares the same ids. A built-in row is read-only to
  operators (`SNMPOIDTemplate` forbids updating or destroying it); an operator
  who wants a variant copies it into a custom template.

  Every seeded OID is poll-correct as it stands, because a profile applies a
  template to devices whose interface indexes the compiler does not know: a
  scalar instance (`.0`) is read with a GET, and an IF-MIB table column is
  walked, so each interface row becomes its own series (`::index:N`, which the
  agent maps to `ifindex:N`).

  The vendor templates are a browsing catalog for copying OIDs into explicit
  targets and custom templates. They are not seeded: several of their OIDs are
  table columns without a walk mode, which a profile could not poll.

  `default_profile_template_ids/0` names the templates the default SNMP profile
  polls: system uptime and the interface counters.
  """

  alias ServiceRadar.SNMPProfiles.SNMPOIDTemplate

  require Ash.Query
  require Logger

  @system_uptime_id "d0c37992-79a2-4432-81ba-3619a57a2671"
  @interface_counters_id "8d2b2e79-952f-4208-9816-aa1c600e1be1"
  @system_information_id "387a23a7-c135-4081-b7fa-1019e3d99d0e"
  @interface_statistics_id "9bb55ab7-63d7-4d9b-a571-3c9b15ab949d"
  @hc_interface_statistics_id "b07fa167-3809-427c-9c96-776e161a433c"
  @ip_statistics_id "696daa16-e014-483d-b4cd-9ea97fcc8f12"
  @tcp_statistics_id "89112d56-c24f-4134-bbe4-09cd1f049c1d"
  @snmp_statistics_id "c8b96506-24a0-4427-8396-8a48a7011a92"

  @doc """
  Returns all built-in OID templates.
  """
  @spec all() :: [map()]
  def all do
    standard_templates() ++ cisco_templates() ++ juniper_templates() ++ arista_templates()
  end

  @doc """
  Returns all built-in OID templates, each with an `:id` the template browser
  selects it by: a seeded template's fixed id, otherwise a slug of its vendor
  and name.
  """
  @spec all_templates() :: [map()]
  def all_templates do
    Enum.map(all(), fn template ->
      Map.put_new_lazy(template, :id, fn ->
        slug =
          template.name
          |> String.downcase()
          |> String.replace(~r/[^a-z0-9]+/, "-")
          |> String.trim("-")

        "#{String.downcase(template.vendor)}-#{slug}"
      end)
    end)
  end

  @doc """
  The built-in templates written into the database, each with its fixed `:id`.
  """
  @spec seeded() :: [map()]
  def seeded, do: standard_templates()

  @doc """
  The ids of the templates the default SNMP profile polls.

  The migration that attaches them to an existing default profile
  (`20261115191431_attach_standard_snmp_templates_to_default_profile.exs`)
  restates these ids literally, as a migration must not depend on code that
  later changes.
  """
  @spec default_profile_template_ids() :: [String.t()]
  def default_profile_template_ids, do: [@system_uptime_id, @interface_counters_id]

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
  Writes every seeded template whose id is not in the database yet and
  returns how many it created.

  An existing row is left as it is, so seeding is idempotent. A template that
  cannot be created is logged and skipped rather than failing the others; the
  one expected cause is an operator's custom template that already holds the
  same vendor and name, which seeding never overwrites.

  The schema is determined by the DB connection's search_path.
  """
  @spec seed(map()) :: {:ok, non_neg_integer()} | {:error, term()}
  def seed(actor) do
    ids = Enum.map(seeded(), & &1.id)

    query =
      SNMPOIDTemplate
      |> Ash.Query.filter(id in ^ids)
      |> Ash.Query.select([:id])

    with {:ok, existing} <- Ash.read(query, actor: actor) do
      present = MapSet.new(existing, & &1.id)

      created =
        seeded()
        |> Enum.reject(&MapSet.member?(present, &1.id))
        |> Enum.count(&create_builtin(&1, actor))

      {:ok, created}
    end
  end

  defp create_builtin(template, actor) do
    {id, attrs} = Map.pop!(template, :id)

    SNMPOIDTemplate
    |> Ash.Changeset.for_create(:seed_builtin, Map.put(attrs, :builtin_id, id), actor: actor)
    |> Ash.create(actor: actor)
    |> case do
      {:ok, _template} ->
        true

      {:error, reason} ->
        Logger.warning(
          "Built-in SNMP OID template #{template.vendor}/#{template.name} was not seeded: " <>
            Exception.message(reason)
        )

        false
    end
  end

  defp walk(oid), do: Map.put(oid, :mode, "walk")

  # Standard MIB-II / IF-MIB templates. These are seeded, so every OID must be
  # pollable through a profile: scalars end in `.0` and are read with a GET;
  # table columns are walked.
  defp standard_templates do
    [
      %{
        id: @system_uptime_id,
        name: "System Uptime",
        description:
          "Time since the SNMP agent last restarted, in seconds (MIB-II sysUpTime). " <>
            "Polled by the default SNMP profile.",
        vendor: "Standard",
        category: "System",
        oids: [
          %{
            oid: ".1.3.6.1.2.1.1.3.0",
            name: "sysUpTime",
            data_type: "gauge",
            scale: 0.01,
            delta: false
          }
        ]
      },
      %{
        id: @interface_counters_id,
        name: "Interface Counters",
        description:
          "Per-interface 64-bit traffic and unicast packet counters, errors, discards and " <>
            "operational status, walked from IF-MIB. Polled by the default SNMP profile. " <>
            "SNMPv1-only devices have no 64-bit counters; attach Interface Statistics for them.",
        vendor: "Standard",
        category: "Network",
        oids:
          Enum.map(
            [
              %{
                oid: ".1.3.6.1.2.1.31.1.1.1.6",
                name: "ifHCInOctets",
                data_type: "counter",
                scale: 1.0,
                delta: true
              },
              %{
                oid: ".1.3.6.1.2.1.31.1.1.1.10",
                name: "ifHCOutOctets",
                data_type: "counter",
                scale: 1.0,
                delta: true
              },
              %{
                oid: ".1.3.6.1.2.1.31.1.1.1.7",
                name: "ifHCInUcastPkts",
                data_type: "counter",
                scale: 1.0,
                delta: true
              },
              %{
                oid: ".1.3.6.1.2.1.31.1.1.1.11",
                name: "ifHCOutUcastPkts",
                data_type: "counter",
                scale: 1.0,
                delta: true
              },
              %{
                oid: ".1.3.6.1.2.1.2.2.1.14",
                name: "ifInErrors",
                data_type: "counter",
                scale: 1.0,
                delta: true
              },
              %{
                oid: ".1.3.6.1.2.1.2.2.1.20",
                name: "ifOutErrors",
                data_type: "counter",
                scale: 1.0,
                delta: true
              },
              %{
                oid: ".1.3.6.1.2.1.2.2.1.13",
                name: "ifInDiscards",
                data_type: "counter",
                scale: 1.0,
                delta: true
              },
              %{
                oid: ".1.3.6.1.2.1.2.2.1.19",
                name: "ifOutDiscards",
                data_type: "counter",
                scale: 1.0,
                delta: true
              },
              %{
                oid: ".1.3.6.1.2.1.2.2.1.8",
                name: "ifOperStatus",
                data_type: "gauge",
                scale: 1.0,
                delta: false
              }
            ],
            &walk/1
          )
      },
      %{
        id: @system_information_id,
        name: "System Information",
        description: "Basic system identification and uptime (MIB-II system group)",
        vendor: "Standard",
        category: "System",
        oids: [
          %{
            oid: ".1.3.6.1.2.1.1.1.0",
            name: "sysDescr",
            data_type: "string",
            scale: 1.0,
            delta: false
          },
          %{
            oid: ".1.3.6.1.2.1.1.3.0",
            name: "sysUpTime",
            data_type: "gauge",
            scale: 0.01,
            delta: false
          },
          %{
            oid: ".1.3.6.1.2.1.1.5.0",
            name: "sysName",
            data_type: "string",
            scale: 1.0,
            delta: false
          },
          %{
            oid: ".1.3.6.1.2.1.1.6.0",
            name: "sysLocation",
            data_type: "string",
            scale: 1.0,
            delta: false
          },
          %{
            oid: ".1.3.6.1.2.1.1.4.0",
            name: "sysContact",
            data_type: "string",
            scale: 1.0,
            delta: false
          }
        ]
      },
      %{
        id: @interface_statistics_id,
        name: "Interface Statistics",
        description:
          "32-bit interface traffic and status counters, walked from the MIB-II interfaces " <>
            "table. For devices without IF-MIB 64-bit counters.",
        vendor: "Standard",
        category: "Network",
        oids:
          Enum.map(
            [
              %{
                oid: ".1.3.6.1.2.1.2.2.1.10",
                name: "ifInOctets",
                data_type: "counter",
                scale: 1.0,
                delta: true
              },
              %{
                oid: ".1.3.6.1.2.1.2.2.1.16",
                name: "ifOutOctets",
                data_type: "counter",
                scale: 1.0,
                delta: true
              },
              %{
                oid: ".1.3.6.1.2.1.2.2.1.8",
                name: "ifOperStatus",
                data_type: "gauge",
                scale: 1.0,
                delta: false
              },
              %{
                oid: ".1.3.6.1.2.1.2.2.1.5",
                name: "ifSpeed",
                data_type: "gauge",
                scale: 1.0,
                delta: false
              },
              %{
                oid: ".1.3.6.1.2.1.2.2.1.7",
                name: "ifAdminStatus",
                data_type: "gauge",
                scale: 1.0,
                delta: false
              },
              %{
                oid: ".1.3.6.1.2.1.2.2.1.14",
                name: "ifInErrors",
                data_type: "counter",
                scale: 1.0,
                delta: true
              },
              %{
                oid: ".1.3.6.1.2.1.2.2.1.20",
                name: "ifOutErrors",
                data_type: "counter",
                scale: 1.0,
                delta: true
              }
            ],
            &walk/1
          )
      },
      %{
        id: @hc_interface_statistics_id,
        name: "High-Capacity Interface Statistics",
        description: "64-bit interface counters and speed for high-speed interfaces (IF-MIB)",
        vendor: "Standard",
        category: "Network",
        oids:
          Enum.map(
            [
              %{
                oid: ".1.3.6.1.2.1.31.1.1.1.6",
                name: "ifHCInOctets",
                data_type: "counter",
                scale: 1.0,
                delta: true
              },
              %{
                oid: ".1.3.6.1.2.1.31.1.1.1.10",
                name: "ifHCOutOctets",
                data_type: "counter",
                scale: 1.0,
                delta: true
              },
              %{
                oid: ".1.3.6.1.2.1.31.1.1.1.7",
                name: "ifHCInUcastPkts",
                data_type: "counter",
                scale: 1.0,
                delta: true
              },
              %{
                oid: ".1.3.6.1.2.1.31.1.1.1.11",
                name: "ifHCOutUcastPkts",
                data_type: "counter",
                scale: 1.0,
                delta: true
              },
              %{
                oid: ".1.3.6.1.2.1.31.1.1.1.15",
                name: "ifHighSpeed",
                data_type: "gauge",
                scale: 1_000_000.0,
                delta: false
              }
            ],
            &walk/1
          )
      },
      %{
        id: @ip_statistics_id,
        name: "IP Statistics",
        description: "IP layer traffic and forwarding statistics (IP-MIB)",
        vendor: "Standard",
        category: "Network",
        oids: [
          %{
            oid: ".1.3.6.1.2.1.4.3.0",
            name: "ipInReceives",
            data_type: "counter",
            scale: 1.0,
            delta: true
          },
          %{
            oid: ".1.3.6.1.2.1.4.10.0",
            name: "ipOutRequests",
            data_type: "counter",
            scale: 1.0,
            delta: true
          },
          %{
            oid: ".1.3.6.1.2.1.4.8.0",
            name: "ipInDiscards",
            data_type: "counter",
            scale: 1.0,
            delta: true
          },
          %{
            oid: ".1.3.6.1.2.1.4.6.0",
            name: "ipForwDatagrams",
            data_type: "counter",
            scale: 1.0,
            delta: true
          }
        ]
      },
      %{
        id: @tcp_statistics_id,
        name: "TCP Statistics",
        description: "TCP connection and segment counters (TCP-MIB)",
        vendor: "Standard",
        category: "Network",
        oids: [
          %{
            oid: ".1.3.6.1.2.1.6.9.0",
            name: "tcpCurrEstab",
            data_type: "gauge",
            scale: 1.0,
            delta: false
          },
          %{
            oid: ".1.3.6.1.2.1.6.10.0",
            name: "tcpInSegs",
            data_type: "counter",
            scale: 1.0,
            delta: true
          },
          %{
            oid: ".1.3.6.1.2.1.6.11.0",
            name: "tcpOutSegs",
            data_type: "counter",
            scale: 1.0,
            delta: true
          },
          %{
            oid: ".1.3.6.1.2.1.6.12.0",
            name: "tcpRetransSegs",
            data_type: "counter",
            scale: 1.0,
            delta: true
          }
        ]
      },
      %{
        id: @snmp_statistics_id,
        name: "SNMP Statistics",
        description: "SNMP agent statistics and error counters (SNMPv2-MIB)",
        vendor: "Standard",
        category: "System",
        oids: [
          %{
            oid: ".1.3.6.1.2.1.11.1.0",
            name: "snmpInPkts",
            data_type: "counter",
            scale: 1.0,
            delta: true
          },
          %{
            oid: ".1.3.6.1.2.1.11.2.0",
            name: "snmpOutPkts",
            data_type: "counter",
            scale: 1.0,
            delta: true
          },
          %{
            oid: ".1.3.6.1.2.1.11.8.0",
            name: "snmpInBadVersions",
            data_type: "counter",
            scale: 1.0,
            delta: true
          },
          %{
            oid: ".1.3.6.1.2.1.11.4.0",
            name: "snmpInBadCommunityNames",
            data_type: "counter",
            scale: 1.0,
            delta: true
          }
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
          %{
            oid: ".1.3.6.1.4.1.9.9.109.1.1.1.1.3.1",
            name: "cpmCPUTotal5sec",
            data_type: "gauge",
            scale: 1.0,
            delta: false
          },
          %{
            oid: ".1.3.6.1.4.1.9.9.109.1.1.1.1.4.1",
            name: "cpmCPUTotal1min",
            data_type: "gauge",
            scale: 1.0,
            delta: false
          },
          %{
            oid: ".1.3.6.1.4.1.9.9.109.1.1.1.1.5.1",
            name: "cpmCPUTotal5min",
            data_type: "gauge",
            scale: 1.0,
            delta: false
          },
          %{
            oid: ".1.3.6.1.4.1.9.9.48.1.1.1.5.1",
            name: "ciscoMemoryPoolUsed",
            data_type: "gauge",
            scale: 1.0,
            delta: false
          },
          %{
            oid: ".1.3.6.1.4.1.9.9.48.1.1.1.6.1",
            name: "ciscoMemoryPoolFree",
            data_type: "gauge",
            scale: 1.0,
            delta: false
          }
        ]
      },
      %{
        name: "Environment Sensors",
        description: "Cisco environmental monitoring (temperature, fans, power)",
        vendor: "Cisco",
        category: "Environment",
        oids: [
          %{
            oid: ".1.3.6.1.4.1.9.9.13.1.3.1.3",
            name: "ciscoEnvMonTemperatureValue",
            data_type: "gauge",
            scale: 1.0,
            delta: false
          },
          %{
            oid: ".1.3.6.1.4.1.9.9.13.1.3.1.6",
            name: "ciscoEnvMonTemperatureState",
            data_type: "gauge",
            scale: 1.0,
            delta: false
          },
          %{
            oid: ".1.3.6.1.4.1.9.9.13.1.4.1.3",
            name: "ciscoEnvMonFanState",
            data_type: "gauge",
            scale: 1.0,
            delta: false
          },
          %{
            oid: ".1.3.6.1.4.1.9.9.13.1.5.1.3",
            name: "ciscoEnvMonSupplyState",
            data_type: "gauge",
            scale: 1.0,
            delta: false
          }
        ]
      },
      %{
        name: "BGP Neighbors",
        description: "Cisco BGP peer state and prefix counters",
        vendor: "Cisco",
        category: "Routing",
        oids: [
          %{
            oid: ".1.3.6.1.4.1.9.9.187.1.2.5.1.3",
            name: "cbgpPeerState",
            data_type: "gauge",
            scale: 1.0,
            delta: false
          },
          %{
            oid: ".1.3.6.1.4.1.9.9.187.1.2.5.1.6",
            name: "cbgpPeerPrefixAccepted",
            data_type: "gauge",
            scale: 1.0,
            delta: false
          },
          %{
            oid: ".1.3.6.1.4.1.9.9.187.1.2.5.1.7",
            name: "cbgpPeerPrefixDenied",
            data_type: "counter",
            scale: 1.0,
            delta: true
          },
          %{
            oid: ".1.3.6.1.4.1.9.9.187.1.2.5.1.11",
            name: "cbgpPeerPrefixAdvertised",
            data_type: "gauge",
            scale: 1.0,
            delta: false
          }
        ]
      },
      %{
        name: "Stack Status",
        description: "Cisco StackWise/VSS stack member status",
        vendor: "Cisco",
        category: "Platform",
        oids: [
          %{
            oid: ".1.3.6.1.4.1.9.9.500.1.2.1.1.1",
            name: "cswSwitchNumCurrent",
            data_type: "gauge",
            scale: 1.0,
            delta: false
          },
          %{
            oid: ".1.3.6.1.4.1.9.9.500.1.2.1.1.6",
            name: "cswSwitchState",
            data_type: "gauge",
            scale: 1.0,
            delta: false
          },
          %{
            oid: ".1.3.6.1.4.1.9.9.500.1.2.1.1.7",
            name: "cswSwitchMacAddress",
            data_type: "string",
            scale: 1.0,
            delta: false
          }
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
          %{
            oid: ".1.3.6.1.4.1.2636.3.1.13.1.8",
            name: "jnxOperatingCPU",
            data_type: "gauge",
            scale: 1.0,
            delta: false
          },
          %{
            oid: ".1.3.6.1.4.1.2636.3.1.13.1.11",
            name: "jnxOperatingBuffer",
            data_type: "gauge",
            scale: 1.0,
            delta: false
          },
          %{
            oid: ".1.3.6.1.4.1.2636.3.1.13.1.15",
            name: "jnxOperatingMemory",
            data_type: "gauge",
            scale: 1.0,
            delta: false
          },
          %{
            oid: ".1.3.6.1.4.1.2636.3.1.13.1.5",
            name: "jnxOperatingDRAMSize",
            data_type: "gauge",
            scale: 1.0,
            delta: false
          }
        ]
      },
      %{
        name: "Environment Sensors",
        description: "Juniper environmental monitoring",
        vendor: "Juniper",
        category: "Environment",
        oids: [
          %{
            oid: ".1.3.6.1.4.1.2636.3.1.13.1.7",
            name: "jnxOperatingTemp",
            data_type: "gauge",
            scale: 1.0,
            delta: false
          },
          %{
            oid: ".1.3.6.1.4.1.2636.3.1.13.1.6",
            name: "jnxOperatingState",
            data_type: "gauge",
            scale: 1.0,
            delta: false
          },
          %{
            oid: ".1.3.6.1.4.1.2636.3.4.1.1.1",
            name: "jnxFanOperatingState",
            data_type: "gauge",
            scale: 1.0,
            delta: false
          },
          %{
            oid: ".1.3.6.1.4.1.2636.3.4.2.1.1",
            name: "jnxPowerSupplyOperatingState",
            data_type: "gauge",
            scale: 1.0,
            delta: false
          }
        ]
      },
      %{
        name: "BGP Neighbors",
        description: "Juniper BGP peer statistics",
        vendor: "Juniper",
        category: "Routing",
        oids: [
          %{
            oid: ".1.3.6.1.4.1.2636.5.1.1.2.1.1.1.2",
            name: "jnxBgpM2PeerState",
            data_type: "gauge",
            scale: 1.0,
            delta: false
          },
          %{
            oid: ".1.3.6.1.4.1.2636.5.1.1.2.6.2.1.7",
            name: "jnxBgpM2PrefixInPrefixes",
            data_type: "gauge",
            scale: 1.0,
            delta: false
          },
          %{
            oid: ".1.3.6.1.4.1.2636.5.1.1.2.6.2.1.8",
            name: "jnxBgpM2PrefixInPrefixesAccepted",
            data_type: "gauge",
            scale: 1.0,
            delta: false
          },
          %{
            oid: ".1.3.6.1.4.1.2636.5.1.1.2.6.2.1.10",
            name: "jnxBgpM2PrefixOutPrefixes",
            data_type: "gauge",
            scale: 1.0,
            delta: false
          }
        ]
      },
      %{
        name: "Firewall Counters",
        description: "Juniper firewall filter statistics",
        vendor: "Juniper",
        category: "Security",
        oids: [
          %{
            oid: ".1.3.6.1.4.1.2636.3.5.2.1.4",
            name: "jnxFWCounterPacketCount",
            data_type: "counter",
            scale: 1.0,
            delta: true
          },
          %{
            oid: ".1.3.6.1.4.1.2636.3.5.2.1.5",
            name: "jnxFWCounterByteCount",
            data_type: "counter",
            scale: 1.0,
            delta: true
          }
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
          %{
            oid: ".1.3.6.1.4.1.30065.3.12.1.1.1.3",
            name: "aristaEnvMonTempSensorValue",
            data_type: "gauge",
            scale: 0.1,
            delta: false
          },
          %{
            oid: ".1.3.6.1.4.1.30065.3.12.1.1.1.5",
            name: "aristaEnvMonTempSensorState",
            data_type: "gauge",
            scale: 1.0,
            delta: false
          },
          %{
            oid: ".1.3.6.1.4.1.30065.3.12.1.2.1.3",
            name: "aristaEnvMonFanState",
            data_type: "gauge",
            scale: 1.0,
            delta: false
          },
          %{
            oid: ".1.3.6.1.4.1.30065.3.12.1.3.1.3",
            name: "aristaEnvMonPowerSupplyState",
            data_type: "gauge",
            scale: 1.0,
            delta: false
          }
        ]
      },
      %{
        name: "Queue Statistics",
        description: "Arista interface queue counters",
        vendor: "Arista",
        category: "Network",
        oids: [
          %{
            oid: ".1.3.6.1.4.1.30065.3.15.1.2.1.5",
            name: "aristaQosQueueStatDropPackets",
            data_type: "counter",
            scale: 1.0,
            delta: true
          },
          %{
            oid: ".1.3.6.1.4.1.30065.3.15.1.2.1.6",
            name: "aristaQosQueueStatDropBytes",
            data_type: "counter",
            scale: 1.0,
            delta: true
          },
          %{
            oid: ".1.3.6.1.4.1.30065.3.15.1.2.1.7",
            name: "aristaQosQueueStatSentPackets",
            data_type: "counter",
            scale: 1.0,
            delta: true
          },
          %{
            oid: ".1.3.6.1.4.1.30065.3.15.1.2.1.8",
            name: "aristaQosQueueStatSentBytes",
            data_type: "counter",
            scale: 1.0,
            delta: true
          }
        ]
      },
      %{
        name: "MLAG Status",
        description: "Arista Multi-Chassis Link Aggregation status",
        vendor: "Arista",
        category: "Platform",
        oids: [
          %{
            oid: ".1.3.6.1.4.1.30065.3.16.1.1.0",
            name: "aristaMlagDomainId",
            data_type: "string",
            scale: 1.0,
            delta: false
          },
          %{
            oid: ".1.3.6.1.4.1.30065.3.16.1.2.0",
            name: "aristaMlagLocalStatus",
            data_type: "gauge",
            scale: 1.0,
            delta: false
          },
          %{
            oid: ".1.3.6.1.4.1.30065.3.16.1.3.0",
            name: "aristaMlagPeerLinkStatus",
            data_type: "gauge",
            scale: 1.0,
            delta: false
          }
        ]
      }
    ]
  end
end
