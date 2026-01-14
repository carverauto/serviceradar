defmodule ServiceRadar.SNMPProfiles do
  @moduledoc """
  Domain for SNMP monitoring configuration.

  SNMPProfiles provides admin-managed profiles for configuring SNMP monitoring
  in agents. Profiles define which SNMP targets to poll, what OIDs to collect,
  and authentication settings.

  ## Resources

  - `SNMPProfile` - Top-level profile configuration with device targeting
  - `SNMPTarget` - Individual SNMP device/host configuration
  - `SNMPOIDConfig` - OID definitions for a target
  - `SNMPOIDTemplate` - Reusable OID template definitions

  ## Device Targeting

  Like SysmonProfiles, SNMP profiles use SRQL queries to target which devices
  (typically network monitoring agents) should receive the profile:

      # Target devices that monitor the core network
      target_query: "in:devices tags.role:network-monitor"

      # Target devices in the datacenter
      target_query: "in:devices location:datacenter-1"
  """

  use Ash.Domain, extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  authorization do
    require_actor? false
    authorize :by_default
  end

  resources do
    resource ServiceRadar.SNMPProfiles.SNMPProfile
    resource ServiceRadar.SNMPProfiles.SNMPTarget
    resource ServiceRadar.SNMPProfiles.SNMPOIDConfig
    resource ServiceRadar.SNMPProfiles.SNMPOIDTemplate
  end
end
