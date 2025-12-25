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
      AshAdmin.Domain
    ]

  admin do
    show? true
  end

  authorization do
    require_actor? true
    authorize :by_default
  end

  resources do
    resource ServiceRadar.Inventory.Device
    resource ServiceRadar.Inventory.Interface
    resource ServiceRadar.Inventory.DeviceGroup
    resource ServiceRadar.Inventory.DeviceIdentifier
    resource ServiceRadar.Inventory.MergeAudit
  end
end
