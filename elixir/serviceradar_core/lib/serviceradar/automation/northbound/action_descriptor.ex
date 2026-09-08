defmodule ServiceRadar.Automation.Northbound.ActionDescriptor do
  @moduledoc """
  Versioned launch contract for one provider-neutral action.
  """

  use Ash.Resource,
    domain: ServiceRadar.Automation.Northbound,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "northbound.actions.view"}
  @launch_check {ActorHasPermission, permission: "northbound.actions.launch"}
  @manage_check {ActorHasPermission, permission: "northbound.actions.manage"}

  @fields [
    :provider_id,
    :action_id,
    :version,
    :label,
    :description,
    :scopes,
    :required_context,
    :input_schema,
    :safety_classification,
    :requires_confirmation,
    :timeout_seconds,
    :credential_requirements,
    :result_schema_version,
    :descriptor_hash,
    :enabled,
    :metadata
  ]

  @launch_read_fields [:id | @fields]

  postgres do
    table "northbound_action_descriptors"
    repo ServiceRadar.Repo
    schema "platform"

    identity_index_names unique_provider_action_version:
                           "northbound_action_descriptors_provider_action_version_uidx"

    references do
      reference :provider, on_delete: :delete
    end
  end

  paper_trail do
    primary_key_type :uuid_v7
    table_name "northbound_action_descriptor_versions"
    mixin {ServiceRadar.Credentials.PaperTrailMixin, :mixin, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? false
    ignore_attributes [:inserted_at, :updated_at]
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_by_provider, action: :by_provider, args: [:provider_id]
    define :list_enabled_for_scope, action: :enabled_for_scope, args: [:scope]
    define :get_launch_candidate_by_id, action: :launch_candidate_by_id, args: [:id]
    define :list_launchable_for_scope, action: :launchable_for_scope, args: [:scope]
    define :upsert_descriptor, action: :upsert
    define :update_descriptor, action: :update
    define :destroy_descriptor, action: :destroy
  end

  actions do
    defaults [:destroy]

    read :read do
      primary? true
    end

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
      prepare build(load: [:provider], select: [:id, :inserted_at, :updated_at | @fields])
    end

    read :enabled_for_scope do
      argument :scope, :string, allow_nil?: false

      filter expr(enabled == true and fragment("? = ANY(?)", ^arg(:scope), scopes))
      prepare build(load: [:provider], select: [:id, :inserted_at, :updated_at | @fields])
    end

    read :launchable_for_scope do
      argument :scope, :string, allow_nil?: false

      filter expr(enabled == true and fragment("? = ANY(?)", ^arg(:scope), scopes))
      prepare build(select: @launch_read_fields)
    end

    read :launch_candidate_by_id do
      argument :id, :uuid, allow_nil?: false
      get? true

      filter expr(id == ^arg(:id))
      prepare build(select: @launch_read_fields)
    end

    read :by_provider do
      argument :provider_id, :uuid, allow_nil?: false

      filter expr(provider_id == ^arg(:provider_id))
      prepare build(select: [:id, :inserted_at, :updated_at | @fields])
    end

    create :upsert do
      upsert? true
      upsert_identity :unique_provider_action_version
      accept @fields
    end

    update :update do
      accept List.delete(@fields, :provider_id)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    action_with_permission([:read, :by_id, :enabled_for_scope, :by_provider], @view_check)
    action_with_permission([:launchable_for_scope, :launch_candidate_by_id], @launch_check)
    action_type_with_permission([:create, :update, :destroy], @manage_check)
  end

  validations do
    validate present(:scopes)
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :provider_id, :uuid, allow_nil?: false, public?: true
    attribute :action_id, :string, allow_nil?: false, public?: true
    attribute :version, :string, allow_nil?: false, public?: true, default: "1.0.0"
    attribute :label, :string, allow_nil?: false, public?: true
    attribute :description, :string, allow_nil?: true, public?: true

    attribute :scopes, {:array, :string} do
      allow_nil? false
      public? true
      default []
      constraints min_length: 1
    end

    attribute :required_context, {:array, :string} do
      allow_nil? false
      public? true
      default []
    end

    attribute :input_schema, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :safety_classification, :atom do
      allow_nil? false
      public? true
      default :standard
      constraints one_of: [:read_only, :standard, :destructive]
    end

    attribute :requires_confirmation, :boolean do
      allow_nil? false
      public? true
      default false
    end

    attribute :timeout_seconds, :integer do
      allow_nil? false
      public? true
      default 60
      constraints min: 1, max: 3600
    end

    attribute :credential_requirements, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :result_schema_version, :string do
      allow_nil? false
      public? true
      default "serviceradar.northbound_action_result.v1"
    end

    attribute :descriptor_hash, :string, allow_nil?: true, public?: true

    attribute :enabled, :boolean do
      allow_nil? false
      public? true
      default true
    end

    attribute :metadata, :map do
      allow_nil? false
      public? true
      default %{}
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :provider, ServiceRadar.Automation.Northbound.ActionProvider do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :provider_id
    end
  end

  identities do
    identity :unique_provider_action_version, [:provider_id, :action_id, :version]
  end
end
