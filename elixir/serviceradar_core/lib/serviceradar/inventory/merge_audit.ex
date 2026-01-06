defmodule ServiceRadar.Inventory.MergeAudit do
  @moduledoc """
  Audit trail for device identity merges.

  Records when devices are merged together during identity reconciliation,
  providing a complete audit trail for compliance and debugging.

  ## Merge Reasons

  - `duplicate_mac` - Devices share the same MAC address
  - `duplicate_armis` - Devices share the same Armis ID
  - `duplicate_netbox` - Devices share the same NetBox ID
  - `manual_merge` - Administrator manually merged devices
  - `identity_resolution` - Automatic identity resolution
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "merge_audit"
    repo ServiceRadar.Repo
  end

  multitenancy do
    strategy :context
  end

  code_interface do
    define :record, action: :record
    define :get_by_device, action: :by_device, args: [:device_id]
    define :get_merged_from, action: :merged_from, args: [:to_device_id]
    define :get_merged_to, action: :merged_to, args: [:from_device_id]
  end

  actions do
    defaults [:read]

    read :by_device do
      description "Get all merge events involving a device"
      argument :device_id, :string, allow_nil?: false

      filter expr(
               from_device_id == ^arg(:device_id) or
                 to_device_id == ^arg(:device_id)
             )
    end

    read :merged_from do
      description "Get all devices that were merged into a canonical device"
      argument :to_device_id, :string, allow_nil?: false
      filter expr(to_device_id == ^arg(:to_device_id))
    end

    read :merged_to do
      description "Get the canonical device a device was merged into"
      argument :from_device_id, :string, allow_nil?: false
      filter expr(from_device_id == ^arg(:from_device_id))
    end

    read :recent do
      description "Get recent merge events"
      argument :limit, :integer, default: 100

      prepare fn query, _context ->
        limit = Ash.Query.get_argument(query, :limit)

        query
        |> Ash.Query.sort(created_at: :desc)
        |> Ash.Query.limit(limit)
      end
    end

    create :record do
      description "Record a merge event"
      accept [:from_device_id, :to_device_id, :reason, :confidence_score, :source, :details]

      change fn changeset, _context ->
        Ash.Changeset.change_new_attribute(changeset, :created_at, DateTime.utc_now())
      end
    end
  end

  policies do
    # Super admins bypass all policies
    bypass always() do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    # Read access for authenticated users
    policy action_type(:read) do
      authorize_if expr(^actor(:role) in [:viewer, :operator, :admin])
    end

    # Only operators/admins can create merge audit entries
    policy action(:record) do
      authorize_if expr(^actor(:role) in [:operator, :admin])
    end
  end

  attributes do
    uuid_primary_key :event_id

    attribute :from_device_id, :string do
      allow_nil? false
      public? true
      description "Device ID that was merged from (the duplicate)"
    end

    attribute :to_device_id, :string do
      allow_nil? false
      public? true
      description "Device ID that was merged to (the canonical device)"
    end

    attribute :reason, :string do
      public? true
      description "Reason for the merge"
    end

    attribute :confidence_score, :decimal do
      public? true
      description "Confidence score of the merge (0.0 - 1.0)"
    end

    attribute :source, :string do
      public? true
      description "Source that triggered the merge"
    end

    attribute :details, :map do
      default %{}
      public? true
      description "Additional details about the merge"
    end

    attribute :created_at, :utc_datetime do
      public? true
      description "When the merge occurred"
    end
  end
end
