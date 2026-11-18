defmodule ServiceRadar.DeclarativeChecks.DeclarativeCheck do
  @moduledoc """
  Canonical, secret-free JSONB Directed Acyclic Graph (DAG) check resource
  (`platform.declarative_checks`, `schema_version: 1`, `1.1`).

  Stores unified active synthetic checks, multi-vantage composite checks, SRQL
  checks, and PR #6760 control-plane posture checks alongside Solution Pack
  provenance and managed-reconciliation metadata (`pack_id`, `pack_version`,
  `managed`, `template_fingerprint`, `parameter_overrides`).
  """

  use Ash.Resource,
    domain: ServiceRadar.DeclarativeChecks,
    data_layer: AshPostgres.DataLayer,
    notifiers: [ServiceRadar.DeclarativeChecks.ScheduleNotifier],
    authorizers: [Ash.Policy.Authorizer],
    primary_read_warning?: false

  alias Ash.Changeset.OriginalDataNotAvailable
  alias ServiceRadar.DeclarativeChecks.DeclarativeCheckCredentialBinding
  alias ServiceRadar.DeclarativeChecks.DeclarativeCheckEdgeObservation
  alias ServiceRadar.DeclarativeChecks.DeclarativeCheckInstance
  alias ServiceRadar.DeclarativeChecks.SchemaValidator
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "declarative_checks.view"}
  @manage_check {ActorHasPermission, permission: "declarative_checks.manage"}
  @evaluate_check {ActorHasPermission, permission: "declarative_checks.evaluate"}

  @slug_regex ~r/\A[a-z0-9][a-z0-9._-]{0,126}\z/
  @hex64_regex ~r/\A[0-9a-f]{64}\z/

  @create_fields [
    :schema_version,
    :slug,
    :name,
    :description,
    :state,
    :schedule,
    :target_binding,
    :inputs,
    :credential_slots,
    :nodes,
    :edges,
    :alert_policy,
    :ui_layout,
    :pack_id,
    :pack_version,
    :managed,
    :parameter_overrides
  ]

  @update_fields [
    :name,
    :description,
    :state,
    :schedule,
    :target_binding,
    :inputs,
    :credential_slots,
    :nodes,
    :edges,
    :alert_policy,
    :ui_layout,
    :pack_id,
    :pack_version,
    :managed,
    :parameter_overrides
  ]

  defmodule ValidateAndStampCheck do
    @moduledoc false
    use Ash.Resource.Change

    alias Ash.Error.Changes.InvalidAttribute

    @structural_fields [
      :schedule,
      :target_binding,
      :inputs,
      :credential_slots,
      :nodes,
      :edges,
      :alert_policy
    ]

    @impl true
    def change(changeset, _opts, _context) do
      case evaluate_and_stamp(changeset) do
        {:ok, stamped} ->
          Ash.Changeset.force_change_attributes(changeset, stamped)

        {:error, errors} ->
          Enum.reduce(errors, changeset, &Ash.Changeset.add_error(&2, &1))
      end
    end

    @impl true
    def atomic(changeset, _opts, _context) do
      if match?(%OriginalDataNotAvailable{}, changeset.data) do
        {:not_atomic, "validating declarative check DAG requires full document state"}
      else
        case evaluate_and_stamp(changeset) do
          {:ok, stamped} when map_size(stamped) > 0 -> {:atomic, stamped}
          {:ok, _} -> :ok
          {:error, errors} -> {:error, errors}
        end
      end
    end

    defp evaluate_and_stamp(changeset) do
      candidate = build_candidate_doc(changeset)

      val_opts =
        if Map.get(changeset.context, :skip_srql_nif?) == true,
          do: [skip_srql_nif?: true],
          else: []

      case SchemaValidator.validate_document(candidate, val_opts) do
        {:ok, normalized} ->
          verify_managed_guard_and_stamp(changeset, normalized)

        {:error, %{errors: diags}} ->
          errors =
            Enum.map(diags, fn d ->
              InvalidAttribute.exception(
                field: path_to_field(d.path),
                message: "#{d.code}: #{d.message}"
              )
            end)

          {:error, errors}
      end
    end

    defp verify_managed_guard_and_stamp(%{action_type: :create}, normalized) do
      {:ok, stamped_from_normalized(normalized, true)}
    end

    defp verify_managed_guard_and_stamp(changeset, normalized) do
      existing = changeset.data
      was_managed? = is_map(existing) and Map.get(existing, :managed) == true
      reconciling? = Map.get(changeset.context, :reconcile_managed) == true

      confirm_detach? =
        Ash.Changeset.get_argument(changeset, :confirm_detach) == true or
          Map.get(changeset.context, :confirm_detach) == true

      new_fp = normalized["template_fingerprint"]
      old_fp = is_map(existing) && Map.get(existing, :template_fingerprint)
      structural_changed? = was_managed? and is_binary(old_fp) and new_fp != old_fp

      cond do
        not was_managed? ->
          {:ok, stamped_from_normalized(normalized, false)}

        reconciling? ->
          {:ok, stamped_from_normalized(normalized, false)}

        not structural_changed? ->
          stamped =
            normalized
            |> stamped_from_normalized(false)
            |> Map.put(:managed, true)
            |> Map.put(:template_fingerprint, old_fp)

          {:ok, stamped}

        confirm_detach? ->
          stamped =
            normalized
            |> stamped_from_normalized(false)
            |> Map.put(:managed, false)
            |> Map.put(:template_fingerprint, new_fp)

          {:ok, stamped}

        true ->
          changed_field =
            Enum.find(
              @structural_fields,
              :nodes,
              &Ash.Changeset.changing_attribute?(changeset, &1)
            )

          {:error,
           [
             InvalidAttribute.exception(
               field: changed_field,
               message:
                 "managed_detach_confirmation_required: structural edits to a managed check require confirm_detach: true"
             )
           ]}
      end
    end

    defp stamped_from_normalized(normalized, include_slug?) do
      base = %{
        schema_version: 1,
        name: normalized["name"],
        description: normalized["description"],
        state: String.to_existing_atom(normalized["state"]),
        schedule: normalized["schedule"],
        target_binding: normalized["target_binding"],
        inputs: normalized["inputs"],
        credential_slots: normalized["credential_slots"],
        nodes: normalized["nodes"],
        edges: normalized["edges"],
        alert_policy: normalized["alert_policy"],
        ui_layout: normalized["ui_layout"],
        pack_id: normalized["pack_id"],
        pack_version: normalized["pack_version"],
        managed: normalized["managed"],
        template_fingerprint: normalized["template_fingerprint"],
        parameter_overrides: normalized["parameter_overrides"]
      }

      if include_slug?, do: Map.put(base, :slug, normalized["slug"]), else: base
    end

    defp build_candidate_doc(changeset) do
      fields = [
        :schema_version,
        :slug,
        :name,
        :description,
        :state,
        :pack_id,
        :pack_version,
        :managed,
        :parameter_overrides,
        :schedule,
        :target_binding,
        :inputs,
        :credential_slots,
        :nodes,
        :edges,
        :alert_policy,
        :ui_layout
      ]

      fields
      |> Map.new(fn field ->
        val = proposed(changeset, field)
        {Atom.to_string(field), val}
      end)
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()
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
                Map.has_key?(changeset.attributes, field) ->
                  Map.get(changeset.attributes, field)

                is_map(changeset.data) and not match?(%OriginalDataNotAvailable{}, changeset.data) ->
                  Map.get(changeset.data, field)

                true ->
                  nil
              end
          end
      end
    end

    defp path_to_field("$.slug" <> _), do: :slug
    defp path_to_field("$.name" <> _), do: :name
    defp path_to_field("$.state" <> _), do: :state
    defp path_to_field("$.schedule" <> _), do: :schedule
    defp path_to_field("$.target_binding" <> _), do: :target_binding
    defp path_to_field("$.inputs" <> _), do: :inputs
    defp path_to_field("$.parameter_overrides" <> _), do: :parameter_overrides
    defp path_to_field("$.credential_slots" <> _), do: :credential_slots
    defp path_to_field("$.nodes" <> _), do: :nodes
    defp path_to_field("$.edges" <> _), do: :edges
    defp path_to_field("$.alert_policy" <> _), do: :alert_policy
    defp path_to_field("$.ui_layout" <> _), do: :ui_layout
    defp path_to_field(_), do: :nodes
  end

  postgres do
    table "declarative_checks"
    repo ServiceRadar.Repo
    schema "platform"

    identity_index_names unique_slug: "declarative_checks_slug_uidx"

    custom_indexes do
      index [:state], name: "declarative_checks_state_idx"
      index [:pack_id], name: "declarative_checks_pack_id_idx", where: "pack_id IS NOT NULL"
    end

    check_constraints do
      check_constraint :schema_version, "declarative_checks_valid_contract",
        check: """
        schema_version = 1 AND
        slug ~ '^[a-z0-9][a-z0-9._-]{0,126}$' AND
        btrim(name) <> '' AND
        state IN ('draft', 'enabled', 'disabled') AND
        template_fingerprint ~ '^[0-9a-f]{64}$'
        """
    end
  end

  code_interface do
    define :list_checks, action: :read
    define :get_by_id, action: :by_id, args: [:id]
    define :get_by_slug, action: :by_slug, args: [:slug]
    define :list_enabled, action: :enabled
    define :record_pass, action: :record_pass
  end

  actions do
    defaults [:destroy]

    read :read do
      primary? true
      prepare build(sort: [slug: :asc])
    end

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :by_slug do
      argument :slug, :string, allow_nil?: false
      get? true
      filter expr(slug == ^arg(:slug))
    end

    read :enabled do
      filter expr(state == :enabled)
      prepare build(sort: [slug: :asc])
    end

    create :create do
      primary? true
      accept @create_fields
      change ValidateAndStampCheck
    end

    update :update do
      primary? true
      accept @update_fields
      argument :confirm_detach, :boolean, default: false
      change ValidateAndStampCheck
    end

    update :record_pass do
      accept [:last_evaluated_at]
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    policy action_type(:read) do
      authorize_if @view_check
      authorize_if @manage_check
      authorize_if @evaluate_check
    end

    policy action([:create, :update, :destroy]) do
      authorize_if @manage_check
    end

    policy action(:record_pass) do
      forbid_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :schema_version, :integer do
      allow_nil? false
      default 1
      public? true
    end

    attribute :slug, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 128, match: @slug_regex
    end

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 255
    end

    attribute :description, :string do
      allow_nil? true
      public? true
      constraints max_length: 4_096
    end

    attribute :state, :atom do
      allow_nil? false
      default :draft
      public? true
      constraints one_of: [:draft, :enabled, :disabled]
    end

    attribute :schedule, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :target_binding, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :inputs, {:array, :map} do
      allow_nil? false
      default []
      public? true
    end

    attribute :credential_slots, {:array, :map} do
      allow_nil? false
      default []
      public? true
    end

    attribute :nodes, {:array, :map} do
      allow_nil? false
      default []
      public? true
    end

    attribute :edges, {:array, :map} do
      allow_nil? false
      default []
      public? true
    end

    attribute :alert_policy, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :ui_layout, :map do
      allow_nil? true
      public? true
    end

    attribute :pack_id, :string do
      allow_nil? true
      public? true
      constraints max_length: 255
    end

    attribute :pack_version, :string do
      allow_nil? true
      public? true
      constraints max_length: 64
    end

    attribute :managed, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :template_fingerprint, :string do
      allow_nil? false
      public? true
      constraints min_length: 64, max_length: 64, match: @hex64_regex
    end

    attribute :parameter_overrides, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :last_evaluated_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at, public?: true
  end

  relationships do
    has_many :credential_bindings, DeclarativeCheckCredentialBinding do
      destination_attribute :check_id
      public? true
    end

    has_many :instances, DeclarativeCheckInstance do
      destination_attribute :check_id
      public? true
    end

    has_many :edge_observations, DeclarativeCheckEdgeObservation do
      destination_attribute :check_id
      public? true
    end
  end

  identities do
    identity :unique_slug, [:slug]
  end
end
