defmodule ServiceRadar.Inventory.ExposureDimensionOutbox do
  @moduledoc "Complete dimension messages retained until the JetStream relay receives PubAck."
  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "exposure_dimension_outbox"
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
    attribute :id, :integer, primary_key?: true, allow_nil?: false
    attribute :kind, :string, allow_nil?: false
    attribute :ordinal, :integer, allow_nil?: false
    attribute :transition_seq, :integer, allow_nil?: false
    attribute :payload, :map, allow_nil?: false
    attribute :inserted_at, :utc_datetime_usec, allow_nil?: false
  end
end
