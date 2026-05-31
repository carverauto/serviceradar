defmodule ServiceRadar.Inventory.VisibilityProfile do
  @moduledoc """
  Admin-managed profiles for host network visibility configuration.

  Visibility profiles scope passive fingerprinting and later network visibility
  capabilities to devices via SRQL targeting.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    notifiers: [ServiceRadar.AgentConfig.DependencyNotifier],
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission
  alias ServiceRadar.SysmonProfiles.Changes.ValidateSrqlQuery

  @visibility_read_check {ActorHasPermission, permission: "visibility_profiles:read"}
  @visibility_write_check {ActorHasPermission, permission: "visibility_profiles:write"}
  @visibility_delete_check {ActorHasPermission, permission: "visibility_profiles:delete"}

  @profile_fields [
    :name,
    :description,
    :enabled,
    :target_query,
    :priority,
    :capture_interfaces,
    :fingerprint,
    :dpi,
    :flow_attribution,
    :process_snapshot_interval_s,
    :sample_interval_ms,
    :retention_days,
    :partition_id
  ]

  postgres do
    table "visibility_profiles"
    repo ServiceRadar.Repo
    schema "platform"
  end

  paper_trail do
    primary_key_type :uuid
    table_name "visibility_profile_versions"
    mixin {ServiceRadar.Inventory.VisibilityProfile.PaperTrailMixin, :mixin, []}
    change_tracking_mode :full_diff
    attributes_as_attributes [:partition_id]
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? true
    ignore_attributes [:inserted_at, :updated_at]
  end

  actions do
    defaults [:read]

    create :create do
      accept @profile_fields

      change &validate_capture_interfaces/2
      change ValidateSrqlQuery
    end

    update :update do
      accept @profile_fields

      require_atomic? false
      change &validate_capture_interfaces/2
      change ValidateSrqlQuery
    end

    destroy :destroy do
      require_atomic? false
    end

    read :list_available do
      description "List enabled visibility profiles"
      filter expr(enabled == true)
    end

    read :by_name do
      description "Get a visibility profile by partition and name"

      argument :partition_id, :string do
        allow_nil? false
      end

      argument :name, :string do
        allow_nil? false
      end

      get? true
      filter expr(partition_id == ^arg(:partition_id) and name == ^arg(:name))
    end

    read :list_targeting_profiles do
      description "List enabled profiles ordered by targeting priority"
      filter expr(enabled == true)

      prepare fn query, _context ->
        Ash.Query.sort(query, priority: :desc)
      end
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_with_permission(@visibility_read_check)
    action_type_with_permission([:create, :update], @visibility_write_check)
    action_type_with_permission(:destroy, @visibility_delete_check)
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      description "Human-readable profile name"
    end

    attribute :description, :string do
      allow_nil? true
      public? true
      description "Optional description of the profile's purpose"
    end

    attribute :enabled, :boolean do
      allow_nil? false
      public? true
      default true
      description "Whether this profile can be compiled for agents"
    end

    attribute :target_query, :string do
      allow_nil? true
      public? true
      description "SRQL query for device targeting"
    end

    attribute :priority, :integer do
      allow_nil? false
      public? true
      default 0
      description "Profile resolution priority; higher values win"
    end

    attribute :fingerprint, :map do
      allow_nil? false
      public? true
      default %{"tcp" => true, "tls" => true, "http" => true}
      description "Passive fingerprint toggles keyed by protocol"
    end

    attribute :capture_interfaces, {:array, :string} do
      allow_nil? false
      public? true
      default []
      description "Host network interfaces explicitly allowlisted for passive capture"
    end

    attribute :dpi, :map do
      allow_nil? true
      public? true
      description "DPI protocol configuration; payloads, URIs, and DNS names are never captured"
    end

    attribute :flow_attribution, :map do
      allow_nil? true
      public? true
      description "Flow attribution protocol toggles keyed by transport"
    end

    attribute :process_snapshot_interval_s, :integer do
      allow_nil? true
      public? true
      constraints min: 0
      description "Process listener snapshot interval in seconds; 0 disables snapshots"
    end

    attribute :sample_interval_ms, :integer do
      allow_nil? false
      public? true
      default 60_000
      constraints min: 0
      description "Minimum sample interval per IP/protocol pair; 0 disables rate limiting"
    end

    attribute :retention_days, :integer do
      allow_nil? false
      public? true
      default 30
      constraints min: 1
      description "Retention period for visibility observations"
    end

    attribute :partition_id, :string do
      allow_nil? false
      public? true
      default "default"
      description "Deployment partition identifier"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_partition_name, [:partition_id, :name]
  end

  defp validate_capture_interfaces(changeset, _context) do
    enabled? = Ash.Changeset.get_attribute(changeset, :enabled)

    interfaces =
      changeset
      |> Ash.Changeset.get_attribute(:capture_interfaces)
      |> List.wrap()
      |> Enum.map(&String.trim(to_string(&1)))
      |> Enum.reject(&(&1 == ""))

    cond do
      enabled? == true and interfaces == [] ->
        Ash.Changeset.add_error(changeset,
          field: :capture_interfaces,
          message: "must include at least one allowlisted interface when enabled"
        )

      Enum.any?(interfaces, &(&1 == "any" or String.contains?(&1, "*"))) ->
        Ash.Changeset.add_error(changeset,
          field: :capture_interfaces,
          message: "cannot include 'any' or wildcard interfaces"
        )

      true ->
        Ash.Changeset.change_attribute(changeset, :capture_interfaces, Enum.uniq(interfaces))
    end
  end
end
