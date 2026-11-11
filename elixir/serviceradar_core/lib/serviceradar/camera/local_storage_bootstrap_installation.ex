defmodule ServiceRadar.Camera.LocalStorageBootstrapInstallation do
  @moduledoc """
  Immutable acknowledgement of a provisioner's new-volume installation report.

  The storage-scoped provisioner calls `confirm/3` only after the offline NVR
  installer has synced the exact preparation and storage marker. Core correlates
  the reported digest with its immutable preparation and retains the first
  acknowledgement and issuing provenance. Retries return the same bytes.

  The digest is correlation, not proof of a filesystem write. The authenticated
  provisioner owns exclusive attachment, writer retirement and observing the
  installer's success. A recorder cannot self-attest installation. This record
  alone is not a reconciled history checkpoint: the volume must durably retain
  the acknowledgement under the separate completion protocol. It grants no
  capture, qualification, copy registration, playback or deletion authority.
  """
  use Ash.Resource,
    domain: ServiceRadar.Camera,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ash.Expr

  alias ServiceRadar.Camera.ArchiveCanonicalJSON
  alias ServiceRadar.Camera.LocalStorageBootstrapPreparation

  postgres do
    table "camera_local_storage_bootstrap_installations"
    schema "platform"
    repo ServiceRadar.Repo

    identity_index_names storage_lifetime: "camera_local_storage_installation_storage_index"

    references do
      reference :preparation,
        on_delete: :restrict,
        name: "camera_local_storage_installation_preparation_fkey"
    end

    check_constraints do
      check_constraint :record, "camera_local_storage_installation_bounds",
        check: "octet_length(record) BETWEEN 1 AND 512 AND record_sha256 ~ '^[0-9a-f]{64}$'"
    end
  end

  code_interface do
    define :confirm, args: [:preparation_id, :preparation_sha256]
  end

  actions do
    defaults [:read]

    create :confirm do
      accept []
      argument :preparation_id, :uuid, allow_nil?: false

      argument :preparation_sha256, :string,
        allow_nil?: false,
        constraints: [match: ~r/\A[0-9a-f]{64}\z/]

      upsert? true
      upsert_identity :storage_lifetime
      upsert_fields []

      change fn changeset, context ->
        actor = context.actor || %{}

        changeset
        |> Ash.Changeset.force_change_attribute(:storage_id, Map.get(actor, :nvr_storage_id))
        |> Ash.Changeset.force_change_attribute(:confirmed_by, Map.get(actor, :id))
        |> Ash.Changeset.before_action(&confirm_preparation(&1, actor))
      end
    end
  end

  policies do
    policy action_type(:create) do
      authorize_if ServiceRadar.Camera.Checks.ProvisioningLocalStorage
    end

    policy action_type(:read) do
      forbid_unless actor_attribute_equals(:role, :system)
      forbid_unless actor_attribute_equals(:nvr_storage_purpose, :provision)
      authorize_if expr(storage_id == ^actor(:nvr_storage_id))
    end
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false
    attribute :storage_id, :uuid, allow_nil?: false
    attribute :record, :string, allow_nil?: false, constraints: [max_length: 512]

    attribute :record_sha256, :string,
      allow_nil?: false,
      constraints: [match: ~r/\A[0-9a-f]{64}\z/]

    attribute :confirmed_by, :string,
      allow_nil?: false,
      constraints: [min_length: 1, max_length: 128, match: ~r/\A[!-~]+\z/]

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :preparation, LocalStorageBootstrapPreparation,
      source_attribute: :id,
      allow_nil?: false,
      define_attribute?: false
  end

  identities do
    identity :storage_lifetime, [:storage_id]
  end

  defp confirm_preparation(changeset, actor) do
    preparation_id = Ash.Changeset.get_argument(changeset, :preparation_id)
    digest = Ash.Changeset.get_argument(changeset, :preparation_sha256)
    storage_id = Ash.Changeset.get_attribute(changeset, :storage_id)

    case Ash.get(LocalStorageBootstrapPreparation, preparation_id,
           actor: actor,
           not_found_error?: false
         ) do
      {:ok, %{storage_id: ^storage_id, record_sha256: ^digest} = preparation} ->
        record =
          ArchiveCanonicalJSON.encode(%{
            "version" => 1,
            "kind" => "local_storage_bootstrap_installed",
            "operation_id" => preparation.id,
            "storage_id" => storage_id,
            "preparation_sha256" => digest
          })

        Ash.Changeset.force_change_attributes(changeset, %{
          id: preparation.id,
          record: record,
          record_sha256: :sha256 |> :crypto.hash(record) |> Base.encode16(case: :lower)
        })

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)

      {:ok, _} ->
        Ash.Changeset.add_error(changeset,
          field: :preparation_id,
          message: "installation requires the exact scoped bootstrap preparation and digest"
        )
    end
  end
end
