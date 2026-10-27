defmodule ServiceRadar.Inventory.Availability.LegacyValue do
  @moduledoc """
  The availability value the legacy writers computed (`device_availability_legacy`,
  design Decision 13), kept so canonical Armis northbound sources with `legacy`
  semantics push exactly what they pushed before merged availability.

  Every device has a row: a trigger copies a new device's initial `is_available`, the
  legacy writers record every later value (`ServiceRadar.Inventory.Availability.LegacyWrites`),
  and migration `20261026220000_converge_merged_availability` seeded the devices of a
  deployment that upgraded before its legacy writers had recorded them.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "device_availability_legacy"
    repo ServiceRadar.Repo
    schema "platform"
  end

  actions do
    defaults [:read]
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
  end

  attributes do
    attribute :device_uid, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :is_available, :boolean, public?: true
    attribute :updated_at, :utc_datetime_usec, allow_nil?: false, public?: true
  end
end
