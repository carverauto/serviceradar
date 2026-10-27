defmodule ServiceRadar.Camera.ArchiveManifestAuthority do
  @moduledoc "One retained, nonrenewable manifest-authority revision per immutable binding."
  use Ash.Resource,
    domain: ServiceRadar.Camera,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ash.Expr

  @origin [:deployment_ref, :generation, :revision, :desired_sha256]
  @challenge [
    :storage_service_id,
    :credential_reference,
    :credential_generation,
    :principal_sha256,
    :storage_boot_id,
    :nonce,
    :issued_at,
    :expires_at
  ]

  postgres do
    table "camera_archive_manifest_authorities"
    schema "platform"
    repo ServiceRadar.Repo

    references do
      reference :archive_binding, on_delete: :restrict
    end

    check_constraints do
      check_constraint :revision, "camera_manifest_authority_identity",
        check: "generation > 0 AND revision > 0 AND desired_sha256 ~ '^[0-9a-f]{64}$'"

      check_constraint :state, "camera_manifest_authority_state",
        check: """
        (state = 'revoked' AND desired_document IS NULL AND report_sha256 IS NULL AND
         applied_at IS NULL AND issued_at IS NULL AND expires_at IS NULL AND
         storage_service_id IS NULL AND credential_reference IS NULL AND credential_generation IS NULL AND
         principal_sha256 IS NULL AND storage_boot_id IS NULL AND nonce IS NULL) OR
        (state IN ('pending', 'applied') AND storage_service_id IS NOT NULL AND
         char_length(storage_service_id) BETWEEN 1 AND 256 AND credential_reference IS NOT NULL AND
         char_length(credential_reference) BETWEEN 1 AND 256 AND credential_generation IS NOT NULL AND credential_generation > 0 AND
         principal_sha256 IS NOT NULL AND principal_sha256 ~ '^[0-9a-f]{64}$' AND
         storage_boot_id IS NOT NULL AND nonce IS NOT NULL AND nonce ~ '^[0-9a-f]{64}$' AND
         issued_at IS NOT NULL AND expires_at IS NOT NULL AND expires_at > issued_at AND
         expires_at <= issued_at + interval '30 seconds' AND
         ((state = 'pending' AND desired_document IS NULL AND report_sha256 IS NULL AND applied_at IS NULL) OR
          (state = 'applied' AND desired_document IS NOT NULL AND jsonb_typeof(desired_document) = 'object' AND
           octet_length(desired_document::text) <= 16384 AND report_sha256 IS NOT NULL AND
           report_sha256 ~ '^[0-9a-f]{64}$' AND applied_at IS NOT NULL AND
           applied_at >= issued_at AND applied_at < expires_at)))
        """
    end
  end

  actions do
    defaults [:read]

    create :initial_challenge do
      accept [:archive_binding_id] ++ @origin ++ @challenge
      change set_attribute(:state, :pending)
    end

    update :challenge do
      accept @origin ++ @challenge
      change set_attribute(:state, :pending)
      change set_attribute(:desired_document, nil)
      change set_attribute(:report_sha256, nil)
      change set_attribute(:applied_at, nil)
    end

    update :apply do
      accept [:desired_document, :report_sha256, :applied_at, :expires_at]
      change set_attribute(:state, :applied)
    end

    create :initial_revoke do
      accept [:archive_binding_id] ++ @origin
      change set_attribute(:state, :revoked)
    end

    update :revoke do
      accept @origin
      change set_attribute(:state, :revoked)

      for field <- @challenge ++ [:desired_document, :report_sha256, :applied_at] do
        change set_attribute(field, nil)
      end
    end
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    attribute :archive_binding_id, :uuid, primary_key?: true, allow_nil?: false
    attribute :deployment_ref, :uuid, allow_nil?: false
    attribute :generation, :integer, allow_nil?: false, constraints: [min: 1]
    attribute :revision, :integer, allow_nil?: false, constraints: [min: 1]

    attribute :desired_sha256, :string,
      allow_nil?: false,
      constraints: [match: ~r/\A[0-9a-f]{64}\z/]

    attribute :state, :atom,
      allow_nil?: false,
      constraints: [one_of: [:pending, :applied, :revoked]]

    attribute :desired_document, :map
    attribute :report_sha256, :string, constraints: [match: ~r/\A[0-9a-f]{64}\z/]
    attribute :storage_service_id, :string, constraints: [min_length: 1, max_length: 256]
    attribute :credential_reference, :string, constraints: [min_length: 1, max_length: 256]
    attribute :credential_generation, :integer, constraints: [min: 1]
    attribute :principal_sha256, :string, constraints: [match: ~r/\A[0-9a-f]{64}\z/]
    attribute :storage_boot_id, :uuid
    attribute :nonce, :string, sensitive?: true, constraints: [match: ~r/\A[0-9a-f]{64}\z/]
    attribute :issued_at, :utc_datetime_usec
    attribute :expires_at, :utc_datetime_usec
    attribute :applied_at, :utc_datetime_usec
  end

  relationships do
    belongs_to :archive_binding, ServiceRadar.Camera.ArchiveBinding,
      allow_nil?: false,
      define_attribute?: false
  end

  calculations do
    calculate :database_now, :utc_datetime_usec, expr(fragment("clock_timestamp()"))
  end
end
