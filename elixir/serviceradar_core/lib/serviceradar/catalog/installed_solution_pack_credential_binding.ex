defmodule ServiceRadar.Catalog.InstalledSolutionPackCredentialBinding do
  @moduledoc """
  Deployment-local binding (`platform.installed_solution_pack_credential_bindings`)
  mapping an abstract `credential_slots` entry on an `InstalledSolutionPack` to
  either a reusable secret (`platform.network_credential_secrets`) or a dynamic
  credential rule (`platform.network_credential_rules`).

  Enforces SQL `on_delete: :restrict` foreign keys and registers usage in
  `ServiceRadar.Credentials.CredentialUsage`, `GuardCredentialDestroy`, and
  `GuardCredentialRuleLifecycle`. Never serialized in pack exports.
  """

  use Ash.Resource,
    domain: ServiceRadar.Catalog,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Ash.Changeset.OriginalDataNotAvailable
  alias ServiceRadar.Catalog.InstalledSolutionPack
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "catalog.view"}
  @install_check {ActorHasPermission, permission: "catalog.packs.install"}
  @sync_check {ActorHasPermission, permission: "catalog.gitops.sync"}

  @slot_regex ~r/\A[a-zA-Z0-9][a-zA-Z0-9._:-]{0,126}\z/

  defmodule ValidateTargetXor do
    @moduledoc false
    use Ash.Resource.Change

    alias Ash.Error.Changes.InvalidAttribute

    @impl true
    def change(changeset, _opts, _context) do
      case check_xor(changeset) do
        :ok -> changeset
        {:error, err} -> Ash.Changeset.add_error(changeset, err)
      end
    end

    @impl true
    def atomic(changeset, _opts, _context) do
      if changeset.action_type != :create and match?(%OriginalDataNotAvailable{}, changeset.data) do
        {:not_atomic, "validating binding XOR requires loaded row"}
      else
        case check_xor(changeset) do
          :ok -> :ok
          {:error, err} -> {:error, [err]}
        end
      end
    end

    defp check_xor(changeset) do
      secret_id = proposed(changeset, :credential_secret_id)
      rule_id = proposed(changeset, :credential_rule_id)

      cond do
        not is_nil(secret_id) and not is_nil(rule_id) ->
          {:error,
           InvalidAttribute.exception(
             field: :credential_secret_id,
             message:
               "must set exactly one of credential_secret_id or credential_rule_id, not both"
           )}

        is_nil(secret_id) and is_nil(rule_id) ->
          {:error,
           InvalidAttribute.exception(
             field: :credential_secret_id,
             message: "must set either credential_secret_id or credential_rule_id"
           )}

        true ->
          :ok
      end
    end

    defp proposed(changeset, field) do
      case Keyword.fetch(changeset.atomics, field) do
        {:ok, v} ->
          v

        :error ->
          case Ash.Changeset.fetch_change(changeset, field) do
            {:ok, v} ->
              v

            :error ->
              cond do
                Map.has_key?(changeset.attributes, field) -> Map.get(changeset.attributes, field)
                is_map(changeset.data) -> Map.get(changeset.data, field)
                true -> nil
              end
          end
      end
    end
  end

  postgres do
    table "installed_solution_pack_credential_bindings"
    repo ServiceRadar.Repo
    schema "platform"

    identity_index_names unique_pack_slot:
                           "installed_solution_pack_credential_bindings_pack_slot_uidx"

    custom_indexes do
      index [:credential_secret_id],
        name: "installed_solution_pack_credential_bindings_secret_idx",
        where: "credential_secret_id IS NOT NULL"

      index [:credential_rule_id],
        name: "installed_solution_pack_credential_bindings_rule_idx",
        where: "credential_rule_id IS NOT NULL"
    end

    references do
      reference :installed_pack,
        on_delete: :delete,
        name: "installed_solution_pack_credential_bindings_installed_pack_id_fkey"

      reference :credential_secret,
        on_delete: :restrict,
        name: "installed_solution_pack_credential_bindings_credential_secret_id_fkey"

      reference :credential_rule,
        on_delete: :restrict,
        name: "installed_solution_pack_credential_bindings_credential_rule_id_fkey"
    end

    check_constraints do
      check_constraint :credential_secret_id,
                       "installed_solution_pack_credential_bindings_target_xor",
                       check: """
                       btrim(slot) <> '' AND
                       ((credential_secret_id IS NOT NULL AND credential_rule_id IS NULL) OR
                        (credential_secret_id IS NULL AND credential_rule_id IS NOT NULL))
                       """
    end
  end

  code_interface do
    define :list_by_pack, action: :by_pack, args: [:installed_pack_id]
    define :upsert_binding, action: :upsert
  end

  actions do
    defaults [:read, :destroy]

    read :by_pack do
      argument :installed_pack_id, :uuid, allow_nil?: false
      filter expr(installed_pack_id == ^arg(:installed_pack_id))
      prepare build(sort: [slot: :asc])
    end

    create :create do
      primary? true
      accept [:installed_pack_id, :slot, :credential_secret_id, :credential_rule_id]
      change ValidateTargetXor
    end

    create :upsert do
      accept [:installed_pack_id, :slot, :credential_secret_id, :credential_rule_id]
      upsert? true
      upsert_identity :unique_pack_slot
      upsert_fields [:credential_secret_id, :credential_rule_id, :updated_at]
      change ValidateTargetXor
    end

    update :update do
      primary? true
      accept [:credential_secret_id, :credential_rule_id]
      change ValidateTargetXor
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    policy action_type(:read) do
      authorize_if @view_check
      authorize_if @install_check
      authorize_if @sync_check
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if @install_check
      authorize_if @sync_check
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :installed_pack_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :slot, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 128, match: @slot_regex
    end

    attribute :credential_secret_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :credential_rule_id, :uuid do
      allow_nil? true
      public? true
    end

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at, public?: true
  end

  relationships do
    belongs_to :installed_pack, InstalledSolutionPack do
      allow_nil? false
      public? true
      define_attribute? false
      source_attribute :installed_pack_id
    end

    belongs_to :credential_secret, NetworkCredentialSecret do
      allow_nil? true
      public? true
      define_attribute? false
      source_attribute :credential_secret_id
    end

    belongs_to :credential_rule, NetworkCredentialRule do
      allow_nil? true
      public? true
      define_attribute? false
      source_attribute :credential_rule_id
    end
  end

  identities do
    identity :unique_pack_slot, [:installed_pack_id, :slot]
  end

  @doc """
  Formats a redacted summary map for API/UI responses without secret material.
  """
  @spec redacted_summary(map()) :: map()
  def redacted_summary(binding) when is_map(binding) do
    secret_id =
      Map.get(binding, :credential_secret_id) || Map.get(binding, "credential_secret_id")

    rule_id = Map.get(binding, :credential_rule_id) || Map.get(binding, "credential_rule_id")

    %{
      "id" => to_string(Map.get(binding, :id) || Map.get(binding, "id") || ""),
      "slot" => to_string(Map.get(binding, :slot) || Map.get(binding, "slot") || ""),
      "binding_mode" => if(is_nil(rule_id), do: "secret", else: "rule"),
      "credential_secret_id" => secret_id && to_string(secret_id),
      "credential_rule_id" => rule_id && to_string(rule_id)
    }
  end
end
