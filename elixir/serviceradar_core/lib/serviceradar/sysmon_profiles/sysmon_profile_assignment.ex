defmodule ServiceRadar.SysmonProfiles.SysmonProfileAssignment do
  @moduledoc """
  Assignment of sysmon profiles to devices or tags.

  SysmonProfileAssignment enables flexible profile targeting:
  - Device-specific assignments: Directly assign a profile to a specific device
  - Tag-based assignments: Assign a profile to all devices matching a tag

  ## Assignment Types

  - `:device` - Direct assignment to a specific device by UID
  - `:tag` - Assignment based on device tags (key/value matching)

  ## Resolution Priority

  When resolving which profile applies to a device:
  1. Device-specific assignment (highest priority)
  2. Tag-based assignments (ordered by priority field, highest first)
  3. Default tenant profile (fallback)

  ## Usage

      # Assign profile to a specific device
      SysmonProfileAssignment
      |> Ash.Changeset.for_create(:create, %{
        profile_id: profile.id,
        assignment_type: :device,
        device_uid: "device-abc123"
      })
      |> Ash.create!()

      # Assign profile to all devices with a tag
      SysmonProfileAssignment
      |> Ash.Changeset.for_create(:create, %{
        profile_id: profile.id,
        assignment_type: :tag,
        tag_key: "environment",
        tag_value: "production",
        priority: 10
      })
      |> Ash.create!()
  """

  use Ash.Resource,
    domain: ServiceRadar.SysmonProfiles,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [ServiceRadar.AgentConfig.ConfigInvalidationNotifier]

  postgres do
    table "sysmon_profile_assignments"
    repo ServiceRadar.Repo
  end

  multitenancy do
    strategy :context
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [
        :profile_id,
        :assignment_type,
        :device_uid,
        :tag_key,
        :tag_value,
        :priority
      ]

      change ServiceRadar.Changes.AssignTenantId

      # Validate assignment type constraints
      validate fn changeset, _context ->
        assignment_type = Ash.Changeset.get_attribute(changeset, :assignment_type)
        device_uid = Ash.Changeset.get_attribute(changeset, :device_uid)
        tag_key = Ash.Changeset.get_attribute(changeset, :tag_key)

        case assignment_type do
          :device when is_nil(device_uid) or device_uid == "" ->
            {:error, field: :device_uid, message: "is required for device assignments"}

          :tag when is_nil(tag_key) or tag_key == "" ->
            {:error, field: :tag_key, message: "is required for tag assignments"}

          _ ->
            :ok
        end
      end
    end

    update :update do
      accept [
        :priority
      ]

      # Only allow changing priority, not the assignment target
    end

    read :for_device do
      description "Get assignments that apply to a specific device"
      argument :device_uid, :string, allow_nil?: false

      filter expr(
               assignment_type == :device and device_uid == ^arg(:device_uid)
             )
    end

    read :for_tag do
      description "Get tag-based assignments"
      argument :tag_key, :string, allow_nil?: false
      argument :tag_value, :string, allow_nil?: true

      filter expr(
               assignment_type == :tag and
                 tag_key == ^arg(:tag_key) and
                 (is_nil(^arg(:tag_value)) or tag_value == ^arg(:tag_value))
             )
    end

    read :by_profile do
      description "List all assignments for a specific profile"
      argument :profile_id, :uuid, allow_nil?: false

      filter expr(profile_id == ^arg(:profile_id))
    end
  end

  policies do
    # Super admins can do anything
    bypass always() do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    # System actors can perform all operations (tenant isolation via schema)
    bypass always() do
      authorize_if actor_attribute_equals(:role, :system)
    end

    # Admins can manage assignments
    policy action_type(:create) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action_type(:update) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action_type(:destroy) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    # Non-admin users can read assignments
    policy action_type(:read) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :viewer)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :tenant_id, :uuid do
      allow_nil? false
      public? false
      description "Tenant this assignment belongs to"
    end

    attribute :profile_id, :uuid do
      allow_nil? false
      public? true
      description "The profile being assigned"
    end

    attribute :assignment_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:device, :tag]
      description "Type of assignment: :device or :tag"
    end

    # Device-specific assignment fields
    attribute :device_uid, :string do
      allow_nil? true
      public? true
      description "Device UID for device-type assignments"
    end

    # Tag-based assignment fields
    attribute :tag_key, :string do
      allow_nil? true
      public? true
      description "Tag key for tag-type assignments"
    end

    attribute :tag_value, :string do
      allow_nil? true
      public? true
      description "Tag value for tag-type assignments (optional, matches any value if nil)"
    end

    attribute :priority, :integer do
      allow_nil? false
      public? true
      default 0
      description "Priority for resolution order (higher = more priority)"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :profile, ServiceRadar.SysmonProfiles.SysmonProfile do
      source_attribute :profile_id
      destination_attribute :id
      allow_nil? false
      define_attribute? false
    end
  end

  identities do
    # Ensure no duplicate device assignments per profile
    identity :unique_device_assignment, [:tenant_id, :profile_id, :device_uid],
      where: expr(assignment_type == :device and not is_nil(device_uid))

    # Ensure no duplicate tag assignments per profile
    identity :unique_tag_assignment, [:tenant_id, :profile_id, :tag_key, :tag_value],
      where: expr(assignment_type == :tag and not is_nil(tag_key))
  end
end
