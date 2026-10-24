defmodule ServiceRadar.Inventory.ExposureDimensionState do
  @moduledoc "Dictionary publication state owned by source transactions; never an exposure query backend."
  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "exposure_dimension_state"
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
    attribute :kind, :string, primary_key?: true, allow_nil?: false
    attribute :ordinal, :integer, primary_key?: true, allow_nil?: false
    attribute :content, :map, allow_nil?: false
    attribute :payload, :map, allow_nil?: false
    attribute :transition_seq, :integer, allow_nil?: false
  end
end
