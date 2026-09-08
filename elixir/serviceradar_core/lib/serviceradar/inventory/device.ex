defmodule ServiceRadar.Inventory.Device do
  @moduledoc """
  Device resource for network inventory (OCSF v1.7.0 Device object).

  Maps to the `ocsf_devices` table with OCSF-aligned attributes.
  Devices can be discovered by gateways, agents, or external sources.

  ## OCSF Type IDs

  - 0: Unknown
  - 1: Server
  - 2: Desktop
  - 3: Laptop
  - 4: Tablet
  - 5: Mobile
  - 6: Virtual
  - 7: IOT
  - 8: Browser
  - 9: Firewall
  - 10: Switch
  - 11: Hub
  - 12: Router
  - 13: IDS
  - 14: IPS
  - 15: Load Balancer
  - 99: Other
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    notifiers: [ServiceRadar.Inventory.DeviceNotifier],
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource],
    primary_read_warning?: false

  alias ServiceRadar.Inventory.Changes.BumpIdentityRevision
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  require Ash.Query

  @devices_view_check {ActorHasPermission, permission: "devices.view"}
  @devices_create_check {ActorHasPermission, permission: "devices.create"}
  @devices_update_check {ActorHasPermission, permission: "devices.update"}
  @devices_delete_check {ActorHasPermission, permission: "devices.delete"}
  @devices_bulk_delete_check {ActorHasPermission, permission: "devices.bulk_delete"}
  @devices_facts_write_check {ActorHasPermission, permission: "devices.facts.write"}
  @device_create_fields [
    :uid,
    :type_id,
    :type,
    :name,
    :hostname,
    :ip,
    :partition,
    :mac,
    :uid_alt,
    :vendor_name,
    :model,
    :domain,
    :zone,
    :subnet_uid,
    :vlan_uid,
    :region,
    :first_seen_time,
    :last_seen_time,
    :created_time,
    :modified_time,
    :risk_level_id,
    :risk_level,
    :risk_score,
    :is_managed,
    :is_compliant,
    :is_trusted,
    :is_active,
    :os,
    :hw_info,
    :network_interfaces,
    :owner,
    :org,
    :groups,
    :agent_list,
    :gateway_id,
    :agent_id,
    :management_device_id,
    :discovery_sources,
    :tags,
    :is_available,
    :availability_source_agent_id,
    :availability_source_profile_id,
    :metadata
  ]
  @device_update_fields [
    :type_id,
    :type,
    :name,
    :hostname,
    :ip,
    :mac,
    :gateway_id,
    :agent_id,
    :management_device_id,
    :vendor_name,
    :model,
    :domain,
    :zone,
    :risk_level_id,
    :risk_level,
    :risk_score,
    :is_managed,
    :is_compliant,
    :is_trusted,
    :is_active,
    :os,
    :hw_info,
    :network_interfaces,
    :owner,
    :org,
    :groups,
    :agent_list,
    :discovery_sources,
    :is_available,
    :availability_source_agent_id,
    :availability_source_profile_id,
    :tags,
    :metadata,
    :group_id,
    :last_seen_time
  ]
  @gateway_sync_fields [
    :type_id,
    :type,
    :agent_id,
    :management_device_id,
    :hostname,
    :ip,
    :is_available,
    :is_managed,
    :is_trusted,
    :discovery_sources,
    :last_seen_time,
    :metadata
  ]
  @group_fields [:group_id]
  @availability_fields [:is_available]
  @availability_source_fields [:availability_source_agent_id, :availability_source_profile_id]
  @soft_delete_fields [:deleted_reason, :deleted_by]

  postgres do
    table "ocsf_devices"
    repo ServiceRadar.Repo
    schema "platform"

    # ocsf_devices_unique_active_ip_idx is unique on (partition, ip) for live
    # rows with a non-blank address (migrations 20260213201000 and
    # 20260825120000), and the same IP may exist in more than one partition.
    # Declaring it here (rather than as an identity, which would attribute
    # violations to the composite key's first field) adds
    # `unique_constraint(:ip, name: ...)` to every changeset, so a Postgres
    # uniqueness raise surfaces as an `ip` "has already been taken" error
    # instead of Ash.Error.Unknown wrapping Ecto.ConstraintError.
    unique_index_names [{[:ip], "ocsf_devices_unique_active_ip_idx"}]
  end

  json_api do
    type "device"

    routes do
      base "/devices"

      get :by_uid
      index :read
    end
  end

  code_interface do
    define :get_by_uid, action: :by_uid, args: [:uid, :include_deleted]
    define :get_by_ip, action: :by_ip, args: [:ip, :include_deleted]
    define :get_by_mac, action: :by_mac, args: [:mac, :include_deleted]
    define :soft_delete, action: :soft_delete, args: [:deleted_reason, :deleted_by]
    define :restore, action: :restore
    define :bump_identity_revision, action: :bump_identity_revision
    define :mark_active, action: :mark_active
    define :mark_inactive, action: :mark_inactive
    define :bulk_soft_delete, action: :bulk_soft_delete, args: [:device_uids, :deleted_reason]
  end

  actions do
    read :read do
      primary? true

      argument :include_deleted, :boolean do
        # Optional for API callers (defaults to false).
        # AshJsonApi treats allow_nil?: false action arguments as required query params.
        allow_nil? true
        default false
      end

      filter expr(is_nil(deleted_at) or ^arg(:include_deleted))
      pagination keyset?: true, default_limit: 5000
    end

    read :by_uid do
      argument :uid, :string, allow_nil?: false

      argument :include_deleted, :boolean do
        allow_nil? true
        default false
      end

      get? true
      filter expr(uid == ^arg(:uid) and (is_nil(deleted_at) or ^arg(:include_deleted)))
    end

    read :by_ip do
      argument :ip, :string, allow_nil?: false

      argument :partition, :string do
        allow_nil? true
      end

      argument :include_deleted, :boolean do
        allow_nil? true
        default false
      end

      filter expr(
               ip == ^arg(:ip) and (is_nil(deleted_at) or ^arg(:include_deleted)) and
                 (is_nil(^arg(:partition)) or ^arg(:partition) == "" or
                    partition == ^arg(:partition))
             )
    end

    read :by_mac do
      argument :mac, :string, allow_nil?: false

      argument :include_deleted, :boolean do
        allow_nil? true
        default false
      end

      filter expr(mac == ^arg(:mac) and (is_nil(deleted_at) or ^arg(:include_deleted)))
    end

    read :by_gateway do
      argument :gateway_id, :string, allow_nil?: false

      argument :include_deleted, :boolean do
        allow_nil? true
        default false
      end

      filter expr(
               gateway_id == ^arg(:gateway_id) and (is_nil(deleted_at) or ^arg(:include_deleted))
             )
    end

    read :available do
      description "Devices currently available"
      filter expr(is_available == true and is_nil(deleted_at))
    end

    read :recently_seen do
      description "Devices seen in the last hour"
      filter expr(last_seen_time > ago(1, :hour) and is_nil(deleted_at))
    end

    create :create do
      accept @device_create_fields

      change fn changeset, _context ->
        now = DateTime.utc_now()

        changeset
        |> Ash.Changeset.change_new_attribute(:first_seen_time, now)
        |> Ash.Changeset.change_new_attribute(:last_seen_time, now)
        |> Ash.Changeset.change_new_attribute(:created_time, now)
        |> Ash.Changeset.change_new_attribute(:is_managed, true)
        |> Ash.Changeset.change_new_attribute(:is_active, true)
      end
    end

    update :update do
      accept @device_update_fields

      change set_attribute(:modified_time, &DateTime.utc_now/0)
      validate ServiceRadar.Inventory.Validations.AgentManaged
    end

    update :gateway_sync do
      accept @gateway_sync_fields

      change set_attribute(:deleted_at, nil)
      change set_attribute(:deleted_by, nil)
      change set_attribute(:deleted_reason, nil)
      change set_attribute(:modified_time, &DateTime.utc_now/0)
    end

    update :assign_to_group do
      description "Assign device to a group"
      accept @group_fields
      change set_attribute(:modified_time, &DateTime.utc_now/0)
    end

    update :touch do
      description "Update last_seen_time without other changes"
      change set_attribute(:last_seen_time, &DateTime.utc_now/0)
    end

    update :bump_identity_revision do
      description "Record that this device's identity changed (merge, unmerge, split, alias or identifier reassignment, soft delete, restore)"

      # Accepts nothing on purpose. The revision is the only thing this action
      # moves, and it moves by expression so concurrent transitions cannot lose a
      # bump. Anything that also needs to write attributes should do that in its
      # own action and call this one as well.
      accept []
      require_atomic? true

      change BumpIdentityRevision
    end

    update :set_availability do
      accept @availability_fields
      change set_attribute(:modified_time, &DateTime.utc_now/0)
    end

    update :set_availability_source do
      accept @availability_source_fields
      change set_attribute(:modified_time, &DateTime.utc_now/0)
    end

    update :merge_metadata do
      description """
      Merge a patch into metadata in the database, leaving every key the patch does
      not name untouched.

      Use this instead of reading metadata, Map.put-ing into it and writing the
      whole map back: that loses whatever another writer committed in between,
      silently. See ServiceRadar.Inventory.Changes.MergeDeviceMetadata.
      """

      accept []
      require_atomic? true

      argument :metadata_patch, :map, allow_nil?: false

      change ServiceRadar.Inventory.Changes.MergeDeviceMetadata
      change set_attribute(:modified_time, &DateTime.utc_now/0)
    end

    update :write_facts do
      description """
      Merge externally supplied scalar facts into metadata with server-stamped
      provenance. Phase-1 ingress for external validation tools such as
      OpenText Network Automation.
      """

      accept []

      argument :facts, :map, allow_nil?: false

      change ServiceRadar.Inventory.Changes.MergeDeviceFacts
      change set_attribute(:modified_time, &DateTime.utc_now/0)
    end

    update :soft_delete do
      accept @soft_delete_fields

      change set_attribute(:deleted_at, &DateTime.utc_now/0)
      change set_attribute(:modified_time, &DateTime.utc_now/0)

      # A soft delete is an identity transition: the uid stops naming a live
      # thing. This is also what covers the merge source, since
      # MergeEngine.tombstone_merged_device/2 tombstones through this action.
      change BumpIdentityRevision
    end

    update :restore do
      change set_attribute(:deleted_at, nil)
      change set_attribute(:deleted_by, nil)
      change set_attribute(:deleted_reason, nil)
      change set_attribute(:modified_time, &DateTime.utc_now/0)

      # The mirror of :soft_delete -- the uid names a live thing again. Covers the
      # unmerge from-device, which MergeEngine.recreate_device/3 restores through
      # this action.
      change BumpIdentityRevision
    end

    update :mark_active do
      description "Return a device to active service"

      change set_attribute(:is_active, true)
      change set_attribute(:modified_time, &DateTime.utc_now/0)
    end

    update :mark_inactive do
      description "Mark a device out of service without deleting it"

      change set_attribute(:is_active, false)
      change set_attribute(:modified_time, &DateTime.utc_now/0)
    end

    action :bulk_soft_delete do
      argument :device_uids, {:array, :string}, allow_nil?: false
      argument :deleted_reason, :string

      run fn input, context ->
        actor = Map.get(context, :actor)
        device_uids = input.arguments.device_uids || []
        deleted_reason = input.arguments.deleted_reason
        deleted_by = actor_identifier(actor)

        query =
          __MODULE__
          |> Ash.Query.for_read(:read, %{include_deleted: true})
          |> Ash.Query.filter(uid in ^device_uids)

        result =
          Ash.bulk_update(
            query,
            :soft_delete,
            %{
              deleted_reason: deleted_reason,
              deleted_by: deleted_by
            },
            actor: actor,
            return_errors?: true,
            return_records?: false
          )

        case result do
          %Ash.BulkResult{status: :success} ->
            :ok

          %Ash.BulkResult{status: :partial_success, errors: errors} ->
            {:error, List.first(errors) || :partial_failure}

          %Ash.BulkResult{status: :error, errors: errors} ->
            {:error, List.first(errors) || :bulk_delete_failed}

          other ->
            {:error, other}
        end
      end
    end

    destroy :destroy do
      description "Delete device records (used during merges)"
    end

    # Identity reconciliation actions

    action :resolve_identity do
      description "Resolve device identity from identifiers (MAC, Armis ID, etc.)"
      argument :device_update, :map, allow_nil?: false

      run fn input, _context ->
        update = input.arguments.device_update
        IdentityReconciler.resolve_device_id(update)
      end
    end

    action :register_identifiers do
      description "Register strong identifiers for a device"
      argument :device_id, :string, allow_nil?: false
      argument :identifiers, :map, allow_nil?: false

      run fn input, context ->
        device_id = input.arguments.device_id
        ids = input.arguments.identifiers
        actor = Map.get(context, :actor)

        IdentityReconciler.register_identifiers(device_id, ids, actor: actor)
      end
    end
  end

  policies do
    import ServiceRadar.Policies

    # System actors can perform all operations (schema isolation via search_path)
    system_bypass()

    # Read access: authenticated users (schema isolation via search_path)
    read_with_permission(@devices_view_check)

    # Create devices: operators/admins (schema isolation via search_path)
    action_type_with_permission(:create, @devices_create_check)

    # Update devices: operators/admins (schema isolation via search_path)
    action_type_with_permission(:update, @devices_update_check)

    # Destroy devices: operators/admins (schema isolation via search_path)
    action_type_with_permission(:destroy, @devices_delete_check)

    action_with_permission(:bulk_soft_delete, @devices_bulk_delete_check)

    # Fact writes get their own permission rather than riding on devices.update:
    # an external validation tool should be able to set a boolean without also
    # being able to rename, retag, or reassign the device.
    action_with_permission(:write_facts, @devices_facts_write_check)
  end

  attributes do
    # OCSF Core Identity - uid is the primary key
    attribute :uid, :string do
      allow_nil? false
      primary_key? true
      public? true
      description "Unique device identifier"
    end

    attribute :type_id, :integer do
      default 0
      public? true
      description "OCSF device type ID"
    end

    attribute :type, :string do
      public? true
      description "OCSF device type name"
    end

    attribute :name, :string do
      public? true
      description "Device display name"
    end

    attribute :hostname, :string do
      public? true
      description "Device hostname"
    end

    attribute :ip, :string do
      public? true
      description "Primary IP address"
    end

    attribute :partition, :string do
      allow_nil? false
      default "default"
      public? true
      description "Network partition. The same IP may exist in more than one partition."
    end

    attribute :mac, :string do
      public? true
      description "Primary MAC address"
    end

    # OCSF Extended Identity
    attribute :uid_alt, :string do
      public? true
      description "Alternative unique identifier"
    end

    attribute :vendor_name, :string do
      public? true
      description "Device vendor/manufacturer"
    end

    attribute :model, :string do
      public? true
      description "Device model"
    end

    attribute :domain, :string do
      public? true
      description "Network domain"
    end

    attribute :zone, :string do
      public? true
      description "Network zone"
    end

    attribute :subnet_uid, :string do
      public? true
      description "Subnet identifier"
    end

    attribute :vlan_uid, :string do
      public? true
      description "VLAN identifier"
    end

    attribute :switch_port_attachment, :map do
      public? true
      description "Canonical access-switch attachment promoted from source facts"
    end

    attribute :region, :string do
      public? true
      description "Geographic region"
    end

    # OCSF Temporal
    attribute :first_seen_time, :utc_datetime do
      public? true
      description "When device was first discovered"
    end

    attribute :last_seen_time, :utc_datetime do
      public? true
      description "When device was last seen"
    end

    attribute :created_time, :utc_datetime do
      public? true
      description "Record creation time"
    end

    attribute :modified_time, :utc_datetime do
      public? true
      description "Record modification time"
    end

    # OCSF Risk and Compliance
    attribute :risk_level_id, :integer do
      public? true
      description "OCSF risk level ID (0-4)"
    end

    attribute :risk_level, :string do
      public? true
      description "Risk level name"
    end

    attribute :risk_score, :integer do
      public? true
      description "Numeric risk score"
    end

    attribute :is_managed, :boolean do
      default false
      public? true
      description "Whether device is managed"
    end

    attribute :is_compliant, :boolean do
      public? true
      description "Compliance status"
    end

    attribute :is_trusted, :boolean do
      default false
      public? true
      description "Trust status"
    end

    attribute :is_active, :boolean do
      allow_nil? false
      default true
      public? true
      description "Whether device is currently in service"
    end

    attribute :identity_revision, :integer do
      allow_nil? false
      default 1

      # Deliberately NOT public. Every consumer of the fence is internal -- ingest
      # pipelines, Oban jobs, gateway sync -- and no external API client pins a
      # revision. Publishing it would put an internal concurrency mechanism into
      # the REST contract, which should be a deliberate decision rather than a
      # side effect of adding the column.
      public? false

      description """
      Monotonic counter bumped on every identity transition, so in-flight work can
      pin it at resolution time and detect that its identity decision went stale.
      Deliberately absent from every accept list: it moves only through
      :bump_identity_revision.
      """
    end

    # OCSF Nested Objects (JSONB)
    attribute :os, :map do
      default %{}
      public? true

      description "Operating system info (OCSF OS object), including passive_fingerprint evidence"
    end

    attribute :hw_info, :map do
      default %{}
      public? true
      description "Hardware info (OCSF Hardware Info object)"
    end

    attribute :network_interfaces, {:array, :map} do
      default []
      public? true
      description "Network interfaces (OCSF Network Interface objects)"
    end

    attribute :owner, :map do
      default %{}
      public? true
      description "Device owner (OCSF User object)"
    end

    attribute :org, :map do
      default %{}
      public? true
      description "Organization (OCSF Organization object)"
    end

    attribute :groups, {:array, :map} do
      default []
      public? true
      description "Device groups (OCSF Group objects)"
    end

    attribute :agent_list, {:array, :map} do
      default []
      public? true
      description "Associated agents (OCSF Agent objects)"
    end

    # ServiceRadar-specific fields
    attribute :gateway_id, :string do
      public? true
      description "Gateway that discovered this device"
    end

    attribute :agent_id, :string do
      public? true
      description "Agent reporting this device"
    end

    attribute :management_device_id, :string do
      public? true

      description "UID of the device used to reach this device for management (e.g. SNMP polling)"
    end

    attribute :discovery_sources, {:array, :string} do
      default []
      public? true
      description "List of discovery source types"
    end

    attribute :deleted_at, :utc_datetime_usec do
      public? true
      description "Soft delete tombstone timestamp"
    end

    attribute :deleted_by, :string do
      public? true
      description "Actor identifier that deleted the device"
    end

    attribute :deleted_reason, :string do
      public? true
      description "Optional reason for device deletion"
    end

    attribute :tags, :map do
      default %{}
      public? true
      description "User-defined tags (key/value map)"
    end

    attribute :is_available, :boolean do
      default true
      public? true
      description "Current availability status"
    end

    attribute :availability_source_agent_id, :string do
      public? true

      description "Agent whose sweep results drive canonical device availability. Required for All-agents sweep groups; nil lets an assigned group's scanner write the bit."
    end

    attribute :availability_source_profile_id, :uuid do
      public? true

      description "Availability source profile that assigned the canonical source; nil means manual override or legacy fallback"
    end

    attribute :metadata, :map do
      default %{}
      public? true
      description "Additional metadata, including protocol-specific passive_fingerprint evidence"
    end

    # Group assignment
    attribute :group_id, :uuid do
      public? true
      description "Device group this device belongs to"
    end
  end

  relationships do
    has_many :interfaces, ServiceRadar.Inventory.Interface do
      source_attribute :uid
      destination_attribute :device_id
      public? true
      description "Network interfaces discovered on this device"
    end

    has_many :identifiers, ServiceRadar.Inventory.DeviceIdentifier do
      source_attribute :uid
      destination_attribute :device_id
      public? true
      description "Device identifiers for identity reconciliation"
    end

    has_many :agent_availability, ServiceRadar.Inventory.DeviceAgentAvailability do
      source_attribute :uid
      destination_attribute :device_uid
      public? true
      description "Latest availability reported by each agent for this device"
    end

    has_many :snmp_facts, ServiceRadar.Inventory.DeviceSNMPFact do
      source_attribute :uid
      destination_attribute :device_uid
    end

    has_many :risk_contributions, ServiceRadar.Inventory.DeviceRiskContribution do
      source_attribute :uid
      destination_attribute :device_uid
      public? true
      description "Source-specific risk contributions used to derive inventory-visible risk"
    end

    has_many :bumblebee_postures, ServiceRadar.Inventory.BumblebeeDevicePosture do
      source_attribute :uid
      destination_attribute :device_uid
      public? true

      description "Bumblebee developer endpoint exposure posture for agents associated with this device"
    end

    has_many :bumblebee_findings, ServiceRadar.Inventory.BumblebeeFinding do
      source_attribute :uid
      destination_attribute :device_uid
      public? true
      description "Bumblebee exposure findings associated with this device"
    end

    has_many :endpoint_inventory_packages, ServiceRadar.Inventory.EndpointInventoryPackage do
      source_attribute :uid
      destination_attribute :device_uid
      public? true
      description "Current and historical endpoint software package rows linked to this device"
    end

    belongs_to :availability_source_profile, ServiceRadar.Inventory.AvailabilitySourceProfile do
      source_attribute :availability_source_profile_id
      destination_attribute :id
      define_attribute? false
      allow_nil? true
      public? true
      description "Profile that assigned the canonical availability source"
    end

    belongs_to :group, ServiceRadar.Inventory.DeviceGroup do
      source_attribute :group_id
      destination_attribute :id
      define_attribute? false
      allow_nil? true
      public? true
      description "Device group this device belongs to"
    end
  end

  calculations do
    calculate :type_name,
              :string,
              expr(
                cond do
                  not is_nil(type) -> type
                  type_id == 0 -> "Unknown"
                  type_id == 1 -> "Server"
                  type_id == 2 -> "Desktop"
                  type_id == 3 -> "Laptop"
                  type_id == 4 -> "Tablet"
                  type_id == 5 -> "Mobile"
                  type_id == 6 -> "Virtual"
                  type_id == 7 -> "IOT"
                  type_id == 8 -> "Browser"
                  type_id == 9 -> "Firewall"
                  type_id == 10 -> "Switch"
                  type_id == 11 -> "Hub"
                  type_id == 12 -> "Router"
                  type_id == 13 -> "IDS"
                  type_id == 14 -> "IPS"
                  type_id == 15 -> "Load Balancer"
                  type_id == 99 -> "Other"
                  true -> "Unknown"
                end
              )

    calculate :display_name,
              :string,
              expr(
                cond do
                  not is_nil(name) -> name
                  not is_nil(hostname) -> hostname
                  not is_nil(ip) -> ip
                  true -> uid
                end
              )

    calculate :is_stale,
              :boolean,
              expr(is_nil(last_seen_time) or last_seen_time < ago(24, :hour))

    calculate :status_color,
              :string,
              expr(
                cond do
                  is_available == true and last_seen_time > ago(5, :minute) -> "green"
                  is_available == true and last_seen_time > ago(1, :hour) -> "yellow"
                  true -> "red"
                end
              )
  end

  defp actor_identifier(nil), do: nil

  defp actor_identifier(actor) when is_map(actor) do
    Map.get(actor, :id) ||
      Map.get(actor, "id") ||
      Map.get(actor, :email) ||
      Map.get(actor, "email")
  end

  defp actor_identifier(_actor), do: nil

  identities do
    identity :unique_uid, [:uid]
    # MAC uniqueness is optional - skipping unique index
    # identity :unique_mac, [:mac], where: expr(not is_nil(mac))
  end
end
