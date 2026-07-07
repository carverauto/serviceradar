defmodule ServiceRadar.Inventory do
  @moduledoc """
  The Inventory domain manages devices, interfaces, and device groups.

  This domain is responsible for:
  - Device management (OCSF-aligned schema)
  - Network interface tracking
  - Device grouping and organization
  - Device identity reconciliation

  ## Resources

  - `ServiceRadar.Inventory.Device` - Network devices (OCSF-aligned)
  - `ServiceRadar.Inventory.Interface` - Network interfaces
  - `ServiceRadar.Inventory.DeviceGroup` - Device grouping

  ## OCSF Alignment

  Device attributes are mapped to OCSF (Open Cybersecurity Schema Framework)
  columns using the `source:` option for backward compatibility with
  existing database tables.
  """

  use Ash.Domain,
    extensions: [
      AshJsonApi.Domain,
      AshAdmin.Domain,
      AshPaperTrail.Domain
    ]

  admin do
    show?(true)
  end

  paper_trail do
    include_versions? true
  end

  resources do
    resource ServiceRadar.Inventory.AvailabilitySourceProfile
    resource ServiceRadar.Inventory.BumblebeeCatalogEntry
    resource ServiceRadar.Inventory.BumblebeeCatalogSnapshot
    resource ServiceRadar.Inventory.BumblebeeCatalogSource
    resource ServiceRadar.Inventory.BumblebeeDevicePosture
    resource ServiceRadar.Inventory.BumblebeeFinding
    resource ServiceRadar.Inventory.Device
    resource ServiceRadar.Inventory.DeviceAgentAvailability
    resource ServiceRadar.Inventory.Interface
    resource ServiceRadar.Inventory.InterfaceSettings
    resource ServiceRadar.Inventory.InterfaceClassificationRule
    resource ServiceRadar.Inventory.DeviceSNMPCredential
    resource ServiceRadar.Inventory.VisibilityProfile
    resource ServiceRadar.Inventory.DeviceGroup
    resource ServiceRadar.Inventory.DeviceIdentifier
    resource ServiceRadar.Inventory.SourceIdentityConflict
    resource ServiceRadar.Inventory.MergeAudit
    resource ServiceRadar.Inventory.DeviceCleanupSettings
    resource ServiceRadar.Inventory.VirtualizationCluster
    resource ServiceRadar.Inventory.VirtualizationHost
    resource ServiceRadar.Inventory.VirtualizationGuest
    resource ServiceRadar.Inventory.VirtualizationDatastore
    resource ServiceRadar.Inventory.VirtualizationHostDisk
    resource ServiceRadar.Inventory.VirtualizationNetworkInterface
    resource ServiceRadar.Inventory.VirtualizationStorageSystem
    resource ServiceRadar.Inventory.DeviceRiskContribution
    resource ServiceRadar.Inventory.EndpointInventoryArtifact
    resource ServiceRadar.Inventory.EndpointInventoryArtifactContent
    resource ServiceRadar.Inventory.EndpointInventoryPackage
    resource ServiceRadar.Inventory.EndpointInventoryScan
    resource ServiceRadar.Inventory.EndpointInventorySettings
    resource ServiceRadar.Inventory.EndpointPackage
    resource ServiceRadar.Inventory.EndpointVulnerabilityMatch
    resource ServiceRadar.Inventory.AdvisoryCoordinate
    resource ServiceRadar.Inventory.VulnerabilityAdvisory
    resource ServiceRadar.Inventory.VulnerabilityFeedDefinition
    resource ServiceRadar.Inventory.VulnerabilityFeedSnapshot
  end

  authorization do
    require_actor? false
    authorize :by_default
  end
end
