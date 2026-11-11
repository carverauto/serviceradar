defmodule ServiceRadar.Camera.LocalStorageBinding do
  @moduledoc """
  Immutable provider binding for a provisioned NVR storage lifetime.

  Identical retries return the original UUID and provenance. Reusing a storage
  UUID/generation with different content conflicts; a changed provider resource
  or profile needs a new generation. A new empty volume needs a new storage UUID.

  This internal provisioning API grants no qualification, capture, publication
  or playback authority. It has no update, activation or deletion action. The
  separate qualification authority will reference these retained generations.
  """
  use Ash.Resource,
    domain: ServiceRadar.Camera,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ash.Expr

  alias Ash.Error.Changes.InvalidArgument
  alias ServiceRadar.Camera.LocalStorageBindingConfig

  postgres do
    table "camera_local_storage_bindings"
    schema "platform"
    repo ServiceRadar.Repo

    check_constraints do
      check_constraint :generation, "camera_local_storage_binding_bounds",
        check: "schema_version = 1 AND generation > 0"

      check_constraint :binding_sha256, "camera_local_storage_binding_digests",
        check: "binding_sha256 ~ '^[0-9a-f]{64}$' AND profile_sha256 ~ '^[0-9a-f]{64}$'"
    end
  end

  code_interface do
    define :register, args: [:configuration]
  end

  actions do
    defaults [:read]

    create :register do
      accept []
      argument :configuration, :map, allow_nil?: false, sensitive?: true
      upsert? true
      upsert_identity :storage_generation
      upsert_fields []

      change fn changeset, context ->
        configuration = Ash.Changeset.get_argument(changeset, :configuration)

        case LocalStorageBindingConfig.attributes(configuration) do
          {:ok, attributes} ->
            changeset
            |> Ash.Changeset.force_change_attributes(attributes)
            |> Ash.Changeset.force_change_attribute(
              :provisioned_by,
              Map.get(context.actor || %{}, :id)
            )
            |> Ash.Changeset.after_action(fn _changeset, retained ->
              if Map.take(retained, Map.keys(attributes)) == attributes,
                do: {:ok, retained},
                else:
                  {:error,
                   InvalidArgument.exception(
                     field: :configuration,
                     message: "local storage binding conflicts"
                   )}
            end)

          {:error, _} ->
            Ash.Changeset.add_error(changeset,
              field: :configuration,
              message: "invalid local storage binding"
            )
        end
      end
    end
  end

  policies do
    policy action_type(:create) do
      authorize_if ServiceRadar.Camera.Checks.ProvisioningLocalStorage
    end

    policy action_type(:read) do
      forbid_unless actor_attribute_equals(:role, :system)

      authorize_if expr(
                     storage_id == ^actor(:nvr_storage_id) and
                       ^actor(:nvr_storage_purpose) in [:provision, :qualify]
                   )
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :schema_version, :integer, allow_nil?: false, constraints: [min: 1, max: 1]
    attribute :storage_id, :uuid, allow_nil?: false

    attribute :generation, :integer,
      allow_nil?: false,
      constraints: [min: 1, max: 9_223_372_036_854_775_807]

    attribute :provider_resource_ref, :string,
      allow_nil?: false,
      sensitive?: true,
      constraints: [min_length: 1, max_length: 256, match: ~r/\A[!-~]+\z/]

    attribute :profile_sha256, :string,
      allow_nil?: false,
      constraints: [match: ~r/\A[0-9a-f]{64}\z/]

    attribute :binding_sha256, :string,
      allow_nil?: false,
      constraints: [match: ~r/\A[0-9a-f]{64}\z/]

    attribute :provisioned_by, :string,
      allow_nil?: false,
      constraints: [min_length: 1, max_length: 128, match: ~r/\A[!-~]+\z/]

    create_timestamp :inserted_at
  end

  identities do
    identity :storage_generation, [:storage_id, :generation]
  end
end
