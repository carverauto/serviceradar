defmodule ServiceRadar.Inventory.DistinctDeviceAssertion do
  @moduledoc """
  An operator's durable assertion that two devices are different devices (#4604).

  Written when a de-duplication task is resolved as "mark distinct", one row per pair of the
  task's devices, stored with the pair sorted (`device_a < device_b`). Every automatic merge
  path refuses to merge an asserted pair: `MergeEngine.merge_devices/3` checks it first among
  its guards (`:asserted_distinct`), and ingest, alias, registration and the scheduled
  backfill all merge through that function. An administrative merge bypasses it, as it
  bypasses every guard.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "identity_distinct_assertions"
    repo ServiceRadar.Repo
    schema "platform"
  end

  actions do
    defaults [:read]

    read :for_pair do
      argument :device_a, :string, allow_nil?: false
      argument :device_b, :string, allow_nil?: false

      filter expr(
               (device_a == ^arg(:device_a) and device_b == ^arg(:device_b)) or
                 (device_a == ^arg(:device_b) and device_b == ^arg(:device_a))
             )
    end

    create :assert do
      accept [:device_a, :device_b, :task_id, :note]

      upsert? true
      upsert_identity :unique_pair
      upsert_fields [:note, :updated_at]

      change ServiceRadar.Inventory.Changes.SortDevicePair
      change ServiceRadar.Inventory.Changes.SetAssertedBy
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
    operator_action([:assert])
  end

  attributes do
    uuid_primary_key :id

    attribute :device_a, :string do
      allow_nil? false
      public? true
    end

    attribute :device_b, :string do
      allow_nil? false
      public? true
    end

    attribute :task_id, :uuid do
      public? true
      description "The de-duplication task the assertion resolved"
    end

    attribute :asserted_by, :string do
      public? true
    end

    attribute :note, :string do
      public? true
    end

    create_timestamp :inserted_at, type: :utc_datetime_usec
    update_timestamp :updated_at, type: :utc_datetime_usec
  end

  identities do
    identity :unique_pair, [:device_a, :device_b]
  end
end
