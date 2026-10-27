defmodule ServiceRadar.Camera.RecordingBlock do
  @moduledoc """
  Retained capture identity and immutable local descriptor for one recording block.

  Recorder release never deletes this history. Only a live original recorder may
  freeze an open block; unfrozen history cannot be adopted by another recorder or
  uploaded. The independent upload lease carries no archive availability claim.
  """
  use Ash.Resource,
    domain: ServiceRadar.Camera,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ash.Expr

  postgres do
    table "camera_recording_blocks"
    schema "platform"
    repo ServiceRadar.Repo

    references do
      reference :archive_binding, on_delete: :restrict

      reference :archive_manifest_dispatch,
        on_delete: :restrict,
        name: "camera_block_manifest_dispatch_fkey"
    end

    check_constraints do
      check_constraint :archive_manifest_dispatch_id, "camera_block_publication_identity",
        check: """
        (archive_manifest_dispatch_id IS NULL AND archive_manifest_verification_sha256 IS NULL AND
         archive_published_at IS NULL) OR
        (archive_manifest_dispatch_id IS NOT NULL AND archive_manifest_verification_sha256 IS NOT NULL AND
         archive_manifest_verification_sha256 ~ '^[0-9a-f]{64}$' AND archive_published_at IS NOT NULL AND
         archive_binding_id IS NOT NULL AND state IN ('sealed', 'uploading'))
        """

      check_constraint :recorder_epoch, "camera_block_counters_valid",
        check:
          "ingest_epoch > 0 AND recorder_epoch > 0 AND block_sequence >= 0 AND upload_epoch >= 0"

      check_constraint :state, "camera_block_descriptor_present",
        check:
          "(state = 'open_local' AND descriptor IS NULL AND descriptor_sha256 IS NULL) OR (state IN ('sealed', 'uploading') AND descriptor IS NOT NULL AND descriptor_sha256 IS NOT NULL AND length(descriptor_sha256) = 64)"

      check_constraint :state, "camera_block_upload_lease_present",
        check:
          "state <> 'uploading' OR (upload_token IS NOT NULL AND upload_epoch > 0 AND upload_expires_at IS NOT NULL)"
    end
  end

  actions do
    defaults [:read]

    create :reserve do
      accept [
        :block_key,
        :camera_source_id,
        :stream_profile_id,
        :ingest_owner_id,
        :ingest_epoch,
        :recorder_claim_id,
        :recorder_epoch,
        :block_sequence,
        :relay_session_id,
        :media_ingest_id,
        :storage_id,
        :clock
      ]
    end

    update :freeze do
      accept [:descriptor, :descriptor_sha256]
      change set_attribute(:state, :sealed)
    end

    update :claim_upload do
      accept [:upload_token, :upload_epoch, :upload_expires_at]
      change set_attribute(:state, :uploading)
    end

    update :renew_upload do
      accept [:upload_expires_at]
    end

    update :release_upload do
      accept []
      change set_attribute(:state, :sealed)
    end

    update :bind_archive do
      accept [:archive_binding_id]
      validate present(:archive_binding_id)
      validate changing(:archive_binding_id, from: nil)
      validate attribute_equals(:state, :uploading)
    end

    update :publish_archive do
      accept [
        :archive_manifest_dispatch_id,
        :archive_manifest_verification_sha256,
        :archive_published_at
      ]

      validate present([
                 :archive_manifest_dispatch_id,
                 :archive_manifest_verification_sha256,
                 :archive_published_at
               ])

      validate changing(:archive_manifest_dispatch_id, from: nil)
      validate changing(:archive_manifest_verification_sha256, from: nil)
      validate changing(:archive_published_at, from: nil)
      validate attribute_equals(:state, :uploading)
    end
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :block_key, :string,
      allow_nil?: false,
      constraints: [min_length: 64, max_length: 64]

    attribute :camera_source_id, :uuid, allow_nil?: false
    attribute :stream_profile_id, :uuid, allow_nil?: false
    attribute :ingest_owner_id, :uuid, allow_nil?: false
    attribute :ingest_epoch, :integer, allow_nil?: false, constraints: [min: 1]
    attribute :recorder_claim_id, :uuid, allow_nil?: false
    attribute :recorder_epoch, :integer, allow_nil?: false, constraints: [min: 1]
    attribute :block_sequence, :integer, allow_nil?: false, constraints: [min: 0]
    attribute :relay_session_id, :uuid, allow_nil?: false
    attribute :media_ingest_id, :string, allow_nil?: false, constraints: [max_length: 128]
    attribute :storage_id, :uuid, allow_nil?: false
    attribute :archive_binding_id, :uuid
    attribute :archive_manifest_dispatch_id, :uuid

    attribute :archive_manifest_verification_sha256, :string,
      constraints: [match: ~r/\A[0-9a-f]{64}\z/]

    attribute :archive_published_at, :utc_datetime_usec
    attribute :clock, :map, allow_nil?: false
    attribute :descriptor, :map
    attribute :descriptor_sha256, :string, constraints: [min_length: 64, max_length: 64]

    attribute :state, :atom,
      allow_nil?: false,
      default: :open_local,
      constraints: [one_of: [:open_local, :sealed, :uploading]]

    attribute :upload_epoch, :integer, allow_nil?: false, default: 0, constraints: [min: 0]
    attribute :upload_token, :uuid, sensitive?: true
    attribute :upload_expires_at, :utc_datetime_usec
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :archive_manifest_dispatch, ServiceRadar.Camera.ArchiveUploadDispatch,
      define_attribute?: false

    belongs_to :archive_binding, ServiceRadar.Camera.ArchiveBinding, define_attribute?: false

    belongs_to :camera_source, ServiceRadar.Camera.Source,
      allow_nil?: false,
      define_attribute?: false

    belongs_to :stream_profile, ServiceRadar.Camera.StreamProfile,
      allow_nil?: false,
      define_attribute?: false

    belongs_to :ingest_owner, ServiceRadar.Camera.IngestOwner,
      allow_nil?: false,
      define_attribute?: false

    belongs_to :recorder_claim, ServiceRadar.Camera.RecorderClaim,
      allow_nil?: false,
      define_attribute?: false

    belongs_to :relay_session, ServiceRadar.Camera.RelaySession,
      allow_nil?: false,
      define_attribute?: false
  end

  calculations do
    calculate :database_now, :utc_datetime_usec, expr(fragment("clock_timestamp()"))
  end

  identities do
    identity :block_key, [:block_key]
    identity :capture, [:camera_source_id, :stream_profile_id, :recorder_epoch, :block_sequence]
  end

  @doc "Capture identity from retained state, never from a recovered file or current claim."
  def identity(block) do
    %{
      "source_id" => block.camera_source_id,
      "profile" => block.stream_profile_id,
      "recorder_epoch" => block.recorder_epoch,
      "block_sequence" => block.block_sequence,
      "clock" => block.clock
    }
  end
end
