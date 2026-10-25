defmodule ServiceRadar.Camera.ArchiveBinding do
  @moduledoc """
  Immutable, unqualified destination generation supplied by provisioning.

  Registration is idempotent only for exactly identical input. There are no
  update, activation or deletion actions. This resource stores no credentials
  and grants no object-storage access. Local spool storage identity and rotating
  credential generations are separate from this retained destination.
  """
  use Ash.Resource,
    domain: ServiceRadar.Camera,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ash.Expr

  alias Ash.Error.Changes.InvalidArgument
  alias ServiceRadar.Camera.ArchiveDestination

  postgres do
    table "camera_archive_bindings"
    schema "platform"
    repo ServiceRadar.Repo

    check_constraints do
      check_constraint :generation, "camera_archive_binding_generation_positive",
        check: "generation > 0"

      check_constraint :schema_version, "camera_archive_binding_v1",
        check: """
        schema_version = 1 AND purpose = 'recording' AND provider = 's3_compatible' AND
        namespace = 'recordings/v1' AND archive_format_version = 1 AND
        required_encryption = 'sse_s3_aes256' AND capability_state = 'unqualified' AND
        length(destination_sha256) = 64
        """
    end
  end

  code_interface do
    define :register, action: :register, args: [:destination]
  end

  actions do
    defaults [:read]

    create :register do
      accept []
      argument :destination, :map, allow_nil?: false
      upsert? true
      upsert_identity :provisioned_generation
      upsert_fields []

      change fn changeset, _context ->
        case ArchiveDestination.attributes(Ash.Changeset.get_argument(changeset, :destination)) do
          {:ok, attributes} ->
            changeset
            |> Ash.Changeset.force_change_attributes(attributes)
            |> Ash.Changeset.after_action(fn _changeset, retained ->
              if Map.take(retained, Map.keys(attributes)) == attributes,
                do: {:ok, retained},
                else:
                  {:error,
                   InvalidArgument.exception(
                     field: :destination,
                     message: "archive destination conflicts"
                   )}
            end)

          {:error, _} ->
            Ash.Changeset.add_error(changeset,
              field: :destination,
              message: "invalid archive destination"
            )
        end
      end
    end
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :schema_version, :integer, allow_nil?: false, constraints: [min: 1, max: 1]

    attribute :provisioning_ref, :string,
      allow_nil?: false,
      constraints: [min_length: 1, max_length: 128]

    attribute :generation, :integer, allow_nil?: false, constraints: [min: 1]
    attribute :purpose, :string, allow_nil?: false
    attribute :provider, :string, allow_nil?: false
    attribute :endpoint, :string, allow_nil?: false, constraints: [max_length: 261]
    attribute :region, :string, allow_nil?: false, constraints: [max_length: 40]
    attribute :bucket, :string, allow_nil?: false, constraints: [max_length: 63]
    attribute :namespace, :string, allow_nil?: false
    attribute :archive_format_version, :integer, allow_nil?: false, constraints: [min: 1, max: 1]
    attribute :required_encryption, :string, allow_nil?: false

    attribute :destination_sha256, :string,
      allow_nil?: false,
      constraints: [min_length: 64, max_length: 64]

    attribute :capability_state, :atom,
      allow_nil?: false,
      default: :unqualified,
      constraints: [one_of: [:unqualified]]

    create_timestamp :inserted_at
  end

  calculations do
    calculate :database_now, :utc_datetime_usec, expr(fragment("clock_timestamp()"))
  end

  identities do
    identity :provisioned_generation, [:provisioning_ref, :generation]
  end
end
