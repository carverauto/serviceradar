defmodule ServiceRadar.Inventory.Availability.VantageExpectation do
  @moduledoc """
  Whether an enabled composite check expects an agent to reach a device or to be
  blocked from it (`device_vantage_expectations`, design Tier 1c).

  Materialized write-on-change from each vantage input's `expected` value by the
  composite check's full evaluation pass (`ServiceRadar.CompositeChecks.Evaluation`).
  Disabling a check removes its rows (a trigger on `composite_checks.state`) and deleting
  it cascades.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "device_vantage_expectations"
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
    attribute :agent_id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :check_id, :uuid, primary_key?: true, allow_nil?: false, public?: true

    attribute :expectation, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:reachable, :blocked]]

    attribute :updated_at, :utc_datetime_usec, allow_nil?: false, public?: true
  end
end
