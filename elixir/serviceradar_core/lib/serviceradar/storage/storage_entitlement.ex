defmodule ServiceRadar.Storage.StorageEntitlement do
  @moduledoc """
  Deployment singleton (`id = "deployment"`) storing the applied SaaS storage
  entitlement document (`platform.storage_entitlements`, `F.3`, `design.md` `F1`).

  Written exclusively through `ServiceRadar.Storage.StorageEntitlements` on the
  authenticated private `:entitlements` control-plane listener, with changes
  recorded in `platform.storage_entitlement_versions` (`AshPaperTrail`) and
  surfaced in `ServiceRadar.Security.AuditHistory`.

  Self-hosted installations have no entitlement row and are unaffected by this
  resource (`design.md:2510-2512`).
  """

  use Ash.Resource,
    domain: ServiceRadar.Camera,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  import Ash.Expr

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @singleton_id "deployment"
  @hex64 ~r/\A[0-9a-f]{64}\z/

  @view_check {ActorHasPermission, permission: "settings.recording.view"}
  @manage_check {ActorHasPermission, permission: "settings.recording.manage"}
  @operate_check {ActorHasPermission, permission: "settings.recording.operate"}
  @audit_view_check {ActorHasPermission, permission: "settings.audit.view"}

  @writable_fields [
    :schema_version,
    :deployment_ref,
    :generation,
    :revision,
    :document_sha256,
    :issued_at,
    :applied_at,
    :recordings_present,
    :recordings_enabled,
    :recordings_allocation_bytes,
    :recordings_overage_mode,
    :recordings_overage_cap_bytes,
    :recordings_capacity_policy,
    :recordings_retention_max_days,
    :recordings_retention_default_days,
    :recordings_max_cameras,
    :recordings_visual_indexing_enabled,
    :recordings_max_visual_index_cameras,
    :recordings_pending,
    :warehouse_present,
    :warehouse_enabled,
    :warehouse_consumer
  ]

  postgres do
    table "storage_entitlements"
    schema "platform"
    repo ServiceRadar.Repo

    custom_statements do
      statement :network_credential_secrets_cloud_managed_columns do
        up """
        ALTER TABLE platform.network_credential_secrets
          ADD COLUMN IF NOT EXISTS managed_by text NOT NULL DEFAULT 'operator',
          ADD COLUMN IF NOT EXISTS credential_generation bigint;
        """

        down """
        ALTER TABLE platform.network_credential_secrets
          DROP COLUMN IF EXISTS credential_generation,
          DROP COLUMN IF EXISTS managed_by;
        """
      end

      statement :network_credential_secrets_cloud_managed_constraint do
        after_tables ["storage_entitlements"]

        up """
        ALTER TABLE platform.network_credential_secrets
          DROP CONSTRAINT IF EXISTS network_credential_secrets_managed_by_valid,
          ADD CONSTRAINT network_credential_secrets_managed_by_valid
            CHECK (
              managed_by IN ('operator', 'control_plane') AND
              (credential_generation IS NULL OR credential_generation > 0)
            );
        """

        down """
        ALTER TABLE platform.network_credential_secrets
          DROP CONSTRAINT IF EXISTS network_credential_secrets_managed_by_valid;
        """
      end

      statement :network_credential_secrets_cloud_managed_index do
        after_tables ["storage_entitlements"]

        up """
        CREATE INDEX IF NOT EXISTS network_credential_secrets_managed_by_idx
          ON platform.network_credential_secrets (managed_by, provider);
        """

        down """
        DROP INDEX IF EXISTS platform.network_credential_secrets_managed_by_idx;
        """
      end
    end

    check_constraints do
      check_constraint :id, "storage_entitlements_singleton", check: "id = 'deployment'"

      check_constraint :revision, "storage_entitlements_valid",
        check: """
        schema_version = 1 AND
        btrim(deployment_ref) <> '' AND octet_length(deployment_ref) <= 128 AND
        generation > 0 AND
        revision > 0 AND
        document_sha256 ~ '^[0-9a-f]{64}$' AND
        recordings_allocation_bytes >= 0 AND
        recordings_overage_mode IN ('off', 'metered') AND
        ((recordings_overage_mode = 'off' AND recordings_overage_cap_bytes IS NULL) OR
         (recordings_overage_mode = 'metered' AND recordings_overage_cap_bytes IS NOT NULL AND recordings_overage_cap_bytes > 0 AND recordings_overage_cap_bytes >= recordings_allocation_bytes)) AND
        recordings_capacity_policy IN ('reap_oldest', 'stop_archiving') AND
        (recordings_retention_max_days IS NULL OR recordings_retention_max_days >= 1) AND
        (recordings_retention_default_days IS NULL OR recordings_retention_default_days >= 1) AND
        (recordings_max_cameras IS NULL OR recordings_max_cameras >= 0) AND
        (recordings_max_visual_index_cameras IS NULL OR recordings_max_visual_index_cameras >= 0)
        """
    end
  end

  paper_trail do
    primary_key_type :uuid_v7
    table_name "storage_entitlement_versions"
    reference_source? false
    mixin {ServiceRadar.Security.PaperTrailMixin, :mixin_with_audit_actor, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? false
    ignore_attributes [:inserted_at, :updated_at]
  end

  code_interface do
    define :get_singleton, action: :get_singleton
  end

  actions do
    defaults [:read]

    read :get_singleton do
      get? true
      filter expr(id == ^@singleton_id)
    end

    create :create_entitlement do
      primary? true
      accept @writable_fields
      change set_attribute(:id, @singleton_id)
    end

    update :apply_entitlement do
      primary? true
      accept @writable_fields
      atomic_upgrade_with :read
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    policy action_type(:read) do
      authorize_if @view_check
      authorize_if @manage_check
      authorize_if @operate_check
      authorize_if @audit_view_check
    end

    policy action_type([:create, :update]) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    attribute :id, :string do
      primary_key? true
      allow_nil? false
      default @singleton_id
      writable? false
      public? true
      constraints match: ~r/\Adeployment\z/
    end

    attribute :schema_version, :integer do
      allow_nil? false
      default 1
      public? true
      constraints min: 1, max: 1
    end

    attribute :deployment_ref, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 128
    end

    attribute :generation, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :revision, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :document_sha256, :string do
      allow_nil? false
      public? true
      constraints min_length: 64, max_length: 64, match: @hex64
    end

    attribute :issued_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :applied_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :recordings_present, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :recordings_enabled, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :recordings_allocation_bytes, :integer do
      allow_nil? false
      default 0
      public? true
      constraints min: 0
    end

    attribute :recordings_overage_mode, :atom do
      allow_nil? false
      default :off
      public? true
      constraints one_of: [:off, :metered]
    end

    attribute :recordings_overage_cap_bytes, :integer do
      allow_nil? true
      default nil
      public? true
      constraints min: 1
    end

    attribute :recordings_capacity_policy, :atom do
      allow_nil? false
      default :reap_oldest
      public? true
      constraints one_of: [:reap_oldest, :stop_archiving]
    end

    attribute :recordings_retention_max_days, :integer do
      allow_nil? true
      default nil
      public? true
      constraints min: 1
    end

    attribute :recordings_retention_default_days, :integer do
      allow_nil? true
      default nil
      public? true
      constraints min: 1
    end

    attribute :recordings_max_cameras, :integer do
      allow_nil? true
      default nil
      public? true
      constraints min: 0
    end

    attribute :recordings_visual_indexing_enabled, :boolean do
      allow_nil? true
      default nil
      public? true
    end

    attribute :recordings_max_visual_index_cameras, :integer do
      allow_nil? true
      default nil
      public? true
      constraints min: 0
    end

    attribute :recordings_pending, :map do
      allow_nil? true
      default nil
      public? true
    end

    attribute :warehouse_present, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :warehouse_enabled, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :warehouse_consumer, :map do
      allow_nil? true
      default nil
      public? true
    end

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at, public?: true
  end

  calculations do
    calculate :database_now, :utc_datetime_usec, expr(fragment("clock_timestamp()"))
  end
end
