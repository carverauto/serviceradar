defmodule ServiceRadar.Camera.ArchiveUploadDispatch do
  @moduledoc """
  Durable dispatch identity and observations for one immutable archive upload intent.

  The actions are trusted persistence primitives. `ArchiveUploads` checks the
  trusted internal actor, fences the lease and supplies database-clock timestamps.
  Identity cannot be changed, and marking or observing a dispatch never rearms it.
  """
  use Ash.Resource,
    domain: ServiceRadar.Camera,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ash.Expr

  @grant_fields [
    :init_authority_revision,
    :init_authority_sha256,
    :init_storage_boot_id,
    :init_nonce_sha256,
    :init_principal_sha256,
    :init_deadline_at
  ]

  postgres do
    table "camera_archive_upload_dispatches"
    schema "platform"
    repo ServiceRadar.Repo

    references do
      reference :archive_upload_intent, on_delete: :restrict
    end

    check_constraints do
      check_constraint :init_authority_revision, "camera_upload_init_grant_bounds",
        check: """
        (init_authority_revision IS NULL AND init_authority_sha256 IS NULL AND
         init_storage_boot_id IS NULL AND init_nonce_sha256 IS NULL AND
         init_principal_sha256 IS NULL AND init_deadline_at IS NULL) OR
        (init_authority_revision IS NOT NULL AND init_authority_revision > 0 AND
         init_authority_sha256 IS NOT NULL AND init_authority_sha256 ~ '^[0-9a-f]{64}$' AND
         init_storage_boot_id IS NOT NULL AND init_nonce_sha256 IS NOT NULL AND
         init_nonce_sha256 ~ '^[0-9a-f]{64}$' AND init_principal_sha256 IS NOT NULL AND
         init_principal_sha256 ~ '^[0-9a-f]{64}$' AND init_deadline_at IS NOT NULL AND
         marked_at IS NOT NULL AND operation = 'put_object' AND
         init_deadline_at > marked_at AND init_deadline_at <= marked_at + interval '5 seconds' AND
         init_deadline_at <= deadline_at)
        """

      check_constraint :init_verification, "camera_upload_init_verification_bounds",
        check: """
        (init_verification IS NULL AND init_verification_sha256 IS NULL AND init_verified_at IS NULL) OR
        (init_verification IS NOT NULL AND init_verification_sha256 IS NOT NULL AND init_verified_at IS NOT NULL AND
         init_authority_revision IS NOT NULL AND jsonb_typeof(init_verification) = 'object' AND
         octet_length(init_verification::text) <= 4096 AND init_verification_sha256 ~ '^[0-9a-f]{64}$')
        """

      check_constraint :init_verification_conflict_at, "camera_upload_init_verification_conflict",
        check: """
        (init_verification_conflict_at IS NULL AND init_verification_conflict_sha256 IS NULL) OR
        (init_verification_conflict_at IS NOT NULL AND init_verification_conflict_sha256 IS NOT NULL AND
         init_verified_at IS NOT NULL AND init_verification_conflict_sha256 ~ '^[0-9a-f]{64}$')
        """

      check_constraint :upload_epoch, "camera_upload_dispatch_identity_bounds",
        check: """
        schema_version = 1 AND upload_epoch > 0 AND
        upload_token_sha256 ~ '^[0-9a-f]{64}$' AND
        request_sha256 ~ '^[0-9a-f]{64}$' AND
        char_length(dispatcher_actor_id) BETWEEN 1 AND 128 AND
        operation IN ('put_object', 'create_multipart_upload')
        """

      check_constraint :deadline_at, "camera_upload_dispatch_window_bounds",
        check: """
        deadline_at > prepared_at AND
        deadline_at <= prepared_at + interval '5 minutes' AND
        (marked_at IS NULL OR (marked_at >= prepared_at AND marked_at < deadline_at))
        """

      check_constraint :unknown_at, "camera_upload_dispatch_marker_required",
        check: """
        (unknown_at IS NULL OR marked_at IS NOT NULL) AND
        (response_at IS NULL OR marked_at IS NOT NULL)
        """

      check_constraint :response, "camera_upload_dispatch_response_bounds",
        check: """
        (response IS NULL AND response_sha256 IS NULL AND response_at IS NULL) OR
        (response IS NOT NULL AND response_sha256 IS NOT NULL AND response_at IS NOT NULL AND
         response_sha256 ~ '^[0-9a-f]{64}$' AND jsonb_typeof(response) = 'object' AND
         octet_length(response::text) <= 8192)
        """

      check_constraint :conflict_at, "camera_upload_dispatch_conflict_requires_response",
        check: """
        (conflict_at IS NULL AND first_conflict_sha256 IS NULL) OR
        (conflict_at IS NOT NULL AND first_conflict_sha256 IS NOT NULL AND
         response_at IS NOT NULL AND first_conflict_sha256 ~ '^[0-9a-f]{64}$')
        """
    end
  end

  actions do
    defaults [:read]

    create :prepare do
      accept [
        :archive_upload_intent_id,
        :upload_epoch,
        :upload_token_sha256,
        :dispatcher_actor_id,
        :operation,
        :request_sha256,
        :prepared_at,
        :deadline_at
      ]
    end

    update :grant_init do
      accept [:marked_at] ++ @grant_fields
      validate present([:marked_at] ++ @grant_fields)
      validate changing(:marked_at, from: nil)

      for field <- @grant_fields do
        validate changing(field, from: nil)
      end
    end

    update :verify_init do
      accept [:init_verification, :init_verification_sha256, :init_verified_at]
      validate present([:init_verification, :init_verification_sha256, :init_verified_at])
      validate changing(:init_verified_at, from: nil)
    end

    update :conflict_init_verification do
      accept [:init_verification_conflict_at, :init_verification_conflict_sha256]
      validate present([:init_verification_conflict_at, :init_verification_conflict_sha256])
      validate changing(:init_verification_conflict_at, from: nil)
    end

    update :mark do
      accept [:marked_at]
      validate present(:marked_at)
      validate changing(:marked_at, from: nil)
    end

    update :observe_unknown do
      accept [:unknown_at]
      validate present(:unknown_at)
      validate changing(:unknown_at, from: nil)
    end

    update :observe_response do
      accept [:response, :response_sha256, :response_at]
      validate present([:response, :response_sha256, :response_at])
      validate changing(:response, from: nil)
      validate changing(:response_sha256, from: nil)
      validate changing(:response_at, from: nil)
    end

    update :record_conflict do
      accept [:conflict_at, :first_conflict_sha256]
      validate present([:conflict_at, :first_conflict_sha256])
      validate changing(:conflict_at, from: nil)
      validate changing(:first_conflict_sha256, from: nil)
    end
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :schema_version, :integer,
      allow_nil?: false,
      default: 1,
      constraints: [min: 1, max: 1]

    attribute :archive_upload_intent_id, :uuid, allow_nil?: false
    attribute :upload_epoch, :integer, allow_nil?: false, constraints: [min: 1]

    attribute :upload_token_sha256, :string,
      allow_nil?: false,
      sensitive?: true,
      constraints: [match: ~r/\A[0-9a-f]{64}\z/]

    attribute :dispatcher_actor_id, :string,
      allow_nil?: false,
      constraints: [min_length: 1, max_length: 128]

    attribute :operation, :atom,
      allow_nil?: false,
      constraints: [one_of: [:put_object, :create_multipart_upload]]

    attribute :request_sha256, :string,
      allow_nil?: false,
      constraints: [match: ~r/\A[0-9a-f]{64}\z/]

    attribute :prepared_at, :utc_datetime_usec, allow_nil?: false
    attribute :deadline_at, :utc_datetime_usec, allow_nil?: false
    attribute :init_authority_revision, :integer, constraints: [min: 1]
    attribute :init_authority_sha256, :string, constraints: [match: ~r/\A[0-9a-f]{64}\z/]
    attribute :init_storage_boot_id, :uuid
    attribute :init_nonce_sha256, :string, constraints: [match: ~r/\A[0-9a-f]{64}\z/]
    attribute :init_principal_sha256, :string, constraints: [match: ~r/\A[0-9a-f]{64}\z/]
    attribute :init_deadline_at, :utc_datetime_usec
    attribute :init_verification, :map
    attribute :init_verification_sha256, :string, constraints: [match: ~r/\A[0-9a-f]{64}\z/]
    attribute :init_verified_at, :utc_datetime_usec
    attribute :init_verification_conflict_at, :utc_datetime_usec

    attribute :init_verification_conflict_sha256, :string,
      constraints: [match: ~r/\A[0-9a-f]{64}\z/]

    attribute :marked_at, :utc_datetime_usec
    attribute :unknown_at, :utc_datetime_usec
    attribute :response_at, :utc_datetime_usec
    attribute :response, :map
    attribute :response_sha256, :string, constraints: [match: ~r/\A[0-9a-f]{64}\z/]
    attribute :conflict_at, :utc_datetime_usec
    attribute :first_conflict_sha256, :string, constraints: [match: ~r/\A[0-9a-f]{64}\z/]
  end

  relationships do
    belongs_to :archive_upload_intent, ServiceRadar.Camera.ArchiveUploadIntent,
      allow_nil?: false,
      define_attribute?: false
  end

  calculations do
    calculate :database_now, :utc_datetime_usec, expr(fragment("clock_timestamp()"))
  end

  identities do
    identity :intent, [:archive_upload_intent_id]
    identity :init_request_nonce, [:init_storage_boot_id, :init_nonce_sha256]
  end
end
