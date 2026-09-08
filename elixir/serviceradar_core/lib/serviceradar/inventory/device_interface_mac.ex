defmodule ServiceRadar.Inventory.DeviceInterfaceMac do
  @moduledoc """
  A MAC a device reports on one of its OWN interfaces.

  Corroboration for identity, never identity itself. Nothing here resolves an
  update or names a device; the single question it answers is whether two device
  rows are the same chassis reached at two addresses, or genuinely different
  hardware.

  ## Why this is not a `DeviceIdentifier`

  It was, briefly, as an `:interface_mac` type — and that could not work.
  `device_identifiers` is unique on `(identifier_type, identifier_value,
  partition)` and its upsert deliberately never moves `device_id`, because
  "silent last-writer-wins repoints collapsed distinct devices". But two device
  rows that are the same chassis report the SAME interface MACs, so the first to
  register owned every one and its twin owned none.

  Keying `(device_id, mac)` is the fix: each device records what it observed on
  its own interfaces, and two rows of one chassis may both claim the same MAC —
  which is exactly the signal that they ARE one chassis.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "device_interface_macs"
    repo ServiceRadar.Repo
    schema "platform"
  end

  actions do
    defaults [:read, :destroy]

    create :upsert do
      description "Record a MAC observed on the device's own interface table"
      accept [:device_id, :mac, :partition]

      upsert? true
      upsert_identity :unique_device_mac
      upsert_fields [:last_seen]

      change fn changeset, _context ->
        now = DateTime.utc_now()

        changeset
        |> Ash.Changeset.change_new_attribute(:first_seen, now)
        |> Ash.Changeset.change_attribute(:last_seen, now)
      end
    end
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end

  attributes do
    attribute :device_id, :string, allow_nil?: false, primary_key?: true, public?: true
    attribute :mac, :string, allow_nil?: false, primary_key?: true, public?: true
    attribute :partition, :string, public?: true

    attribute :first_seen, :utc_datetime_usec,
      allow_nil?: false,
      default: &DateTime.utc_now/0,
      public?: true

    attribute :last_seen, :utc_datetime_usec,
      allow_nil?: false,
      default: &DateTime.utc_now/0,
      public?: true
  end

  identities do
    identity :unique_device_mac, [:device_id, :mac]
  end
end
