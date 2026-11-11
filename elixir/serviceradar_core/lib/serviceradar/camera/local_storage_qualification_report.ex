defmodule ServiceRadar.Camera.LocalStorageQualificationReport do
  @moduledoc """
  Immutable qualification evidence submissions for local-storage bindings.

  The trusted adapter supplies a deployment qualification principal scoped to
  the storage lifetime; the report cannot supply its own issuing identity.
  Exact retries retain the original UUID, issuer and timestamp. Changed content
  requires a new revision and never replaces a historical report.

  Retention validates the binding correlation, not the evidence or its freshness.
  This resource has no activation, update or deletion action and grants no
  capture, registration or playback authority.
  """
  use Ash.Resource,
    domain: ServiceRadar.Camera,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ash.Expr

  alias Ash.Error.Changes.InvalidArgument
  alias ServiceRadar.Camera.LocalStorageBinding
  alias ServiceRadar.Camera.LocalStorageQualificationDocument

  postgres do
    table "camera_local_storage_qualification_reports"
    schema "platform"
    repo ServiceRadar.Repo

    identity_index_names binding_revision: "camera_local_storage_report_binding_revision_index"

    references do
      reference :local_storage_binding,
        on_delete: :restrict,
        name: "camera_local_storage_report_binding_fkey"
    end

    check_constraints do
      check_constraint :revision, "camera_local_storage_report_revision", check: "revision > 0"

      check_constraint :report, "camera_local_storage_report_bounds",
        check: """
        report_sha256 ~ '^[0-9a-f]{64}$' AND jsonb_typeof(report) = 'object' AND
        octet_length(report::text) <= 8192
        """
    end
  end

  code_interface do
    define :submit, args: [:document]
  end

  actions do
    defaults [:read]

    create :submit do
      accept []
      argument :document, :map, allow_nil?: false, sensitive?: true
      upsert? true
      upsert_identity :binding_revision
      upsert_fields []

      change fn changeset, context ->
        document = Ash.Changeset.get_argument(changeset, :document)

        case LocalStorageQualificationDocument.attributes(document) do
          {:ok, attributes} ->
            changeset
            |> Ash.Changeset.force_change_attributes(attributes)
            |> Ash.Changeset.force_change_attribute(
              :issued_by,
              Map.get(context.actor || %{}, :id)
            )
            |> Ash.Changeset.before_action(&correlate_binding(&1, document, context.actor))
            |> Ash.Changeset.after_action(fn _changeset, retained ->
              if Map.take(retained, Map.keys(attributes)) == attributes,
                do: {:ok, retained},
                else:
                  {:error,
                   InvalidArgument.exception(
                     field: :document,
                     message: "local storage qualification report conflicts"
                   )}
            end)

          {:error, _} ->
            Ash.Changeset.add_error(changeset,
              field: :document,
              message: "invalid local storage qualification report"
            )
        end
      end
    end
  end

  policies do
    policy action_type(:create) do
      authorize_if ServiceRadar.Camera.Checks.QualifyingLocalStorage
    end

    policy action_type(:read) do
      forbid_unless actor_attribute_equals(:role, :system)
      forbid_unless actor_attribute_equals(:nvr_storage_purpose, :qualify)
      authorize_if expr(local_storage_binding.storage_id == ^actor(:nvr_storage_id))
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :local_storage_binding_id, :uuid, allow_nil?: false

    attribute :revision, :integer,
      allow_nil?: false,
      constraints: [min: 1, max: 9_223_372_036_854_775_807]

    attribute :report, :map, allow_nil?: false, sensitive?: true

    attribute :report_sha256, :string,
      allow_nil?: false,
      constraints: [match: ~r/\A[0-9a-f]{64}\z/]

    attribute :issued_by, :string,
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
    identity :binding_revision, [:local_storage_binding_id, :revision]
  end

  defp correlate_binding(changeset, document, actor) do
    case Ash.get(LocalStorageBinding, document["binding_id"], actor: actor) do
      {:ok, binding} when not is_nil(binding) ->
        if binding.storage_id == document["storage_id"] and
             binding.binding_sha256 == document["binding_sha256"] and
             binding.profile_sha256 == document["profile_sha256"] do
          changeset
        else
          binding_error(changeset)
        end

      {:ok, nil} ->
        binding_error(changeset)

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end

  defp binding_error(changeset),
    do:
      Ash.Changeset.add_error(changeset,
        field: :document,
        message: "local storage qualification report does not match an available binding"
      )
end
