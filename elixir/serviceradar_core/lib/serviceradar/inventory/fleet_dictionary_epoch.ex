defmodule ServiceRadar.Inventory.FleetDictionaryEpoch do
  @moduledoc "Persistent identity of the device ordinal dictionary."
  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "fleet_dictionary_epochs"
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
    attribute :name, :string, primary_key?: true, allow_nil?: false
    attribute :epoch, :uuid, allow_nil?: false
  end
end
