defmodule ServiceRadar.Dashboards.DashboardPackage do
  @moduledoc """
  Browser dashboard package metadata and verification state.

  A package points at a signed WASM renderer and validated JSON manifest. It is
  not assignable to agents.
  """

  use Ash.Resource,
    domain: ServiceRadar.Dashboards,
    data_layer: AshPostgres.DataLayer

  alias ServiceRadar.Dashboards.Validations.Manifest

  @package_fields [
    :dashboard_id,
    :name,
    :version,
    :description,
    :vendor,
    :manifest,
    :renderer,
    :data_frames,
    :capabilities,
    :settings_schema,
    :wasm_object_key,
    :content_hash,
    :signature,
    :source_type,
    :source_repo_url,
    :source_ref,
    :source_manifest_path,
    :source_commit,
    :source_bundle_digest,
    :source_metadata,
    :imported_at,
    :verification_status,
    :verification_error
  ]

  postgres do
    table "dashboard_packages"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false
  end

  actions do
    defaults [:read, :destroy]

    read :by_dashboard_id do
      argument :dashboard_id, :string, allow_nil?: false
      filter expr(dashboard_id == ^arg(:dashboard_id))
    end

    read :enabled do
      filter expr(status == :enabled)
    end

    create :create do
      accept @package_fields
      validate Manifest
    end

    create :upsert do
      accept @package_fields
      upsert? true
      upsert_identity :unique_dashboard_version
      upsert_fields List.delete(@package_fields, :dashboard_id) ++ [:updated_at]
      validate Manifest
    end

    update :update do
      accept @package_fields
      validate Manifest
    end

    update :mark_verified do
      accept [:verification_status, :verification_error, :source_metadata]
      change set_attribute(:verification_status, "verified")
      change set_attribute(:verification_error, nil)
    end

    update :mark_failed do
      accept [:verification_error, :source_metadata]
      change set_attribute(:verification_status, "failed")
    end

    update :enable do
      accept []
      change set_attribute(:status, :enabled)
    end

    update :disable do
      accept []
      change set_attribute(:status, :disabled)
    end

    update :revoke do
      accept [:verification_error]
      change set_attribute(:status, :revoked)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :dashboard_id, :string do
      allow_nil? false
      public? true
      description "Stable dashboard package identifier from the JSON manifest"
    end

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :version, :string do
      allow_nil? false
      public? true
    end

    attribute :description, :string do
      public? true
    end

    attribute :vendor, :string do
      public? true
    end

    attribute :manifest, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :renderer, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :data_frames, {:array, :map} do
      allow_nil? false
      public? true
      default []
    end

    attribute :capabilities, {:array, :string} do
      allow_nil? false
      public? true
      default []
    end

    attribute :settings_schema, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :wasm_object_key, :string do
      public? true
      description "ServiceRadar-managed object key for the dashboard WASM renderer"
    end

    attribute :content_hash, :string do
      public? true
      description "SHA256 of the dashboard WASM artifact or mirrored package payload"
    end

    attribute :signature, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :source_type, :atom do
      allow_nil? false
      public? true
      default :upload
      constraints one_of: [:upload, :git, :first_party]
    end

    attribute :source_repo_url, :string do
      public? true
    end

    attribute :source_ref, :string do
      public? true
    end

    attribute :source_manifest_path, :string do
      public? true
    end

    attribute :source_commit, :string do
      public? true
    end

    attribute :source_bundle_digest, :string do
      public? true
    end

    attribute :source_metadata, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :imported_at, :utc_datetime_usec do
      public? true
    end

    attribute :verification_status, :string do
      public? true
    end

    attribute :verification_error, :string do
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :staged
      constraints one_of: [:staged, :enabled, :disabled, :revoked]
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :instances, ServiceRadar.Dashboards.DashboardInstance do
      destination_attribute :dashboard_package_id
    end
  end

  identities do
    identity :unique_dashboard_version, [:dashboard_id, :version]
  end
end
