defmodule ServiceRadar.Inventory.DeviceIdentifier do
  @moduledoc """
  Device identifier resource for the DIRE (Device Identity and Reconciliation Engine).

  This resource stores normalized identifiers tied to devices, enabling identity
  resolution across different identifier types (MAC, Armis ID, NetBox ID, etc.).

  ## Identifier Types

  Strong identifiers (in priority order):
  - `armis_device_id` - Armis platform device ID
  - `integration_id` - Generic integration ID
  - `netbox_device_id` - NetBox device ID
  - `mac` - MAC address (normalized uppercase, no separators)

  Weak identifier:
  - `ip` - IP address (only used when no strong identifiers present)

  ## Confidence Levels

  - `strong` - High confidence, from authoritative sources
  - `medium` - Moderate confidence
  - `weak` - Low confidence, needs verification
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @identifier_types [:armis_device_id, :integration_id, :netbox_device_id, :mac, :ip]
  @confidence_levels [:strong, :medium, :weak]

  postgres do
    table "device_identifiers"
    repo ServiceRadar.Repo
  end

  multitenancy do
    strategy :context
  end

  code_interface do
    define :lookup, action: :lookup, args: [:identifier_type, :identifier_value]
    define :get_by_device, action: :by_device, args: [:device_id]
    define :register, action: :register
    define :upsert, action: :upsert
  end

  actions do
    defaults [:read]

    read :by_device do
      description "Get all identifiers for a device"
      argument :device_id, :string, allow_nil?: false
      filter expr(device_id == ^arg(:device_id))
    end

    read :lookup do
      description "Lookup device by identifier type and value"
      argument :identifier_type, :atom, allow_nil?: false
      argument :identifier_value, :string, allow_nil?: false
      argument :partition, :string, default: "default"

      filter expr(
               identifier_type == ^arg(:identifier_type) and
                 identifier_value == ^arg(:identifier_value) and
                 partition == ^arg(:partition)
             )
    end

    read :lookup_any do
      description "Lookup device by any matching identifier"
      argument :identifiers, {:array, :map}, allow_nil?: false

      prepare fn query, _context ->
        identifiers = Ash.Query.get_argument(query, :identifiers)

        if Enum.empty?(identifiers) do
          query
        else
          # Build OR conditions for each identifier
          conditions =
            Enum.map(identifiers, fn %{type: type, value: value, partition: partition} ->
              partition = partition || "default"

              {:and,
               [
                 {:==, [:identifier_type], type},
                 {:==, [:identifier_value], value},
                 {:==, [:partition], partition}
               ]}
            end)

          Ash.Query.filter(query, {:or, conditions})
        end
      end
    end

    create :register do
      description "Register a new identifier for a device"

      accept [
        :device_id,
        :identifier_type,
        :identifier_value,
        :partition,
        :confidence,
        :source,
        :verified,
        :metadata
      ]

      change fn changeset, _context ->
        now = DateTime.utc_now()

        changeset
        |> Ash.Changeset.change_new_attribute(:first_seen, now)
        |> Ash.Changeset.change_new_attribute(:last_seen, now)
      end
    end

    update :touch do
      description "Update last_seen timestamp"
      change set_attribute(:last_seen, &DateTime.utc_now/0)
    end

    update :verify do
      description "Mark identifier as verified"
      change set_attribute(:verified, true)
      change set_attribute(:last_seen, &DateTime.utc_now/0)
    end

    create :upsert do
      description "Create or update identifier"

      accept [
        :device_id,
        :identifier_type,
        :identifier_value,
        :partition,
        :confidence,
        :source,
        :verified,
        :metadata
      ]

      upsert? true
      upsert_identity :unique_identifier
      upsert_fields [:device_id, :last_seen, :confidence, :source, :verified, :metadata]

      change fn changeset, _context ->
        now = DateTime.utc_now()

        changeset
        |> Ash.Changeset.change_new_attribute(:first_seen, now)
        |> Ash.Changeset.change_attribute(:last_seen, now)
      end
    end
  end

  policies do
    # Super admins bypass all policies
    bypass always() do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    # Read access for authenticated users in same tenant
    # Note: device_identifiers doesn't have tenant_id; schema isolation handles tenancy.
    policy action_type(:read) do
      authorize_if expr(^actor(:role) in [:viewer, :operator, :admin])
    end

    # Create/update: operators and admins
    policy action([:register, :upsert, :touch, :verify]) do
      authorize_if expr(^actor(:role) in [:operator, :admin])
    end
  end

  attributes do
    integer_primary_key :id

    attribute :device_id, :string do
      allow_nil? false
      public? true
      description "Device ID (sr:uuid format) this identifier maps to"
    end

    attribute :identifier_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: @identifier_types
      description "Type of identifier (armis_device_id, mac, netbox_device_id, etc.)"
    end

    attribute :identifier_value, :string do
      allow_nil? false
      public? true
      description "The identifier value"
    end

    attribute :partition, :string do
      default "default"
      public? true
      description "Partition for overlapping IP spaces"
    end

    attribute :confidence, :atom do
      default :strong
      constraints one_of: @confidence_levels
      public? true
      description "Confidence level of this identifier mapping"
    end

    attribute :source, :string do
      public? true
      description "Source that provided this identifier"
    end

    attribute :first_seen, :utc_datetime do
      public? true
      description "When this identifier was first seen"
    end

    attribute :last_seen, :utc_datetime do
      public? true
      description "When this identifier was last seen"
    end

    attribute :verified, :boolean do
      default false
      public? true
      description "Whether this identifier has been verified"
    end

    attribute :metadata, :map do
      default %{}
      public? true
      description "Additional metadata"
    end
  end

  relationships do
    belongs_to :device, ServiceRadar.Inventory.Device do
      source_attribute :device_id
      destination_attribute :uid
      define_attribute? false
      allow_nil? false
      public? true
      description "Device this identifier belongs to"
    end
  end

  calculations do
    calculate :is_strong, :boolean, expr(confidence == :strong)

    calculate :priority,
              :integer,
              expr(
                cond do
                  identifier_type == :armis_device_id -> 1
                  identifier_type == :integration_id -> 2
                  identifier_type == :netbox_device_id -> 3
                  identifier_type == :mac -> 4
                  identifier_type == :ip -> 5
                  true -> 99
                end
              )
  end

  identities do
    identity :unique_identifier, [:identifier_type, :identifier_value, :partition]
  end
end
