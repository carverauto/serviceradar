defmodule ServiceRadar.Inventory.DeviceFleetOrdinal do
  @moduledoc "Persistent typed inventory identity; writes are owned by FleetIdentity and database lifecycle hooks."
  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "device_fleet_ordinals"
    schema "platform"
    repo ServiceRadar.Repo
    migrate? false
  end

  actions do
    defaults [:read]
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
  end

  attributes do
    attribute :uid, :string, primary_key?: true, allow_nil?: false
    attribute :ordinal, :integer, allow_nil?: false, constraints: [min: 1, max: 4_294_967_295]
    attribute :tombstoned, :boolean, allow_nil?: false
    attribute :allocated_at, :utc_datetime_usec, allow_nil?: false
  end
end
