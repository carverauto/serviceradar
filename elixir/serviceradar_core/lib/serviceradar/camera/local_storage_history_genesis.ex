defmodule ServiceRadar.Camera.LocalStorageHistoryGenesis do
  @moduledoc """
  Immutable sequence-zero history evidence for an explicitly provisioned empty volume.

  The storage-scoped provisioner supplies the exact installation acknowledgement
  and a recovery generation from authenticated deployment control in its actor.
  Core derives the preparation and installation digests; no recorder-authored
  payload or generic history append is accepted. Exact retries retain the first
  bytes and provenance. A changed generation conflicts rather than resetting
  this storage lifetime's history.

  Establishment is an offline provisioning operation, not startup or recovery of
  retained media. The provisioner must verify exclusive empty-volume installation
  and durable acknowledgement retention before calling. The record correlates
  that attestation; it does not prove filesystem writes or current-generation
  reconciliation. Missing history on a retained volume must never call this API.

  This is only the genesis record, not a mutable history head or completion.
  It grants no capture, copy registration, playback, deletion or qualification.
  The runtime bootstrap barrier remains closed.
  """
  use Ash.Resource,
    domain: ServiceRadar.Camera,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ash.Expr

  alias Ash.Error.Changes.InvalidArgument
  alias ServiceRadar.Camera.ArchiveCanonicalJSON
  alias ServiceRadar.Camera.LocalStorageBootstrapInstallation

  postgres do
    table "camera_local_storage_history_geneses"
    schema "platform"
    repo ServiceRadar.Repo

    identity_index_names storage_lifetime: "camera_local_storage_genesis_storage_index"

    references do
      reference :installation,
        on_delete: :restrict,
        name: "camera_local_storage_genesis_installation_fkey"
    end

    check_constraints do
      check_constraint :record, "camera_local_storage_genesis_bounds",
        check: "octet_length(record) BETWEEN 1 AND 1024 AND record_sha256 ~ '^[0-9a-f]{64}$'"
    end
  end

  code_interface do
    define :establish, args: [:installation_id, :installation_sha256]
  end

  actions do
    defaults [:read]

    create :establish do
      accept []
      argument :installation_id, :uuid, allow_nil?: false

      argument :installation_sha256, :string,
        allow_nil?: false,
        constraints: [match: ~r/\A[0-9a-f]{64}\z/]

      upsert? true
      upsert_identity :storage_lifetime
      upsert_fields []

      change fn changeset, context ->
        actor = context.actor || %{}

        changeset
        |> Ash.Changeset.force_change_attribute(:storage_id, Map.get(actor, :nvr_storage_id))
        |> Ash.Changeset.force_change_attribute(:established_by, Map.get(actor, :id))
        |> Ash.Changeset.before_action(&establish_genesis(&1, actor))
        |> Ash.Changeset.after_action(fn submitted, retained ->
          if Ash.Changeset.get_attribute(submitted, :record) == retained.record,
            do: {:ok, retained},
            else:
              {:error,
               InvalidArgument.exception(
                 field: :installation_id,
                 message: "local storage history genesis conflicts"
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
    attribute :record, :string, allow_nil?: false, constraints: [max_length: 1024]

    attribute :record_sha256, :string,
      allow_nil?: false,
      constraints: [match: ~r/\A[0-9a-f]{64}\z/]

    attribute :established_by, :string,
      allow_nil?: false,
      constraints: [min_length: 1, max_length: 128, match: ~r/\A[!-~]+\z/]

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :installation, LocalStorageBootstrapInstallation,
      source_attribute: :id,
      allow_nil?: false,
      define_attribute?: false
  end

  identities do
    identity :storage_lifetime, [:storage_id]
  end

  defp establish_genesis(changeset, actor) do
    installation_id = Ash.Changeset.get_argument(changeset, :installation_id)
    digest = Ash.Changeset.get_argument(changeset, :installation_sha256)
    storage_id = Ash.Changeset.get_attribute(changeset, :storage_id)
    generation = Map.get(actor, :nvr_recovery_generation)

    with {:ok, ^generation} when is_binary(generation) <- Ecto.UUID.cast(generation),
         {:ok, %{storage_id: ^storage_id, record_sha256: ^digest} = installation} <-
           Ash.get(LocalStorageBootstrapInstallation, installation_id,
             actor: actor,
             load: [:preparation],
             not_found_error?: false
           ) do
      record =
        ArchiveCanonicalJSON.encode(%{
          "version" => 1,
          "kind" => "local_storage_history_genesis",
          "operation_id" => installation.id,
          "storage_id" => storage_id,
          "recovery_generation" => generation,
          "sequence" => 0,
          "previous_sha256" => nil,
          "preparation_sha256" => installation.preparation.record_sha256,
          "installation_sha256" => digest
        })

      Ash.Changeset.force_change_attributes(changeset, %{
        id: installation.id,
        record: record,
        record_sha256: :sha256 |> :crypto.hash(record) |> Base.encode16(case: :lower)
      })
    else
      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)

      _ ->
        Ash.Changeset.add_error(changeset,
          field: :installation_id,
          message:
            "genesis requires the exact scoped installation and deployment recovery generation"
        )
    end
  end
end
