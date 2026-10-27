defmodule ServiceRadar.Inventory.Availability.Invalidation do
  @moduledoc """
  One entry of the append-only availability invalidation log
  (`availability_invalidations`, design Decision 1).

  Database triggers, and an inline resolution that could not run, append with a plain
  INSERT; the resolver worker claims and deletes entries.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "availability_invalidations"
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
    attribute :id, :integer, primary_key?: true, allow_nil?: false, generated?: true
    attribute :device_uid, :string, allow_nil?: false, public?: true
    attribute :enqueued_at, :utc_datetime_usec, allow_nil?: false, public?: true
  end
end
