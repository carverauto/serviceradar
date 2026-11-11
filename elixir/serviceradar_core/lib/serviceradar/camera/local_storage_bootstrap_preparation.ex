defmodule ServiceRadar.Camera.LocalStorageBootstrapPreparation do
  @moduledoc """
  Immutable Core preparation for bootstrapping a new local-storage lifetime.

  A storage-scoped provisioning principal chooses the operation UUID once and
  binds it to the original provider binding. Exact retries preserve the operation,
  canonical bytes and original provenance, including after credential rotation.
  A second operation for the lifetime conflicts instead of resetting its history.

  Preparation is not an empty-volume attestation or a reconciled checkpoint.
  It neither initializes a spool nor grants capture, registration, playback or
  deletion authority. The volume-side installer and two-sided completion protocol
  must establish those prerequisites separately; retained volumes need history
  reconciliation even when a preparation is present.
  """
  use Ash.Resource,
    domain: ServiceRadar.Camera,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ash.Expr

  alias Ash.Error.Changes.InvalidArgument
  alias ServiceRadar.Camera.ArchiveCanonicalJSON
  alias ServiceRadar.Camera.LocalStorageBinding

  postgres do
    table "camera_local_storage_bootstrap_preparations"
    schema "platform"
    repo ServiceRadar.Repo

    identity_index_names storage_lifetime: "camera_local_storage_bootstrap_storage_index"

    references do
      reference :local_storage_binding,
        on_delete: :restrict,
        name: "camera_local_storage_bootstrap_binding_fkey"
    end

    check_constraints do
      check_constraint :record, "camera_local_storage_bootstrap_bounds",
        check: "octet_length(record) BETWEEN 1 AND 512 AND record_sha256 ~ '^[0-9a-f]{64}$'"
    end
  end

  code_interface do
    define :prepare, args: [:operation_id, :binding_id]
  end

  actions do
    defaults [:read]

    create :prepare do
      accept []
      argument :operation_id, :uuid, allow_nil?: false
      argument :binding_id, :uuid, allow_nil?: false
      upsert? true
      upsert_identity :storage_lifetime
      upsert_fields []

      change fn changeset, context ->
        actor = context.actor || %{}

        changeset
        |> Ash.Changeset.force_change_attribute(:storage_id, Map.get(actor, :nvr_storage_id))
        |> Ash.Changeset.force_change_attribute(:prepared_by, Map.get(actor, :id))
        |> Ash.Changeset.before_action(&prepare_record(&1, actor))
        |> Ash.Changeset.after_action(fn submitted, retained ->
          if Ash.Changeset.get_attribute(submitted, :record) == retained.record,
            do: {:ok, retained},
            else:
              {:error,
               InvalidArgument.exception(
                 field: :operation_id,
                 message: "local storage bootstrap preparation conflicts"
               )}
        end)
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
    attribute :local_storage_binding_id, :uuid, allow_nil?: false
    attribute :record, :string, allow_nil?: false, constraints: [max_length: 512]

    attribute :record_sha256, :string,
      allow_nil?: false,
      constraints: [match: ~r/\A[0-9a-f]{64}\z/]

    attribute :prepared_by, :string,
      allow_nil?: false,
      constraints: [min_length: 1, max_length: 128, match: ~r/\A[!-~]+\z/]

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :local_storage_binding, LocalStorageBinding,
      allow_nil?: false,
      define_attribute?: false
  end

  identities do
    identity :storage_lifetime, [:storage_id]
  end

  defp prepare_record(changeset, actor) do
    binding_id = Ash.Changeset.get_argument(changeset, :binding_id)
    storage_id = Ash.Changeset.get_attribute(changeset, :storage_id)

    case Ash.get(LocalStorageBinding, binding_id, actor: actor, not_found_error?: false) do
      {:ok, %{storage_id: ^storage_id} = binding} ->
        operation_id = Ash.Changeset.get_argument(changeset, :operation_id)

        record =
          ArchiveCanonicalJSON.encode(%{
            "version" => 1,
            "kind" => "local_storage_bootstrap_prepared",
            "operation_id" => operation_id,
            "storage_id" => storage_id,
            "binding_id" => binding.id,
            "binding_sha256" => binding.binding_sha256
          })

        Ash.Changeset.force_change_attributes(changeset, %{
          id: operation_id,
          local_storage_binding_id: binding.id,
          record: record,
          record_sha256: :sha256 |> :crypto.hash(record) |> Base.encode16(case: :lower)
        })

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)

      {:ok, _} ->
        Ash.Changeset.add_error(changeset,
          field: :binding_id,
          message: "bootstrap preparation requires an available scoped storage binding"
        )
    end
  end
end
