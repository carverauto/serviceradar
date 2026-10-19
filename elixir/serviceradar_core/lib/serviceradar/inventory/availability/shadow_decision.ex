defmodule ServiceRadar.Inventory.Availability.ShadowDecision do
  @moduledoc """
  The resolver's decision for a device while availability runs in `shadow` mode
  (`device_availability_shadow`). Written only by
  `ServiceRadar.Inventory.Availability.Resolution`, on change, under the device lock.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "device_availability_shadow"
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

    attribute :availability_state, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:available, :unavailable, :unknown]]

    attribute :decided_by, :map, public?: true
    attribute :conflict, :boolean, allow_nil?: false, default: false, public?: true
    attribute :agents, :map, public?: true
    attribute :changed_at, :utc_datetime_usec, public?: true
    attribute :computed_at, :utc_datetime_usec, allow_nil?: false, public?: true
  end
end
