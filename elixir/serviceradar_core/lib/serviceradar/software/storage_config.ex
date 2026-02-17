defmodule ServiceRadar.Software.StorageConfig do
  @moduledoc """
  Storage configuration for the software library.

  Supports dual credential modes:
  - ENV-based: S3 credentials from environment variables (never touches DB)
  - Database: S3 credentials encrypted with AshCloak (AES-256-GCM via ServiceRadar.Vault)

  Credential resolution order: ENV vars → DB-stored → disabled.

  AshCloak automatically renames `s3_access_key_id` → `encrypted_s3_access_key_id` in the DB
  and adds a calculation to decrypt it on load.
  """

  use Ash.Resource,
    domain: ServiceRadar.Software,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshCloak]

  postgres do
    table "software_storage_configs"
    repo ServiceRadar.Repo
    schema "platform"
  end

  cloak do
    vault(ServiceRadar.Vault)
    attributes([:s3_access_key_id, :s3_secret_access_key])
    decrypt_by_default([])
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [
        :storage_mode,
        :s3_bucket,
        :s3_region,
        :s3_endpoint,
        :s3_prefix,
        :local_path,
        :retention_days
      ]
    end

    update :update do
      accept [
        :storage_mode,
        :s3_bucket,
        :s3_region,
        :s3_endpoint,
        :s3_prefix,
        :local_path,
        :retention_days
      ]
    end

    update :set_s3_credentials do
      description "Store S3 credentials encrypted in the database"
      accept []
      require_atomic? false

      argument :s3_access_key_id, :string, allow_nil?: false, sensitive?: true
      argument :s3_secret_access_key, :string, allow_nil?: false, sensitive?: true

      change fn changeset, _context ->
        access_key = Ash.Changeset.get_argument(changeset, :s3_access_key_id)
        secret_key = Ash.Changeset.get_argument(changeset, :s3_secret_access_key)

        changeset
        |> AshCloak.encrypt_and_set(:s3_access_key_id, access_key)
        |> AshCloak.encrypt_and_set(:s3_secret_access_key, secret_key)
      end
    end

    read :get_config do
      description "Get the current storage configuration"
      get? true
      filter expr(true)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :storage_mode, :atom do
      allow_nil? false
      default :local
      public? true
      constraints one_of: [:local, :s3, :both]
      description "Where to store files: local filesystem, S3, or both"
    end

    attribute :s3_bucket, :string do
      allow_nil? true
      public? true
    end

    attribute :s3_region, :string do
      allow_nil? true
      public? true
    end

    attribute :s3_endpoint, :string do
      allow_nil? true
      public? true
      description "Custom S3 endpoint URL (for MinIO, R2, etc.)"
    end

    attribute :s3_prefix, :string do
      allow_nil? true
      public? true
      default "software/"
      description "Key prefix for S3 objects"
    end

    # These will be transformed by AshCloak into encrypted_s3_access_key_id
    # and encrypted_s3_secret_access_key (binary), with calculation accessors.
    attribute :s3_access_key_id, :string do
      allow_nil? true
      public? false
      sensitive? true
      description "S3 access key ID (encrypted at rest via AshCloak)"
    end

    attribute :s3_secret_access_key, :string do
      allow_nil? true
      public? false
      sensitive? true
      description "S3 secret access key (encrypted at rest via AshCloak)"
    end

    attribute :local_path, :string do
      allow_nil? true
      public? true
      default "/var/lib/serviceradar/software"
      description "Local filesystem storage path"
    end

    attribute :retention_days, :integer do
      allow_nil? true
      public? true
      default 90
      description "Days to retain backup files before cleanup"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  policies do
    bypass always() do
      authorize_if actor_attribute_equals(:role, :system)
    end

    policy action_type(:read) do
      authorize_if {ServiceRadar.Policies.Checks.ActorHasPermission,
                    permission: "settings.software.view"}
      authorize_if {ServiceRadar.Policies.Checks.ActorHasPermission,
                    permission: "settings.software.manage"}
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if {ServiceRadar.Policies.Checks.ActorHasPermission,
                    permission: "settings.software.manage"}
    end
  end
end
