defmodule ServiceRadar.Automation.Ansible.AwxTemplateBinding do
  @moduledoc """
  A reviewed, immutable AWX job-template launch binding.

  Bindings pin the complete non-secret supply-chain and launch surface that
  ServiceRadar is allowed to use. A changed template, project revision,
  execution environment, credential reference, prompt setting, input schema,
  or callback slot requires a new binding version. Only one version may be
  current for a controller/template pair.

  Binding lifecycle mutations are system-only. Human actors with
  `ansible.catalog.view` may inspect the reviewed catalog but cannot create,
  approve, supersede, revoke, or expire bindings directly.
  """

  use Ash.Resource,
    domain: ServiceRadar.Automation.Ansible,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Automation.Ansible.AwxLaunchContract
  alias ServiceRadar.Automation.Ansible.DispatchMarkerContract
  alias ServiceRadar.Automation.Ansible.VariableSchema
  alias ServiceRadar.Automation.CallbackGrants.LaunchContract
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "ansible.catalog.view"}
  @launch_check {ActorHasPermission, permission: "ansible.runs.launch"}
  @launch_read_fields [
    :id,
    :controller_id,
    :job_template_id,
    :binding_version,
    :current,
    :approval_state,
    :approval_id,
    :approval_expires_at,
    :allowed_inventory_ids,
    :run_mode_supported,
    :check_mode_supported,
    :ask_credential_on_launch,
    :input_schema,
    :input_classifications,
    :callback_actions
  ]
  @scm_revision ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
  @sha256_hex ~r/\A[0-9a-f]{64}\z/
  @credential_kind ~r/\A[a-z][a-z0-9_.-]{0,63}\z/
  @callback_action ~r/\A[a-z][a-z0-9_.:-]{0,127}\z/
  @callback_slot ~r/\A[a-z][a-z0-9_.-]{0,63}\z/
  @input_types MapSet.new(["text", "textarea", "integer", "float", "select", "multiselect"])
  @input_definition_keys MapSet.new([
                           "type",
                           "required",
                           "choices",
                           "min",
                           "max",
                           "label",
                           "help"
                         ])
  @classifications MapSet.new(["public", "internal"])
  @review_metadata_keys MapSet.new([
                          "review_ticket",
                          "awx_snapshot_digest",
                          "policy_version",
                          "source_ref",
                          "callback_contract",
                          "dispatch_marker_contract"
                        ])

  postgres do
    table "ansible_awx_template_bindings"
    repo ServiceRadar.Repo
    schema "platform"

    identity_index_names template_version: "ansible_awx_template_bindings_template_version_uidx",
                         current_template: "ansible_awx_template_bindings_current_template_uidx"

    identity_wheres_to_sql current_template: "current = true"

    references do
      reference :controller, on_delete: :restrict
    end
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]

    define :get_current_for_template,
      action: :current_for_template,
      args: [:controller_id, :job_template_id]

    define :get_current_approved_for_template,
      action: :current_approved_for_template,
      args: [:controller_id, :job_template_id]

    define :list_versions_for_template,
      action: :versions_for_template,
      args: [:controller_id, :job_template_id]

    define :create_version, action: :create_version
    define :supersede, action: :supersede
    define :revoke, action: :revoke
    define :expire, action: :expire
  end

  actions do
    read :read do
      primary? true
    end

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :current_for_template do
      argument :controller_id, :uuid, allow_nil?: false
      argument :job_template_id, :integer, allow_nil?: false, constraints: [min: 1]
      get? true

      filter expr(
               controller_id == ^arg(:controller_id) and
                 job_template_id == ^arg(:job_template_id) and current == true
             )
    end

    read :current_approved_for_template do
      argument :controller_id, :uuid, allow_nil?: false
      argument :job_template_id, :integer, allow_nil?: false, constraints: [min: 1]
      get? true

      filter expr(
               controller_id == ^arg(:controller_id) and
                 job_template_id == ^arg(:job_template_id) and current == true and
                 approval_state == :approved and approval_expires_at > now()
             )

      prepare build(select: @launch_read_fields)
    end

    read :versions_for_template do
      argument :controller_id, :uuid, allow_nil?: false
      argument :job_template_id, :integer, allow_nil?: false, constraints: [min: 1]

      filter expr(
               controller_id == ^arg(:controller_id) and
                 job_template_id == ^arg(:job_template_id)
             )

      prepare build(sort: [binding_version: :desc])
    end

    create :create_version do
      primary? true

      accept [
        :controller_id,
        :job_template_id,
        :binding_version,
        :current,
        :approval_state,
        :approval_id,
        :approval_expires_at,
        :inventory_policy,
        :allowed_inventory_ids,
        :project_id,
        :scm_revision,
        :content_sha256,
        :project_update_on_launch,
        :execution_environment_id,
        :credentials,
        :machine_credential_id,
        :run_mode_supported,
        :check_mode_supported,
        :ask_inventory_on_launch,
        :ask_limit_on_launch,
        :ask_credential_on_launch,
        :ask_job_type_on_launch,
        :dispatch_markers_retained,
        :inventory_groups_verified,
        :inventory_group_names,
        :input_schema,
        :input_classifications,
        :callback_actions,
        :callback_credential_type_id,
        :callback_credential_organization_id,
        :callback_credential_injector_digest,
        :callback_credential_slot,
        :awx_created_by_id,
        :reviewed_by_principal_type,
        :reviewed_by_principal_id,
        :reviewed_at,
        :review_metadata,
        :reviewed_launch_snapshot,
        :reviewed_launch_snapshot_digest,
        :superseded_at
      ]
    end

    update :supersede do
      require_atomic? false
      accept []
      change set_attribute(:current, false)
      change set_attribute(:superseded_at, &DateTime.utc_now/0)
    end

    update :revoke do
      require_atomic? false
      accept []
      change set_attribute(:approval_state, :revoked)
      change set_attribute(:current, false)
      change set_attribute(:superseded_at, &DateTime.utc_now/0)
    end

    update :expire do
      require_atomic? false
      accept []
      change set_attribute(:approval_state, :expired)
      change set_attribute(:current, false)
      change set_attribute(:superseded_at, &DateTime.utc_now/0)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    action_with_permission(
      [:read, :by_id, :current_for_template, :versions_for_template],
      @view_check
    )

    policy action(:current_approved_for_template) do
      authorize_if @view_check
      authorize_if @launch_check
    end
  end

  validations do
    validate fn changeset, _context ->
      with :ok <- validate_immutable_content(changeset),
           :ok <- validate_approval(changeset),
           :ok <- validate_currentness(changeset),
           :ok <- validate_inventory(changeset),
           :ok <- validate_modes_and_prompts(changeset),
           :ok <- validate_credentials(changeset),
           :ok <- validate_inventory_groups(changeset),
           :ok <- validate_input_contract(changeset),
           :ok <- validate_review_metadata(changeset),
           :ok <- validate_dispatch_marker_contract(changeset),
           :ok <- validate_reviewed_launch_snapshot(changeset) do
        validate_callback_contract(changeset)
      end
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :controller_id, :uuid, allow_nil?: false, public?: true

    attribute :job_template_id, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :binding_version, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :current, :boolean, allow_nil?: false, default: true, public?: true

    attribute :approval_state, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:pending, :approved, :rejected, :revoked, :expired]
    end

    attribute :approval_id, :uuid, allow_nil?: true, public?: true
    attribute :approval_expires_at, :utc_datetime_usec, allow_nil?: true, public?: true

    attribute :inventory_policy, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:fixed, :allow_list]
    end

    attribute :allowed_inventory_ids, {:array, :integer},
      allow_nil?: false,
      default: [],
      public?: true

    attribute :project_id, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :scm_revision, :string, allow_nil?: false, public?: true
    attribute :content_sha256, :string, allow_nil?: false, public?: true

    attribute :project_update_on_launch, :boolean,
      allow_nil?: false,
      default: false,
      public?: true

    attribute :execution_environment_id, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :credentials, {:array, :map}, allow_nil?: false, default: [], public?: true

    attribute :machine_credential_id, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :run_mode_supported, :boolean,
      allow_nil?: false,
      default: true,
      public?: true

    attribute :check_mode_supported, :boolean,
      allow_nil?: false,
      default: false,
      public?: true

    attribute :ask_inventory_on_launch, :boolean,
      allow_nil?: false,
      default: false,
      public?: true

    attribute :ask_limit_on_launch, :boolean,
      allow_nil?: false,
      default: false,
      public?: true

    attribute :ask_credential_on_launch, :boolean,
      allow_nil?: false,
      default: false,
      public?: true

    attribute :ask_job_type_on_launch, :boolean,
      allow_nil?: false,
      default: false,
      public?: true

    attribute :dispatch_markers_retained, :boolean,
      allow_nil?: false,
      default: false,
      public?: true

    attribute :inventory_groups_verified, :boolean,
      allow_nil?: false,
      default: false,
      public?: true

    attribute :inventory_group_names, {:array, :string},
      allow_nil?: false,
      default: [],
      public?: true

    attribute :input_schema, :map, allow_nil?: false, default: %{}, public?: true
    attribute :input_classifications, :map, allow_nil?: false, default: %{}, public?: true
    attribute :callback_actions, {:array, :string}, allow_nil?: false, default: [], public?: true

    attribute :callback_credential_type_id, :integer,
      allow_nil?: true,
      public?: true,
      constraints: [min: 1]

    attribute :callback_credential_organization_id, :integer,
      allow_nil?: true,
      public?: true,
      constraints: [min: 1]

    attribute :callback_credential_injector_digest, :string,
      allow_nil?: true,
      public?: true,
      constraints: [max_length: 64]

    attribute :callback_credential_slot, :string, allow_nil?: true, public?: true

    attribute :awx_created_by_id, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :reviewed_by_principal_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:human, :service_principal]
    end

    attribute :reviewed_by_principal_id, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1, max_length: 255]

    attribute :reviewed_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :review_metadata, :map, allow_nil?: false, default: %{}, public?: true

    # Existing persisted digest-only bindings remain readable and revocable, but
    # every newly approved version must carry this complete canonical contract.
    # The lifecycle actions accept no reviewed fields, preserving immutability.
    attribute :reviewed_launch_snapshot, :map, allow_nil?: true, public?: true

    attribute :reviewed_launch_snapshot_digest, :string,
      allow_nil?: true,
      public?: true,
      constraints: [max_length: 64]

    attribute :superseded_at, :utc_datetime_usec, allow_nil?: true, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :controller, ServiceRadar.Automation.Ansible.Controller do
      define_attribute? false
      source_attribute :controller_id
      public? true
    end
  end

  identities do
    identity :template_version, [:controller_id, :job_template_id, :binding_version]

    identity :current_template, [:controller_id, :job_template_id], where: expr(current == true)
  end

  defp validate_immutable_content(changeset) do
    scm_revision = attribute(changeset, :scm_revision)
    content_sha256 = attribute(changeset, :content_sha256)

    cond do
      attribute(changeset, :project_update_on_launch) != false ->
        invalid(:project_update_on_launch, "must remain false for an immutable binding")

      not is_binary(scm_revision) or not Regex.match?(@scm_revision, scm_revision) ->
        invalid(:scm_revision, "must be an immutable lowercase 40- or 64-character commit ID")

      not is_binary(content_sha256) or not Regex.match?(@sha256_hex, content_sha256) ->
        invalid(:content_sha256, "must be a lowercase SHA-256 hex digest")

      true ->
        :ok
    end
  end

  defp validate_approval(changeset) do
    state = attribute(changeset, :approval_state)
    approval_id = attribute(changeset, :approval_id)
    expires_at = attribute(changeset, :approval_expires_at)
    reviewed_at = attribute(changeset, :reviewed_at)

    cond do
      state == :approved and (is_nil(approval_id) or is_nil(expires_at)) ->
        invalid(:approval_state, "approved bindings require an approval ID and expiry")

      state == :pending and (not is_nil(approval_id) or not is_nil(expires_at)) ->
        invalid(:approval_state, "pending bindings cannot claim approval evidence")

      not is_nil(expires_at) and not is_nil(reviewed_at) and
          DateTime.compare(expires_at, reviewed_at) != :gt ->
        invalid(:approval_expires_at, "must be later than the review timestamp")

      true ->
        :ok
    end
  end

  defp validate_currentness(changeset) do
    current? = attribute(changeset, :current)
    superseded_at = attribute(changeset, :superseded_at)

    if (current? and is_nil(superseded_at)) or (not current? and not is_nil(superseded_at)) do
      :ok
    else
      invalid(:current, "must agree with the superseded timestamp")
    end
  end

  defp validate_inventory(changeset) do
    policy = attribute(changeset, :inventory_policy)
    inventory_ids = List.wrap(attribute(changeset, :allowed_inventory_ids))
    ask_inventory? = attribute(changeset, :ask_inventory_on_launch)

    cond do
      inventory_ids == [] or not positive_unique_integers?(inventory_ids) ->
        invalid(:allowed_inventory_ids, "must contain unique positive AWX inventory IDs")

      policy == :fixed and (length(inventory_ids) != 1 or ask_inventory? != false) ->
        invalid(:inventory_policy, "fixed policy requires one inventory and no inventory prompt")

      policy == :allow_list and ask_inventory? != true ->
        invalid(:inventory_policy, "allow-list policy requires the inventory prompt")

      true ->
        :ok
    end
  end

  defp validate_modes_and_prompts(changeset) do
    run? = attribute(changeset, :run_mode_supported)
    check? = attribute(changeset, :check_mode_supported)

    cond do
      run? != true and check? != true ->
        invalid(:run_mode_supported, "at least one reviewed run/check mode is required")

      run? == true and check? == true and attribute(changeset, :ask_job_type_on_launch) != true ->
        invalid(:ask_job_type_on_launch, "must be enabled when one template supports both modes")

      attribute(changeset, :ask_limit_on_launch) != true ->
        invalid(:ask_limit_on_launch, "must be enabled for an exact literal target limit")

      attribute(changeset, :dispatch_markers_retained) != true ->
        invalid(:dispatch_markers_retained, "must be verified before the binding can be reviewed")

      true ->
        :ok
    end
  end

  defp validate_credentials(changeset) do
    credentials = List.wrap(attribute(changeset, :credentials))
    machine_id = attribute(changeset, :machine_credential_id)

    with {:ok, refs} <- credential_refs(credentials),
         :ok <- unique_credential_ids(refs),
         :ok <- machine_credential(refs, machine_id) do
      :ok
    else
      {:error, message} -> invalid(:credentials, message)
    end
  end

  defp credential_refs([]), do: {:error, "must contain reviewed non-secret credential references"}

  defp credential_refs(credentials) do
    Enum.reduce_while(credentials, {:ok, []}, fn ref, {:ok, acc} ->
      id = map_value(ref, :id)
      kind = map_value(ref, :kind)
      keys = map_keys(ref)

      if keys == MapSet.new(["id", "kind"]) and unique_normalized_map_keys?(ref) and
           is_integer(id) and id > 0 and is_binary(kind) and
           Regex.match?(@credential_kind, kind) do
        {:cont, {:ok, [%{"id" => id, "kind" => kind} | acc]}}
      else
        {:halt, {:error, "must contain only exact {id, kind} references"}}
      end
    end)
  end

  defp unique_credential_ids(refs) do
    ids = Enum.map(refs, & &1["id"])

    if length(ids) == length(Enum.uniq(ids)),
      do: :ok,
      else: {:error, "must not contain duplicate credential IDs"}
  end

  defp machine_credential(refs, machine_id) do
    case Enum.find(refs, &(&1["id"] == machine_id)) do
      %{"kind" => "ssh"} -> :ok
      nil -> {:error, "must include the machine credential ID"}
      _ -> {:error, "must identify the machine credential with kind ssh"}
    end
  end

  defp validate_inventory_groups(changeset) do
    groups = List.wrap(attribute(changeset, :inventory_group_names))

    valid? =
      attribute(changeset, :inventory_groups_verified) == true and
        Enum.all?(groups, &valid_display_name?/1) and
        length(groups) == length(Enum.uniq(groups))

    if valid?,
      do: :ok,
      else:
        invalid(
          :inventory_group_names,
          "must be a verified complete set of unique non-empty AWX group names"
        )
  end

  defp validate_input_contract(changeset) do
    schema = attribute(changeset, :input_schema)
    classifications = attribute(changeset, :input_classifications)

    with :ok <- input_schema(schema),
         :ok <- input_classifications(schema, classifications) do
      :ok
    else
      {:error, field, message} -> invalid(field, message)
    end
  end

  defp input_schema(schema) when is_map(schema) and map_size(schema) <= 100 do
    if unique_normalized_map_keys?(schema) do
      validate_input_definitions(schema)
    else
      {:error, :input_schema, "must not contain duplicate normalized input names"}
    end
  end

  defp input_schema(_),
    do: {:error, :input_schema, "must be a map containing at most 100 typed fields"}

  defp validate_input_definitions(schema) do
    Enum.reduce_while(schema, :ok, fn {name, definition}, :ok ->
      name = to_string(name)

      case input_definition(name, definition) do
        :ok -> {:cont, :ok}
        {:error, _field, _message} = error -> {:halt, error}
      end
    end)
  end

  defp input_definition(name, definition) do
    type = map_value(definition, :type)
    required = map_value(definition, :required)
    choices = map_value(definition, :choices)
    min = map_value(definition, :min)
    max = map_value(definition, :max)

    cond do
      not VariableSchema.reviewed_input_name?(name) ->
        {:error, :input_schema, "contains a secret, magic, transport, or reserved input name"}

      not is_map(definition) or not unique_normalized_map_keys?(definition) or
          not MapSet.subset?(map_keys(definition), @input_definition_keys) ->
        {:error, :input_schema, "definitions contain unreviewed keys"}

      not MapSet.member?(@input_types, type) ->
        {:error, :input_schema, "definitions must use supported non-secret types"}

      not is_nil(required) and not is_boolean(required) ->
        {:error, :input_schema, "required flags must be booleans"}

      type in ["select", "multiselect"] and not valid_choices?(choices) ->
        {:error, :input_schema, "choice inputs require unique non-empty string choices"}

      type not in ["select", "multiselect"] and not empty_choices?(choices) ->
        {:error, :input_schema, "only choice inputs may declare choices"}

      not valid_bounds?(type, min, max) ->
        {:error, :input_schema, "numeric bounds must match the input type and remain ordered"}

      not optional_text?(map_value(definition, :label), 255) or
          not optional_text?(map_value(definition, :help), 2_048) ->
        {:error, :input_schema, "labels and help text exceed reviewed bounds"}

      true ->
        :ok
    end
  end

  defp input_classifications(schema, classifications) when is_map(classifications) do
    schema_keys = schema |> Map.keys() |> MapSet.new(&to_string/1)
    classification_keys = classifications |> Map.keys() |> MapSet.new(&to_string/1)

    valid_values? =
      Enum.all?(classifications, fn {_name, classification} ->
        MapSet.member?(@classifications, classification)
      end)

    if unique_normalized_map_keys?(classifications) and schema_keys == classification_keys and
         valid_values? do
      :ok
    else
      {:error, :input_classifications,
       "must classify every input exactly once as public or internal"}
    end
  end

  defp input_classifications(_schema, _classifications),
    do: {:error, :input_classifications, "must be a map"}

  defp validate_callback_contract(changeset) do
    actions = List.wrap(attribute(changeset, :callback_actions))
    credential_type_id = attribute(changeset, :callback_credential_type_id)
    organization_id = attribute(changeset, :callback_credential_organization_id)
    injector_digest = attribute(changeset, :callback_credential_injector_digest)
    slot = attribute(changeset, :callback_credential_slot)
    callback_fields = [credential_type_id, organization_id, injector_digest, slot]

    cond do
      actions != [] and attribute(changeset, :ask_credential_on_launch) != true ->
        invalid(
          :ask_credential_on_launch,
          "must be enabled when callback credentials are attached at launch"
        )

      actions == [] and Enum.any?(callback_fields, &(not is_nil(&1))) ->
        invalid(:callback_actions, "empty callbacks cannot retain a credential contract")

      actions != [] and
          (not is_integer(credential_type_id) or credential_type_id <= 0 or
             not is_integer(organization_id) or organization_id <= 0 or
             not is_binary(injector_digest) or not Regex.match?(@sha256_hex, injector_digest) or
             not is_binary(slot) or not Regex.match?(@callback_slot, slot)) ->
        invalid(
          :callback_actions,
          "callbacks require a reviewed credential type, organization, injector digest, and slot"
        )

      actions != [] and
          (length(actions) != length(Enum.uniq(actions)) or
             not Enum.all?(actions, &(is_binary(&1) and Regex.match?(@callback_action, &1)))) ->
        invalid(:callback_actions, "must contain unique reviewed callback action names")

      true ->
        validate_callback_launch_contract(changeset, actions)
    end
  end

  # Lifecycle updates cannot rewrite reviewed fields. Keep malformed legacy rows
  # revocable/expirable while enforcing the complete contract on every new row.
  defp validate_callback_launch_contract(%{action_type: :update}, _actions), do: :ok

  defp validate_callback_launch_contract(changeset, []) do
    metadata = attribute(changeset, :review_metadata)

    if is_map(metadata) and
         not MapSet.member?(map_keys(metadata), "callback_contract"),
       do: :ok,
       else:
         invalid(
           :review_metadata,
           "cannot retain a callback launch contract when callback actions are empty"
         )
  end

  defp validate_callback_launch_contract(changeset, actions) do
    binding = %{
      callback_actions: actions,
      ask_credential_on_launch: attribute(changeset, :ask_credential_on_launch),
      callback_credential_slot: attribute(changeset, :callback_credential_slot),
      review_metadata: attribute(changeset, :review_metadata)
    }

    case LaunchContract.from_binding(binding) do
      {:ok, _contract} ->
        :ok

      {:error, _reason} ->
        invalid(
          :review_metadata,
          "must contain one exact registry-backed callback launch contract"
        )
    end
  end

  defp validate_review_metadata(changeset) do
    metadata = attribute(changeset, :review_metadata)
    ticket = map_value(metadata, :review_ticket)
    snapshot_digest = map_value(metadata, :awx_snapshot_digest)

    cond do
      not is_map(metadata) or not MapSet.subset?(map_keys(metadata), @review_metadata_keys) ->
        invalid(:review_metadata, "must contain only reviewed non-secret metadata fields")

      not unique_normalized_map_keys?(metadata) ->
        invalid(:review_metadata, "must not contain duplicate normalized metadata fields")

      not is_binary(ticket) or byte_size(ticket) not in 1..255 ->
        invalid(:review_metadata, "must identify the external review ticket")

      not is_binary(snapshot_digest) or not Regex.match?(@sha256_hex, snapshot_digest) ->
        invalid(:review_metadata, "must contain the reviewed AWX snapshot digest")

      not optional_text?(map_value(metadata, :policy_version), 255) or
          not optional_text?(map_value(metadata, :source_ref), 2_048) ->
        invalid(:review_metadata, "contains an invalid policy version or source reference")

      true ->
        :ok
    end
  end

  # Do not make historical rows unrevocable merely because they predate the
  # complete reviewed snapshot. The secure launch gate uses
  # AwxLaunchContract.from_binding/1 and therefore treats those rows as
  # non-launchable until a reviewer creates a replacement version.
  defp validate_reviewed_launch_snapshot(%{action_type: :update}), do: :ok

  defp validate_reviewed_launch_snapshot(changeset) do
    snapshot = attribute(changeset, :reviewed_launch_snapshot)
    digest = attribute(changeset, :reviewed_launch_snapshot_digest)

    if attribute(changeset, :approval_state) != :approved and is_nil(snapshot) and is_nil(digest) do
      :ok
    else
      case AwxLaunchContract.from_binding(reviewed_launch_binding(changeset)) do
        {:ok, _snapshot} ->
          :ok

        {:error, :reviewed_launch_snapshot_required} ->
          invalid(
            :reviewed_launch_snapshot,
            "approved bindings require a complete canonical reviewed AWX launch snapshot"
          )

        {:error, :reviewed_launch_snapshot_incomplete} ->
          invalid(
            :reviewed_launch_snapshot_digest,
            "must be present exactly with the reviewed AWX launch snapshot"
          )

        {:error, :review_metadata_snapshot_digest_mismatch} ->
          invalid(
            :reviewed_launch_snapshot_digest,
            "must match both canonical reviewed snapshot content and review_metadata.awx_snapshot_digest"
          )

        {:error, _reason} ->
          invalid(
            :reviewed_launch_snapshot,
            "must be a secret-free canonical serviceradar.awx_launch_contract.v1 projection"
          )
      end
    end
  end

  defp reviewed_launch_binding(changeset) do
    %{
      controller_id: attribute(changeset, :controller_id),
      job_template_id: attribute(changeset, :job_template_id),
      project_id: attribute(changeset, :project_id),
      scm_revision: attribute(changeset, :scm_revision),
      allowed_inventory_ids: attribute(changeset, :allowed_inventory_ids),
      project_update_on_launch: attribute(changeset, :project_update_on_launch),
      execution_environment_id: attribute(changeset, :execution_environment_id),
      credentials: attribute(changeset, :credentials),
      run_mode_supported: attribute(changeset, :run_mode_supported),
      check_mode_supported: attribute(changeset, :check_mode_supported),
      ask_inventory_on_launch: attribute(changeset, :ask_inventory_on_launch),
      ask_limit_on_launch: attribute(changeset, :ask_limit_on_launch),
      ask_credential_on_launch: attribute(changeset, :ask_credential_on_launch),
      ask_job_type_on_launch: attribute(changeset, :ask_job_type_on_launch),
      review_metadata: attribute(changeset, :review_metadata),
      reviewed_launch_snapshot: attribute(changeset, :reviewed_launch_snapshot),
      reviewed_launch_snapshot_digest: attribute(changeset, :reviewed_launch_snapshot_digest)
    }
  end

  # Lifecycle updates cannot rewrite reviewed fields. Keep legacy bindings
  # revocable/expirable while requiring the restricted marker channel on every
  # newly reviewed binding version.
  defp validate_dispatch_marker_contract(%{action_type: :update}), do: :ok

  defp validate_dispatch_marker_contract(changeset) do
    case DispatchMarkerContract.from_review_metadata(attribute(changeset, :review_metadata)) do
      {:ok, _contract} ->
        :ok

      {:error, _reason} ->
        invalid(
          :review_metadata,
          "must contain the exact restricted AWX survey dispatch-marker contract"
        )
    end
  end

  defp positive_unique_integers?(values) do
    Enum.all?(values, &(is_integer(&1) and &1 > 0)) and
      length(values) == length(Enum.uniq(values))
  end

  defp valid_display_name?(value) when is_binary(value) do
    byte_size(value) in 1..255 and String.trim(value) == value and
      not String.contains?(value, ["\n", "\r", "\t", <<0>>])
  end

  defp valid_display_name?(_), do: false

  defp valid_choices?(choices) when is_list(choices) and choices != [] do
    Enum.all?(choices, &(is_binary(&1) and byte_size(&1) in 1..1_024)) and
      length(choices) == length(Enum.uniq(choices))
  end

  defp valid_choices?(_), do: false

  defp empty_choices?(nil), do: true
  defp empty_choices?([]), do: true
  defp empty_choices?(_), do: false

  defp valid_bounds?(type, min, max) when type in ["integer", "float"] do
    numeric? = fn value -> is_nil(value) or is_number(value) end

    numeric?.(min) and numeric?.(max) and
      (is_nil(min) or is_nil(max) or min <= max) and
      (type != "integer" or (integer_or_nil?(min) and integer_or_nil?(max)))
  end

  defp valid_bounds?(_type, nil, nil), do: true
  defp valid_bounds?(_type, _min, _max), do: false

  defp integer_or_nil?(nil), do: true
  defp integer_or_nil?(value), do: is_integer(value)

  defp optional_text?(nil, _max), do: true
  defp optional_text?(value, max) when is_binary(value), do: byte_size(value) <= max
  defp optional_text?(_value, _max), do: false

  defp attribute(changeset, name), do: Ash.Changeset.get_attribute(changeset, name)

  defp map_value(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp map_value(_map, _key), do: nil

  defp map_keys(map) when is_map(map), do: map |> Map.keys() |> MapSet.new(&to_string/1)
  defp map_keys(_map), do: MapSet.new()

  defp unique_normalized_map_keys?(map) when is_map(map),
    do: map_size(map) == MapSet.size(map_keys(map))

  defp unique_normalized_map_keys?(_map), do: false

  defp invalid(field, message), do: {:error, field: field, message: message}
end
