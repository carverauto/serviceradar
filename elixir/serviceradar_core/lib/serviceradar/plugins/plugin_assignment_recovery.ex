defmodule ServiceRadar.Plugins.PluginAssignmentRecovery do
  @moduledoc """
  Safe recovery for assignments quarantined by the partition-binding migration.

  A legacy row is historical evidence only: this context never assigns it a
  partition or enables it. A manual recovery creates a separate assignment
  through `PluginAssignment.create`, whose normal change derives its partition
  from the current authenticated control session.
  """

  alias Ash.Error.Changes.InvalidAttribute
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialRedactor
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Events.AuditWriter
  alias ServiceRadar.Identity.CurrentUserAuthority
  alias ServiceRadar.Observability.ServiceStateRegistry
  alias ServiceRadar.Plugins.ConfigSchema
  alias ServiceRadar.Plugins.MapUtils
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginAssignmentRecoveryAudit
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Plugins.PluginPolicyAssignmentRecoveryRequest
  alias ServiceRadar.Plugins.PluginTargetPolicy
  alias ServiceRadar.Plugins.PolicyOwnedAssignmentRecovery.OwnerReference
  alias ServiceRadar.Plugins.RecoveryConfigDispatch
  alias ServiceRadar.Plugins.SecretRefs
  alias ServiceRadar.Policies.Checks.ActorHasPermission
  alias ServiceRadar.Repo

  require Ash.Query

  @plugins_manage_permission "settings.plugins.manage"
  @legacy_list_default_limit 50
  @legacy_list_max_limit 100
  @recovery_audit_writer SystemActor.system(:plugin_assignment_recovery_audit_writer)
  @recovery_audit_lookup SystemActor.system(:plugin_assignment_recovery_audit_lookup)
  @policy_recovery_request_lookup SystemActor.system(:plugin_policy_assignment_recovery_lookup)
  @automatic_recovery_actor SystemActor.system(:plugin_assignment_automatic_recovery)
  @automatic_recovery_default_limit 100
  @automatic_recovery_max_limit 500

  @manual_recovery_audit_decisions %{
    initiating_actor_required: {:denied, :initiating_actor_required},
    authorization_denied: {:denied, :authorization_denied},
    confirmation_required: {:denied, :confirmation_required},
    legacy_assignment_not_found: {:denied, :legacy_assignment_not_found},
    not_legacy_unbound: {:rejected, :not_legacy_unbound},
    policy_assignment_requires_reconciliation:
      {:rejected, :policy_assignment_requires_reconciliation},
    authenticated_agent_partition_unavailable:
      {:evidence_unavailable, :authenticated_agent_partition_unavailable},
    authenticated_agent_partition_mismatch:
      {:identity_mismatch, :authenticated_agent_partition_mismatch},
    authenticated_agent_partition_changed:
      {:identity_mismatch, :authenticated_agent_partition_changed},
    plugin_package_not_found: {:package_unavailable, :plugin_package_not_found},
    plugin_package_not_approved: {:package_unavailable, :plugin_package_not_approved},
    params_not_recoverable: {:schema_invalid, :params_not_recoverable},
    active_assignment_conflict: {:conflict, :active_assignment_conflict},
    bound_manual_assignment_conflict: {:conflict, :bound_manual_assignment_conflict},
    assignment_create_failed: {:rejected, :assignment_create_failed},
    recovery_audit_failed: {:failed, :recovery_audit_failed},
    recovery_failed: {:failed, :recovery_failed}
  }

  @type recovery_kind ::
          :manual_reapproval
          | :policy_reconciliation
          | :unsupported_policy_owner
          | :not_recoverable

  @doc """
  Lists one bounded page of disabled, partition-unbound rows with an
  allowlisted recovery classification. This deliberately does not read current
  inventory metadata. Callers must treat `:unsupported_policy_owner` as
  non-actionable historical evidence, not as a policy reconciliation request.
  Callers may pass `:limit` (maximum 100) and an opaque `:after_id` cursor
  from the preceding page. Offset pagination is deliberately unsupported so a
  caller cannot drive arbitrarily deep scans.
  """
  @spec list_legacy(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_legacy(opts \\ []) when is_list(opts) do
    limit = legacy_list_limit(Keyword.get(opts, :limit))

    with {:ok, actor} <- initiating_actor(opts),
         :ok <- authorize_plugins_manage(actor),
         {:ok, after_id} <- legacy_list_after_id(Keyword.get(opts, :after_id)),
         {:ok, assignments} <- legacy_assignments(actor, limit, after_id) do
      {:ok, Enum.map(assignments, &legacy_summary/1)}
    end
  end

  @doc """
  Returns the current mTLS-derived partition preview for an agent, without
  consulting inventory or accepting a caller-supplied partition. This is the
  generic core boundary used by the web adapter before it selects a legacy row.
  """
  @spec authenticated_partition_preview(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def authenticated_partition_preview(agent_uid, opts \\ [])

  def authenticated_partition_preview(agent_uid, opts) when is_binary(agent_uid) do
    with {:ok, actor} <- initiating_actor(opts),
         :ok <- authorize_plugins_manage(actor),
         true <- present?(agent_uid) do
      {:ok, partition_preview(agent_uid)}
    else
      false -> {:error, :invalid_agent_uid}
      {:error, _reason} = error -> error
    end
  end

  def authenticated_partition_preview(_agent_uid, _opts), do: {:error, :invalid_agent_uid}

  @doc """
  Returns a non-authoritative preview of the selected legacy row's currently
  authenticated edge principal. The result is intentionally informational; the
  recovery action resolves evidence again while holding its transaction.
  """
  @spec preview(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def preview(legacy_assignment_id, opts \\ [])

  def preview(legacy_assignment_id, opts) when is_binary(legacy_assignment_id) do
    with {:ok, actor} <- initiating_actor(opts),
         :ok <- authorize_plugins_manage(actor),
         {:ok, assignment} <- get_assignment(legacy_assignment_id, actor),
         :ok <- ensure_legacy_unbound(assignment) do
      {:ok, preview_summary(assignment)}
    end
  end

  def preview(_legacy_assignment_id, _opts), do: {:error, :legacy_assignment_not_found}

  @doc """
  Projects the UI-safe details for one disabled, partition-unbound assignment.

  The projection intentionally omits configuration, secret references, and
  encrypted secret material. `config_compatibility` reports only a typed,
  current-schema outcome; `owner` contains an opaque, normalized owner
  reference and a display label where it can be safely resolved.
  """
  @spec legacy_detail(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def legacy_detail(legacy_assignment_id, opts \\ [])

  def legacy_detail(legacy_assignment_id, opts) when is_binary(legacy_assignment_id) do
    with {:ok, actor} <- initiating_actor(opts),
         :ok <- authorize_plugins_manage(actor),
         {:ok, assignment} <- get_assignment(legacy_assignment_id, actor),
         :ok <- ensure_legacy_unbound(assignment) do
      {:ok,
       assignment
       |> legacy_summary()
       |> Map.put(:owner, owner_projection(assignment, actor))
       |> Map.put(:config_compatibility, config_compatibility(assignment, actor))
       |> Map.put(:manual_recovery, manual_recovery_projection(assignment, actor))
       |> Map.put(:policy_recovery, policy_recovery_projection(assignment))
       |> Map.put(
         :authenticated_partition,
         authenticated_partition_projection(assignment.agent_uid)
       )}
    end
  end

  def legacy_detail(_legacy_assignment_id, _opts), do: {:error, :legacy_assignment_not_found}

  @doc """
  Creates a fresh partition-bound manual assignment after explicit confirmation.

  An explicit `:actor` or authenticated `:scope` is mandatory. This is a
  user/API-token action and deliberately has no `SystemActor` fallback. The
  returned map has no params or secret material.
  """
  @spec recover_manual(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def recover_manual(legacy_assignment_id, opts \\ [])

  def recover_manual(legacy_assignment_id, opts) when is_binary(legacy_assignment_id) do
    case initiating_actor(opts) do
      {:ok, actor} ->
        result =
          with :ok <- authorize_plugins_manage(actor),
               :ok <- require_confirmation(opts) do
            run_recovery_transaction(legacy_assignment_id, actor, opts)
          end

        write_manual_recovery_event(legacy_assignment_id, audit_actor(actor), result, opts)
        result

      {:error, _reason} = error ->
        write_manual_recovery_event(
          legacy_assignment_id,
          audit_actor_from_opts(opts),
          error,
          opts
        )

        error
    end
  end

  def recover_manual(_legacy_assignment_id, opts) do
    result = {:error, :legacy_assignment_not_found}

    write_manual_recovery_event(
      nil,
      audit_actor_from_opts(opts),
      result,
      opts
    )

    result
  end

  @doc """
  Converges one bounded page of trusted first-party manual assignments without
  creating operator work.

  This is an internal maintenance boundary. It always uses a named system
  actor, requires the historical package to remain approved and cryptographically
  verified as first-party, re-resolves current mTLS evidence, validates the
  current schema, and creates a fresh partition-bound assignment through the
  ordinary create action. Uploads and other packages without first-party trust
  evidence remain disabled audit history.

  Policy-owned rows are intentionally not cloned here. Their current
  authoritative reconcilers determine desired state independently of history.
  """
  @spec recover_automatic(keyword()) :: {:ok, map()} | {:error, term()}
  def recover_automatic(opts \\ []) when is_list(opts) do
    limit = automatic_recovery_limit(Keyword.get(opts, :limit))

    with {:ok, after_id} <- legacy_list_after_id(Keyword.get(opts, :after_id)),
         {:ok, assignments} <-
           legacy_assignments(@automatic_recovery_actor, limit + 1, after_id) do
      {page, overflow} = Enum.split(assignments, limit)

      results =
        page
        |> Enum.filter(&(&1.source == :manual))
        |> Enum.map(&recover_automatic_candidate(&1, opts))

      {:ok,
       %{
         scanned: length(page),
         manual_candidates: length(results),
         recovered: Enum.count(results, &match?({:ok, %{outcome: :recovered}}, &1)),
         deferred: Enum.count(results, &match?({:ok, %{outcome: :deferred}}, &1)),
         failed: Enum.count(results, &match?({:error, _reason}, &1)),
         more?: overflow != [],
         next_after_id: if(overflow == [], do: nil, else: page |> List.last() |> Map.get(:id))
       }}
    end
  end

  @doc """
  Classifies an assignment without inferring provenance from a live agent or an
  inventory record. Exposed for the web adapter and focused tests.
  """
  @spec classify(PluginAssignment.t() | map()) :: recovery_kind()
  def classify(%{source: :manual} = assignment) do
    if legacy_unbound?(assignment), do: :manual_reapproval, else: :not_recoverable
  end

  def classify(%{source: :policy} = assignment) do
    if legacy_unbound?(assignment) do
      policy_id = Map.get(assignment, :policy_id) || Map.get(assignment, "policy_id")

      case OwnerReference.parse(policy_id) do
        {:ok, _owner} -> :policy_reconciliation
        {:error, :invalid_policy_owner} -> :unsupported_policy_owner
      end
    else
      :not_recoverable
    end
  end

  def classify(_assignment), do: :not_recoverable

  defp recover_automatic_candidate(assignment, opts) do
    case automatic_terminal_audit(assignment.id) do
      {:ok, %PluginAssignmentRecoveryAudit{outcome: :recovered} = audit} ->
        {:ok,
         %{
           outcome: :recovered,
           legacy_assignment_id: assignment.id,
           replacement_assignment_id: audit.replacement_assignment_id,
           idempotent?: true
         }}

      {:ok, %PluginAssignmentRecoveryAudit{} = audit} ->
        {:ok,
         %{
           outcome: :deferred,
           legacy_assignment_id: assignment.id,
           reason: audit.reason
         }}

      {:ok, nil} ->
        # Run every first attempt through the transaction so terminal package
        # trust and approval failures are recorded in the immutable audit.
        # Returning them before the transaction made those rows eligible for
        # every periodic sweep despite the documented terminal-outcome rule.
        assignment.id
        |> run_recovery_transaction(@automatic_recovery_actor, opts, :automatic)
        |> normalize_automatic_recovery_result(assignment.id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_automatic_recovery_result({:ok, result}, _legacy_assignment_id),
    do: {:ok, result}

  defp normalize_automatic_recovery_result({:error, reason}, legacy_assignment_id)
       when reason in [
              :active_assignment_conflict,
              :bound_manual_assignment_conflict,
              :params_not_recoverable,
              :plugin_package_not_found,
              :plugin_package_not_approved,
              :plugin_package_not_trusted,
              :policy_assignment_requires_reconciliation
            ] do
    {:ok, %{outcome: :deferred, legacy_assignment_id: legacy_assignment_id, reason: reason}}
  end

  defp normalize_automatic_recovery_result({:error, reason}, _legacy_assignment_id),
    do: {:error, reason}

  defp automatic_terminal_audit(legacy_assignment_id) do
    case latest_recovery_audit(legacy_assignment_id) do
      {:ok, %PluginAssignmentRecoveryAudit{outcome: :recovered} = audit} ->
        {:ok, audit}

      {:ok, %PluginAssignmentRecoveryAudit{reason: reason} = audit}
      when reason in [
             :active_assignment_conflict,
             :bound_manual_assignment_conflict,
             :params_not_recoverable,
             :plugin_package_not_found,
             :plugin_package_not_approved,
             :plugin_package_not_trusted
           ] ->
        {:ok, audit}

      {:ok, _retryable_or_missing} ->
        {:ok, nil}

      {:error, _reason} = error ->
        error
    end
  end

  defp run_recovery_transaction(legacy_assignment_id, actor, opts, mode \\ :operator) do
    case Repo.transaction(fn -> recover_locked(legacy_assignment_id, actor, mode) end) do
      {:ok, {:recovered, result, replacement, notifications}} ->
        # Match the normal enabled-assignment lifecycle only after the
        # assignment and its immutable audit have committed. The replacement
        # stays internal, so encrypted params never enter the recovery API.
        Ash.Notifier.notify(notifications)
        dispatch_recovered_config(replacement, opts)
        ServiceStateRegistry.upsert_for_assignment(replacement)
        {:ok, result}

      {:ok, {:recovered, result}} ->
        # A completed recovery is idempotent. Its prior successful lifecycle
        # transition may have been interrupted after commit, so repair the
        # enabled replacement's service-state placeholder when it still exists.
        maybe_sync_idempotent_replacement(result.replacement_assignment_id, actor, opts)
        {:ok, result}

      {:ok, {:failed, reason, notifications}} ->
        Ash.Notifier.notify(notifications)
        {:error, reason}

      {:error, {:identity_changed, audit_attrs}} ->
        # The ordinary create action observed a different partition than our
        # commit preflight. The replacement was rolled back; write only the
        # redacted decision in a new transaction.
        case write_audit(audit_attrs, actor) do
          {:ok, _audit, notifications} ->
            Ash.Notifier.notify(notifications)
            {:error, :authenticated_agent_partition_changed}

          {:error, _reason} ->
            {:error, :recovery_audit_failed}
        end

      {:error, _reason} ->
        {:error, :recovery_failed}
    end
  end

  defp recover_locked(legacy_assignment_id, actor, mode) do
    case lock_assignment(legacy_assignment_id, actor) do
      {:ok, assignment} ->
        case recovered_audit(assignment.id, actor) do
          {:ok, %PluginAssignmentRecoveryAudit{} = audit} ->
            {:recovered, result_from_audit(audit)}

          {:ok, nil} ->
            recover_unlocked_legacy(assignment, actor, mode)

          {:error, _reason} ->
            Repo.rollback(:recovery_audit_lookup_failed)
        end

      {:error, :legacy_assignment_not_found} ->
        {:failed, :legacy_assignment_not_found, []}

      {:error, _reason} ->
        Repo.rollback(:legacy_assignment_lookup_failed)
    end
  end

  defp recover_unlocked_legacy(assignment, actor, mode) do
    case ensure_manual_legacy_unbound(assignment) do
      :ok -> recover_manual_legacy(assignment, actor, mode)
      {:error, {outcome, reason}} -> persist_failure(assignment, actor, outcome, reason, %{})
    end
  end

  defp recover_manual_legacy(assignment, actor, mode) do
    case resolve_authenticated_evidence(assignment.agent_uid) do
      {:ok, evidence} ->
        recover_with_evidence(assignment, actor, evidence, mode)

      {:error, {outcome, reason, observed_evidence}} ->
        persist_failure(assignment, actor, outcome, reason, observed_evidence)
    end
  end

  defp recover_with_evidence(assignment, actor, evidence, mode) do
    with {:ok, package} <- recoverable_package(assignment.plugin_package_id, actor, mode),
         {:ok, params} <- recoverable_params(assignment.params, package.config_schema || %{}),
         :ok <- ensure_no_bound_conflict(assignment, package, evidence, actor) do
      create_replacement(assignment, package, params, evidence, actor)
    else
      {:error, {outcome, reason}} ->
        persist_failure(assignment, actor, outcome, reason, evidence)
    end
  end

  defp create_replacement(assignment, package, params, evidence, actor) do
    attrs = %{
      agent_uid: assignment.agent_uid,
      plugin_package_id: package.id,
      source: :manual,
      enabled: true,
      interval_seconds: assignment.interval_seconds,
      timeout_seconds: assignment.timeout_seconds,
      params: params,
      permissions_override: assignment.permissions_override || %{},
      resources_override: assignment.resources_override || %{}
    }

    result =
      PluginAssignment
      |> Ash.Changeset.for_create(:create, attrs, actor: actor)
      |> Ash.Changeset.set_context(%{config_schema: package.config_schema || %{}})
      |> Ash.create(actor: actor, authorize?: true, return_notifications?: true)

    case result do
      {:ok, replacement, assignment_notifications}
      when replacement.partition_id == evidence.partition_id ->
        audit_attrs = audit_attrs(assignment, actor, :recovered, :reapproved, evidence)
        audit_attrs = Map.put(audit_attrs, :replacement_assignment_id, replacement.id)

        case write_audit(audit_attrs, actor) do
          {:ok, _audit, audit_notifications} ->
            {:recovered, recovery_result(assignment, replacement, evidence), replacement,
             assignment_notifications ++ audit_notifications}

          {:error, _reason} ->
            Repo.rollback(:recovery_audit_write_failed)
        end

      {:ok, replacement, _notifications} ->
        # A different live session was selected by the ordinary create action.
        # Roll back the new row before recording the safe identity-change event.
        changed_evidence = %{
          agent_id: assignment.agent_uid,
          partition_id: replacement.partition_id
        }

        Repo.rollback(
          {:identity_changed,
           audit_attrs(
             assignment,
             actor,
             :identity_mismatch,
             :authenticated_agent_partition_changed,
             changed_evidence
           )}
        )

      {:error, error} ->
        {outcome, reason} = classify_create_error(error)
        persist_failure(assignment, actor, outcome, reason, evidence)
    end
  end

  defp persist_failure(assignment, actor, outcome, reason, evidence) do
    case write_audit(audit_attrs(assignment, actor, outcome, reason, evidence), actor) do
      {:ok, _audit, notifications} -> {:failed, reason, notifications}
      {:error, _reason} -> Repo.rollback(:recovery_audit_write_failed)
    end
  end

  defp recoverable_package(package_id, actor),
    do: recoverable_package(package_id, actor, :operator)

  defp recoverable_package(package_id, actor, mode) do
    PluginPackage
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^package_id)
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, nil} -> {:error, {:package_unavailable, :plugin_package_not_found}}
      {:ok, %{status: :approved} = package} -> ensure_recovery_package_trust(package, mode)
      {:ok, %PluginPackage{}} -> {:error, {:package_unavailable, :plugin_package_not_approved}}
      {:error, _reason} -> {:error, {:package_unavailable, :plugin_package_not_found}}
    end
  end

  defp ensure_recovery_package_trust(package, :operator), do: {:ok, package}

  defp ensure_recovery_package_trust(package, :automatic) do
    if trusted_first_party_package?(package) do
      {:ok, package}
    else
      {:error, {:package_unavailable, :plugin_package_not_trusted}}
    end
  end

  defp trusted_first_party_package?(package) do
    package.source_type == :first_party and package.verification_status == "verified" and
      present?(package.content_hash) and present?(package.wasm_object_key) and
      is_map(package.signature) and map_size(package.signature) > 0
  end

  defp recoverable_params(params, schema) when is_map(params) and is_map(schema) do
    params = MapUtils.stringify_keys(params)
    schema = MapUtils.stringify_keys(schema)
    public_params = SecretRefs.public_params(params)

    with :ok <- reject_visible_secret_material(public_params),
         :ok <- validate_secret_material_shape(schema, params),
         prepared = SecretRefs.prepare_params_for_storage(schema, public_params, params),
         normalized = ConfigSchema.normalize_params(schema, prepared),
         :ok <- validate_current_schema(schema, normalized),
         :ok <- validate_current_secret_linkage(schema, normalized) do
      {:ok, normalized}
    else
      {:error, _reason} -> {:error, {:schema_invalid, :params_not_recoverable}}
    end
  end

  defp recoverable_params(_params, _schema),
    do: {:error, {:schema_invalid, :params_not_recoverable}}

  defp validate_current_schema(schema, params) do
    case ConfigSchema.validate_params(schema, params) do
      :ok -> :ok
      {:error, _errors} -> {:error, :invalid_schema_params}
    end
  end

  defp validate_current_secret_linkage(schema, params) do
    case SecretRefs.validate_secret_linkage(schema, params) do
      :ok -> :ok
      {:error, _errors} -> {:error, :invalid_secret_linkage}
    end
  end

  # Existing SecretRefs safely retains only linkage referenced by current schema
  # fields. Before using it, reject malformed material and secret refs outside
  # those fields rather than silently dropping or reinterpreting legacy input.
  defp validate_secret_material_shape(schema, params) do
    sections = secret_sections(params)

    errors =
      Enum.flat_map(sections, fn {label, section} ->
        validate_secret_section(label, schema, section)
      end)

    case errors do
      [] -> :ok
      _ -> {:error, :unsafe_secret_linkage}
    end
  end

  defp secret_sections(params) do
    base = [{:params, params}]

    if plugin_inputs_payload?(params) and is_map(Map.get(params, "template")) do
      base ++ [{:template, MapUtils.stringify_keys(Map.fetch!(params, "template"))}]
    else
      base
    end
  end

  defp validate_secret_section(_label, _schema, section) when not is_map(section),
    do: [:invalid_section]

  defp validate_secret_section(label, schema, section) do
    fields = SecretRefs.secret_ref_fields(schema)
    material = Map.get(section, "_secret_material", %{})

    with {:ok, material} <- normalize_secret_material(material),
         {:ok, expected_refs} <- validate_secret_fields(fields, section, material),
         :ok <- validate_material_keys(material, expected_refs),
         :ok <- validate_no_unmodelled_secret_refs(label, section, expected_refs) do
      []
    else
      {:error, _reason} -> [:invalid_secret_material]
    end
  end

  defp normalize_secret_material(%{} = material) do
    material = MapUtils.stringify_keys(material)

    if Enum.all?(material, fn {ref, encrypted} ->
         is_binary(ref) and String.starts_with?(ref, "secretref:") and is_binary(encrypted) and
           String.trim(encrypted) != ""
       end) do
      {:ok, material}
    else
      {:error, :malformed_material}
    end
  end

  defp normalize_secret_material(nil), do: {:ok, %{}}
  defp normalize_secret_material(_material), do: {:error, :malformed_material}

  defp validate_secret_fields(fields, section, material) do
    Enum.reduce_while(fields, {:ok, MapSet.new()}, fn field, {:ok, refs} ->
      case Map.get(section, field) do
        nil ->
          {:cont, {:ok, refs}}

        value when is_binary(value) ->
          if SecretRefs.secret_ref?(value) do
            if String.starts_with?(value, "secretref:") and not Map.has_key?(material, value) do
              {:halt, {:error, :missing_material}}
            else
              {:cont, {:ok, MapSet.put(refs, value)}}
            end
          else
            {:halt, {:error, :raw_or_invalid_secret_ref}}
          end

        _value ->
          {:halt, {:error, :raw_or_invalid_secret_ref}}
      end
    end)
  end

  defp validate_material_keys(material, expected_refs) do
    if Enum.all?(Map.keys(material), &MapSet.member?(expected_refs, &1)) do
      :ok
    else
      {:error, :orphaned_material}
    end
  end

  defp validate_no_unmodelled_secret_refs(label, section, expected_refs) do
    refs = collect_secret_refs(section, label == :params and plugin_inputs_payload?(section))

    if Enum.all?(refs, &MapSet.member?(expected_refs, &1)) do
      :ok
    else
      {:error, :unmodelled_secret_ref}
    end
  end

  defp collect_secret_refs(%{} = value, skip_template?) do
    value
    |> Map.drop(
      if(skip_template?, do: ["_secret_material", "template"], else: ["_secret_material"])
    )
    |> Map.values()
    |> Enum.flat_map(&collect_secret_refs(&1, false))
  end

  defp collect_secret_refs(value, _skip_template?) when is_list(value),
    do: Enum.flat_map(value, &collect_secret_refs(&1, false))

  defp collect_secret_refs(value, _skip_template?) when is_binary(value),
    do: if(SecretRefs.secret_ref?(value), do: [value], else: [])

  defp collect_secret_refs(_value, _skip_template?), do: []

  defp reject_visible_secret_material(params) do
    if CredentialRedactor.redact(params) == params do
      :ok
    else
      {:error, :raw_secret_material}
    end
  end

  defp plugin_inputs_payload?(params) do
    Map.get(params, "schema") == "serviceradar.plugin_inputs.v1" or Map.has_key?(params, "inputs")
  end

  defp ensure_no_bound_conflict(assignment, package, evidence, actor) do
    PluginAssignment
    |> Ash.Query.for_read(
      :by_edge_principal,
      %{agent_uid: assignment.agent_uid, partition_id: evidence.partition_id},
      actor: actor
    )
    |> Ash.read(actor: actor)
    |> case do
      {:ok, assignments} -> classify_bound_conflict(assignments, assignment, package)
      {:error, _reason} -> {:error, {:conflict, :active_assignment_conflict}}
    end
  end

  defp classify_bound_conflict(assignments, assignment, package) do
    cond do
      Enum.any?(assignments, &(&1.enabled and &1.plugin_id == package.plugin_id)) ->
        {:error, {:conflict, :active_assignment_conflict}}

      Enum.any?(assignments, fn existing ->
        existing.source == :manual and existing.id != assignment.id and
            existing.plugin_package_id == package.id
      end) ->
        {:error, {:conflict, :bound_manual_assignment_conflict}}

      true ->
        :ok
    end
  end

  defp resolve_authenticated_evidence(agent_uid) do
    case AgentCommandBus.resolve_control_session_evidence(agent_uid) do
      {:ok, evidence} when is_map(evidence) ->
        evidence = evidence_summary(evidence)

        if evidence.agent_id == agent_uid and present?(evidence.partition_id) do
          {:ok, evidence}
        else
          {:error, {:identity_mismatch, :authenticated_agent_partition_mismatch, evidence}}
        end

      {:error, _reason} ->
        {:error, {:evidence_unavailable, :authenticated_agent_partition_unavailable, %{}}}
    end
  end

  defp preview_summary(assignment) do
    base = legacy_summary(assignment)
    preview = partition_preview(assignment.agent_uid)

    base
    |> Map.put(:status, preview.state)
    |> Map.put(:authenticated_partition_id, Map.get(preview, :partition_id))
    |> maybe_put_preview_reason(preview)
  end

  defp owner_projection(%{source: :manual}, _actor) do
    %{
      kind: :manual,
      label: "Manual assignment",
      reference: nil,
      state: :available
    }
  end

  defp owner_projection(%{source: :policy, policy_id: policy_id}, actor) do
    case OwnerReference.parse(policy_id) do
      {:ok, %{kind: :plugin_target_policy} = owner} ->
        plugin_target_policy_owner_projection(owner, actor)

      {:ok, %{kind: :credential_rule} = owner} ->
        # A plugin-management user need not have credential-management access.
        # Never query the credential rule here: its normalized opaque ID and
        # purpose provide the UI enough context without disclosing credential
        # metadata through this plugin-assignment endpoint.
        %{
          kind: :credential_rule,
          label: credential_rule_label(owner.purpose),
          reference: owner.id,
          purpose: owner.purpose,
          state: :available
        }

      {:error, :invalid_policy_owner} ->
        %{
          kind: :unknown,
          label: "Unsupported historical policy owner",
          reference: nil,
          state: :unavailable
        }
    end
  end

  defp owner_projection(_assignment, _actor) do
    %{
      kind: :unknown,
      label: "Unknown assignment owner",
      reference: nil,
      state: :unavailable
    }
  end

  defp plugin_target_policy_owner_projection(owner, actor) do
    case PluginTargetPolicy.get_by_id(owner.id, actor: actor) do
      {:ok, %{name: name}} when is_binary(name) and name != "" ->
        %{
          kind: :plugin_target_policy,
          label: name,
          reference: owner.id,
          state: :available
        }

      _ ->
        %{
          kind: :plugin_target_policy,
          label: "Plugin target policy",
          reference: owner.id,
          state: :unavailable
        }
    end
  end

  defp credential_rule_label(purpose) when is_binary(purpose) and purpose != "" do
    "Credential rule (#{String.replace(purpose, "_", " ")})"
  end

  defp credential_rule_label(_purpose), do: "Credential rule"

  defp config_compatibility(assignment, actor) do
    with {:ok, package} <- recoverable_package(assignment.plugin_package_id, actor),
         {:ok, _prepared_params} <-
           recoverable_params(assignment.params, package.config_schema || %{}) do
      %{state: :compatible, reason: :current_schema_valid}
    else
      {:error, {:package_unavailable, reason}} ->
        %{state: :unavailable, reason: reason}

      {:error, {:schema_invalid, reason}} ->
        %{state: :incompatible, reason: reason}
    end
  end

  defp authenticated_partition_projection(agent_uid) do
    agent_uid
    |> partition_preview()
    |> Map.delete(:agent_uid)
  end

  defp partition_preview(agent_uid) do
    case resolve_authenticated_evidence(agent_uid) do
      {:ok, evidence} ->
        %{agent_uid: agent_uid, state: :available, partition_id: evidence.partition_id}

      {:error, {:identity_mismatch, reason, _evidence}} ->
        %{agent_uid: agent_uid, state: :mismatch, reason: reason}

      {:error, {_outcome, reason, _evidence}} ->
        %{agent_uid: agent_uid, state: :unavailable, reason: reason}
    end
  end

  defp maybe_put_preview_reason(result, %{reason: reason}), do: Map.put(result, :reason, reason)
  defp maybe_put_preview_reason(result, _preview), do: result

  defp legacy_summary(assignment) do
    recovery_kind = classify(assignment)

    %{
      legacy_assignment_id: assignment.id,
      agent_uid: assignment.agent_uid,
      plugin_id: assignment.plugin_id,
      plugin_package_id: assignment.plugin_package_id,
      source: assignment.source,
      recovery_kind: recovery_kind,
      recovery_reason: recovery_reason(recovery_kind),
      enabled: assignment.enabled,
      partition_id: nil
    }
  end

  # This is deliberately a small, allowlisted reason rather than the raw
  # legacy `policy_id`. A legacy integration-specific identifier is not proof
  # that it can be interpreted as one of the current policy owners.
  defp recovery_reason(:unsupported_policy_owner), do: :unsupported_policy_owner
  defp recovery_reason(_recovery_kind), do: nil

  # Request reads are intentionally performed only after `legacy_detail/2`
  # authorized this exact legacy assignment in the caller's current scope.
  # The projection carries no params, principal identity, owner IDs, audit
  # details, or raw replacement IDs; it is just enough for an operator to
  # understand whether the policy retry is queued or which safe terminal
  # outcome requires attention.
  defp policy_recovery_projection(%{source: :policy, id: legacy_assignment_id} = assignment) do
    if classify(assignment) == :policy_reconciliation do
      case PluginPolicyAssignmentRecoveryRequest.latest_for_legacy(
             legacy_assignment_id,
             actor: @policy_recovery_request_lookup
           ) do
        {:ok, [request | _]} ->
          %{
            state: policy_recovery_state(request.status),
            replacement_count: length(request.replacement_assignment_ids || [])
          }

        {:ok, []} ->
          nil

        {:error, _reason} ->
          %{state: :unavailable}
      end
    end
  end

  defp policy_recovery_projection(_assignment), do: nil

  # This is evaluated only after `legacy_detail/2` has loaded and authorized
  # the exact legacy assignment with the initiating actor. The projection is
  # deliberately smaller than the immutable audit row: it signals that the
  # historical manual row has already been reapproved without exposing a
  # replacement ID, actor, time, or authenticated partition.
  defp manual_recovery_projection(%{source: :manual, id: legacy_assignment_id}, actor) do
    case recovered_audit(legacy_assignment_id, actor) do
      {:ok, %PluginAssignmentRecoveryAudit{}} -> %{state: :reapproved}
      _ -> nil
    end
  end

  defp manual_recovery_projection(_assignment, _actor), do: nil

  defp policy_recovery_state(:requested), do: :queued
  defp policy_recovery_state(:executing), do: :pending
  defp policy_recovery_state(status), do: status

  defp recovery_result(legacy, replacement, evidence) do
    %{
      outcome: :recovered,
      legacy_assignment_id: legacy.id,
      replacement_assignment_id: replacement.id,
      agent_uid: replacement.agent_uid,
      authenticated_agent_id: evidence.agent_id,
      authenticated_partition_id: replacement.partition_id
    }
  end

  defp result_from_audit(audit) do
    %{
      outcome: :recovered,
      legacy_assignment_id: audit.legacy_assignment_id,
      replacement_assignment_id: audit.replacement_assignment_id,
      agent_uid: audit.agent_uid,
      authenticated_agent_id: audit.authenticated_agent_id,
      authenticated_partition_id: audit.authenticated_partition_id,
      idempotent?: true
    }
  end

  defp maybe_sync_idempotent_replacement(nil, _actor, _opts), do: :ok

  defp maybe_sync_idempotent_replacement(replacement_id, actor, opts) do
    case get_assignment(replacement_id, actor) do
      {:ok, %{enabled: true} = replacement} ->
        dispatch_recovered_config(replacement, opts)
        ServiceStateRegistry.upsert_for_assignment(replacement)

      _ ->
        :ok
    end
  end

  defp dispatch_recovered_config(%{agent_uid: agent_uid, partition_id: partition_id}, opts) do
    RecoveryConfigDispatch.dispatch_after_commit(agent_uid, partition_id, opts)
  end

  defp audit_attrs(assignment, actor, outcome, reason, evidence) do
    %{
      legacy_assignment_id: assignment.id,
      actor_id: actor_id(actor),
      actor_type: actor_type(actor),
      agent_uid: assignment.agent_uid,
      authenticated_agent_id: Map.get(evidence, :agent_id),
      authenticated_partition_id: Map.get(evidence, :partition_id),
      outcome: outcome,
      reason: reason
    }
  end

  # Audit attributes are constructed only from the locked assignment, fresh
  # control-session evidence, and the already-authorized initiating actor. The
  # persistence actor is deliberately a dedicated system principal so a plugin
  # manager cannot manufacture a recovered row and bypass idempotent recovery.
  defp write_audit(attrs, _initiating_actor) do
    PluginAssignmentRecoveryAudit
    |> Ash.Changeset.for_create(:record_recovery, attrs, actor: @recovery_audit_writer)
    |> Ash.create(
      actor: @recovery_audit_writer,
      authorize?: true,
      return_notifications?: true
    )
  end

  # Callers reach this only after they have loaded and authorized the exact
  # legacy assignment. Audit reads themselves use a named actor because raw
  # rows carry identifiers and authenticated evidence that must not be
  # enumerable by a generic plugin-management principal.
  defp recovered_audit(legacy_assignment_id, _actor) do
    PluginAssignmentRecoveryAudit
    |> Ash.Query.for_read(
      :for_legacy_assignment,
      %{legacy_assignment_id: legacy_assignment_id},
      actor: @recovery_audit_lookup
    )
    |> Ash.Query.filter(outcome == :recovered)
    |> Ash.Query.limit(1)
    |> Ash.read_one(actor: @recovery_audit_lookup)
  end

  defp latest_recovery_audit(legacy_assignment_id) do
    PluginAssignmentRecoveryAudit
    |> Ash.Query.for_read(
      :for_legacy_assignment,
      %{legacy_assignment_id: legacy_assignment_id},
      actor: @recovery_audit_lookup
    )
    |> Ash.Query.limit(1)
    |> Ash.read_one(actor: @recovery_audit_lookup)
  end

  defp lock_assignment(legacy_assignment_id, actor) do
    PluginAssignment
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^legacy_assignment_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, nil} -> {:error, :legacy_assignment_not_found}
      {:ok, assignment} -> {:ok, assignment}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_assignment(legacy_assignment_id, actor) do
    PluginAssignment
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^legacy_assignment_id)
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, nil} -> {:error, :legacy_assignment_not_found}
      {:ok, assignment} -> {:ok, assignment}
      {:error, reason} -> {:error, reason}
    end
  end

  defp legacy_assignments(actor, limit, after_id) do
    PluginAssignment
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(enabled == false and (is_nil(partition_id) or partition_id == ""))
    |> maybe_filter_after_legacy_id(after_id)
    |> Ash.Query.sort(id: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, assignments} -> {:ok, Enum.filter(assignments, &legacy_unbound?/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp legacy_list_limit(value) when is_integer(value) and value > 0,
    do: min(value, @legacy_list_max_limit)

  defp legacy_list_limit(_value), do: @legacy_list_default_limit

  defp automatic_recovery_limit(value) when is_integer(value) and value > 0,
    do: min(value, @automatic_recovery_max_limit)

  defp automatic_recovery_limit(_value), do: @automatic_recovery_default_limit

  defp legacy_list_after_id(nil), do: {:ok, nil}

  defp legacy_list_after_id(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_legacy_list_cursor}
    end
  end

  defp legacy_list_after_id(_value), do: {:error, :invalid_legacy_list_cursor}

  defp maybe_filter_after_legacy_id(query, nil), do: query
  defp maybe_filter_after_legacy_id(query, after_id), do: Ash.Query.filter(query, id < ^after_id)

  defp ensure_legacy_unbound(assignment) do
    if legacy_unbound?(assignment), do: :ok, else: {:error, :not_legacy_unbound}
  end

  defp ensure_manual_legacy_unbound(assignment) do
    cond do
      not legacy_unbound?(assignment) ->
        {:error, {:rejected, :not_legacy_unbound}}

      assignment.source == :policy ->
        {:error, {:rejected, :policy_assignment_requires_reconciliation}}

      assignment.source != :manual ->
        {:error, {:rejected, :not_legacy_unbound}}

      true ->
        :ok
    end
  end

  defp legacy_unbound?(%{enabled: false, partition_id: partition_id}) do
    not present?(partition_id)
  end

  defp legacy_unbound?(_assignment), do: false

  defp classify_create_error(%Ash.Error.Invalid{errors: errors}) do
    cond do
      Enum.any?(errors, &unavailable_evidence_error?/1) ->
        {:evidence_unavailable, :authenticated_agent_partition_unavailable}

      Enum.any?(errors, &mismatched_evidence_error?/1) ->
        {:identity_mismatch, :authenticated_agent_partition_mismatch}

      Enum.any?(errors, &active_conflict_error?/1) ->
        {:conflict, :active_assignment_conflict}

      true ->
        {:rejected, :assignment_create_failed}
    end
  end

  defp classify_create_error(_error), do: {:rejected, :assignment_create_failed}

  defp active_conflict_error?(%InvalidAttribute{message: message}) when is_binary(message) do
    String.contains?(message, "already enabled") or
      String.contains?(message, "already assigned")
  end

  defp active_conflict_error?(_error), do: false

  defp unavailable_evidence_error?(%InvalidAttribute{message: message}) when is_binary(message),
    do: String.contains?(message, "authenticated agent partition is unavailable")

  defp unavailable_evidence_error?(_error), do: false

  defp mismatched_evidence_error?(%InvalidAttribute{message: message}) when is_binary(message),
    do: String.contains?(message, "authenticated agent partition does not match")

  defp mismatched_evidence_error?(_error), do: false

  defp evidence_summary(evidence) do
    %{
      agent_id: clean_string(Map.get(evidence, :agent_id) || Map.get(evidence, "agent_id")),
      partition_id:
        clean_string(Map.get(evidence, :partition_id) || Map.get(evidence, "partition_id"))
    }
  end

  # The immutable row audit records resolved recovery decisions. This event is
  # separate because it also captures early exits before a legacy row can be
  # loaded (missing actor, RBAC denial, or confirmation denial). Its details
  # are deliberately constructed from a fixed allowlist, never from params,
  # errors, or authenticated-session evidence.
  defp write_manual_recovery_event(legacy_assignment_id, actor, result, opts) do
    {outcome, reason} = manual_recovery_audit_decision(result)
    resource_id = audit_legacy_assignment_id(legacy_assignment_id)

    details =
      %{
        legacy_assignment_id: resource_id,
        actor_id: actor_id(actor),
        outcome: outcome,
        reason: reason
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    audit_opts = [
      action: :plugin_assignment_manual_recovery,
      resource_type: "plugin_assignment_recovery",
      resource_id: resource_id,
      actor: actor,
      details: details,
      severity: manual_recovery_audit_severity(outcome),
      message: "Plugin assignment manual recovery #{outcome}"
    ]

    case audit_writer(opts) do
      {writer, writer_opts} -> writer.write_async(Keyword.merge(audit_opts, writer_opts))
      writer -> writer.write_async(audit_opts)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp manual_recovery_audit_decision({:ok, %{idempotent?: true}}),
    do: {:recovered, :already_recovered}

  defp manual_recovery_audit_decision({:ok, _result}), do: {:recovered, :reapproved}

  defp manual_recovery_audit_decision({:error, reason}) do
    Map.get(@manual_recovery_audit_decisions, reason, {:failed, :recovery_failed})
  end

  defp manual_recovery_audit_decision(_result), do: {:failed, :recovery_failed}

  defp manual_recovery_audit_severity(:recovered), do: :medium
  defp manual_recovery_audit_severity(:denied), do: :high
  defp manual_recovery_audit_severity(_outcome), do: :high

  defp audit_legacy_assignment_id(legacy_assignment_id) when is_binary(legacy_assignment_id) do
    case Ecto.UUID.cast(legacy_assignment_id) do
      {:ok, canonical_id} -> canonical_id
      :error -> "unknown"
    end
  end

  defp audit_legacy_assignment_id(_legacy_assignment_id), do: "unknown"

  defp audit_writer(opts) when is_list(opts), do: Keyword.get(opts, :audit_writer, AuditWriter)

  defp audit_writer(_opts), do: AuditWriter

  defp audit_actor(actor) when is_map(actor) do
    case actor_id(actor) do
      actor_id when is_binary(actor_id) -> %{id: actor_id}
      _ -> nil
    end
  end

  defp audit_actor(_actor), do: nil

  defp audit_actor_from_opts(opts) when is_list(opts) do
    actor =
      case Keyword.fetch(opts, :scope) do
        {:ok, scope} when is_map(scope) -> scope_value(scope, :user)
        {:ok, nil} -> Keyword.get(opts, :actor)
        {:ok, _scope} -> nil
        :error -> Keyword.get(opts, :actor)
      end

    audit_actor(actor)
  end

  defp audit_actor_from_opts(_opts), do: nil

  defp initiating_actor(opts) when is_list(opts) do
    case Keyword.fetch(opts, :scope) do
      {:ok, scope} when is_map(scope) -> initiating_scope_actor(scope)
      {:ok, nil} -> initiating_direct_actor(Keyword.get(opts, :actor))
      {:ok, _scope} -> {:error, :initiating_actor_required}
      :error -> initiating_direct_actor(Keyword.get(opts, :actor))
    end
  end

  defp initiating_actor(_opts), do: {:error, :initiating_actor_required}

  # A supplied scope is authoritative over a simultaneously supplied actor so
  # a web caller cannot accidentally carry a reconstructed or broader actor
  # alongside its current request scope.
  defp initiating_scope_actor(scope) do
    with user when is_map(user) <- scope_value(scope, :user),
         {:ok, %{user: current_user, permissions: %MapSet{} = permissions}} <-
           CurrentUserAuthority.authorize(scope, @plugins_manage_permission),
         actor = minimal_scope_actor(current_user, permissions),
         {:ok, actor} <- validate_initiating_actor(actor) do
      {:ok, actor}
    else
      {:error, :current_authority_denied} -> {:error, :authorization_denied}
      _ -> {:error, :initiating_actor_required}
    end
  end

  defp initiating_direct_actor(actor), do: validate_initiating_actor(actor)

  defp validate_initiating_actor(actor) when is_map(actor) do
    with true <- actor_type(actor) in [:user, :api_token],
         actor_id when is_binary(actor_id) <- actor_id(actor) do
      {:ok, actor}
    else
      _ -> {:error, :initiating_actor_required}
    end
  end

  defp validate_initiating_actor(_actor), do: {:error, :initiating_actor_required}

  defp minimal_scope_actor(user, permissions) do
    %{
      id: scope_value(user, :id),
      email: scope_value(user, :email),
      role: scope_value(user, :role),
      role_profile_id: scope_value(user, :role_profile_id),
      permissions: permissions
    }
  end

  defp scope_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp scope_value(_map, _key), do: nil

  defp authorize_plugins_manage(actor) do
    if ActorHasPermission.match?(actor, [permission: @plugins_manage_permission], %{}) do
      :ok
    else
      {:error, :authorization_denied}
    end
  end

  defp require_confirmation(opts) do
    if is_list(opts) and Keyword.get(opts, :confirm, false) == true,
      do: :ok,
      else: {:error, :confirmation_required}
  end

  defp actor_id(actor) when is_map(actor) do
    actor
    |> scope_value(:id)
    |> clean_string()
  end

  defp actor_id(_actor), do: nil

  defp actor_type(%{principal_type: type}) when type in [:api_token, "api_token"], do: :api_token

  defp actor_type(%{"principal_type" => type}) when type in [:api_token, "api_token"],
    do: :api_token

  defp actor_type(%{api_token_id: _id}), do: :api_token
  defp actor_type(%{"api_token_id" => _id}), do: :api_token
  defp actor_type(%{role: :system}), do: :service
  defp actor_type(%{"role" => "system"}), do: :service
  defp actor_type(_actor), do: :user

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp clean_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp clean_string(value) when is_atom(value), do: value |> Atom.to_string() |> clean_string()

  defp clean_string(value) when is_integer(value),
    do: value |> Integer.to_string() |> clean_string()

  defp clean_string(_value), do: nil
end
