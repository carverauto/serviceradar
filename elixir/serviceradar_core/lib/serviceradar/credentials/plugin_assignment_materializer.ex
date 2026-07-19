defmodule ServiceRadar.Credentials.PluginAssignmentMaterializer do
  @moduledoc """
  Materializes network credential rules into policy-derived plugin assignments.

  Credential rules own the API-key and scope decisions. This module translates
  matching rules into the existing SRQL plugin targeting path so edge agents get
  normal `serviceradar.plugin_inputs.v1` assignments without plugin-specific
  host lists.

  The module is parameterized over a
  `ServiceRadar.Credentials.CredentialProviderProfile`, which supplies the
  provider-specific constants (provider string, plugin ids, purposes), the
  credential-broker grant spec, and the stored params template. Proxmox flows
  through `ProxmoxProfile` via thin shims so its output stays byte-identical to
  the previous Proxmox-only implementation; camera providers (unifi-protect,
  axis) flow through the same generic path.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Credentials.CredentialProviderProfile
  alias ServiceRadar.Credentials.CredentialRedactor
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Credentials.ProviderProfiles.ProxmoxProfile
  alias ServiceRadar.Credentials.RuleAccessors
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Plugins.PolicyAssignmentReconciler
  alias ServiceRadar.Plugins.SecretRefs
  alias ServiceRadar.Plugins.SRQLInputResolver
  alias ServiceRadar.Plugins.ValueUtils

  require Ash.Query

  @inventory_purpose :inventory_enrichment
  @reconcile_telemetry_event [:serviceradar, :credential_rules, :reconcile]
  @policy_recovery_executor SystemActor.system(:plugin_policy_assignment_recovery_executor)

  @doc "Telemetry event emitted once per provider/purpose/agent reconcile."
  @spec reconcile_telemetry_event() :: [atom()]
  def reconcile_telemetry_event, do: @reconcile_telemetry_event

  @doc """
  Reconciles enabled Proxmox inventory credential rules that are in scope for an agent.
  """
  @spec reconcile_proxmox_inventory_for_agent(String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def reconcile_proxmox_inventory_for_agent(agent_id, opts \\ []) when is_binary(agent_id) do
    reconcile_provider_for_agent(ProxmoxProfile, agent_id, :inventory_enrichment, opts)
  end

  @doc """
  Reconciles enabled Proxmox console credential rules that are in scope for an agent.
  """
  @spec reconcile_proxmox_console_for_agent(String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def reconcile_proxmox_console_for_agent(agent_id, opts \\ []) when is_binary(agent_id) do
    reconcile_provider_for_agent(ProxmoxProfile, agent_id, :console_access, opts)
  end

  @doc """
  Reconciles enabled camera inventory credential rules (unifi-protect + axis) in scope for an agent.
  """
  @spec reconcile_camera_inventory_for_agent(String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def reconcile_camera_inventory_for_agent(agent_id, opts \\ []) when is_binary(agent_id) do
    reconcile_camera_for_agent(agent_id, :camera_inventory, opts)
  end

  @doc """
  Reconciles enabled camera stream credential rules (unifi-protect + axis) in scope for an agent.
  """
  @spec reconcile_camera_stream_for_agent(String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def reconcile_camera_stream_for_agent(agent_id, opts \\ []) when is_binary(agent_id) do
    reconcile_camera_for_agent(agent_id, :camera_stream, opts)
  end

  defp reconcile_camera_for_agent(agent_id, purpose, opts) do
    Enum.reduce_while(
      CredentialProviderProfile.camera_profiles(),
      {:ok, empty_summary()},
      fn profile, {:ok, acc} ->
        case reconcile_provider_for_agent(profile, agent_id, purpose, opts) do
          {:ok, summary} -> {:cont, {:ok, add_summaries(acc, summary)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end
    )
  end

  @doc """
  Reconciles enabled credential rules for a provider profile + purpose in scope for an agent.
  """
  @spec reconcile_provider_for_agent(module(), String.t(), atom(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def reconcile_provider_for_agent(profile, agent_id, purpose, opts \\ [])
      when is_atom(profile) and is_binary(agent_id) and is_atom(purpose) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:credential_materializer))
    result = do_reconcile_provider_for_agent(profile, agent_id, purpose, actor, opts)
    emit_reconcile_telemetry(profile, purpose, agent_id, result)
    result
  end

  @doc """
  Reconciles one *currently selected* credential rule for one agent.

  This is the narrow recovery entry point for a policy-owned legacy plugin
  assignment. It deliberately reloads the rule, its provider profile, every
  rule currently in scope, and the selection winner before it issues a grant or
  materializes an assignment. A historical policy id is therefore never enough
  to revive a rule that has since been disabled, moved out of scope, or
  superseded by a higher-priority rule.

  The entry point accepts only the named policy-recovery executor because it
  can issue a persisted `CredentialBrokerGrant`; user-facing code must first
  create a durable, re-authorized recovery request and let its restricted
  worker call this function. A generic `%{role: :system}` actor is not enough.
  """
  @spec reconcile_current_rule_for_agent(String.t(), String.t(), atom(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def reconcile_current_rule_for_agent(rule_id, agent_id, purpose, opts \\ [])

  def reconcile_current_rule_for_agent(rule_id, agent_id, purpose, opts)
      when is_binary(rule_id) and is_binary(agent_id) and is_atom(purpose) do
    case Keyword.fetch(opts, :actor) do
      {:ok, actor} ->
        if policy_recovery_executor?(actor) do
          do_reconcile_current_rule_for_agent(rule_id, agent_id, purpose, actor, opts)
        else
          {:error, :restricted_rule_recovery_requires_recovery_executor}
        end

      :error ->
        {:error, :explicit_recovery_actor_required}
    end
  end

  def reconcile_current_rule_for_agent(_rule_id, _agent_id, _purpose, _opts),
    do: {:error, :invalid_rule_recovery_scope}

  defp policy_recovery_executor?(actor) when is_map(actor) do
    actor_value(actor, :id) == @policy_recovery_executor.id and
      actor_value(actor, :role) == @policy_recovery_executor.role
  end

  defp policy_recovery_executor?(_actor), do: false

  defp actor_value(actor, key), do: Map.get(actor, key) || Map.get(actor, Atom.to_string(key))

  defp do_reconcile_current_rule_for_agent(rule_id, agent_id, purpose, actor, opts) do
    with {:ok, rule} <- current_rule(rule_id, actor),
         {:ok, provider} <- required_string(rule, [:provider, "provider"], "provider"),
         {:ok, profile} <- profile_for_provider(provider),
         true <- profile.rule_has_purpose?(rule, purpose) || {:error, :rule_purpose_mismatch},
         {:ok, rules} <- rules_for_agent_scope(profile, agent_id, purpose, actor, opts),
         {:ok, selected_rules} <- selected_rules_for_agent(profile, rules, agent_id, purpose) do
      case Enum.find(selected_rules, &(value_string(&1, [:id, "id"]) == rule_id)) do
        nil ->
          {:ok, skip_summary(:owner_not_authoritative)}

        selected_rule ->
          with {:ok, package} <- approved_plugin_package(profile.plugin_id(purpose), actor, opts) do
            reconcile_rules(
              [selected_rule],
              agent_id,
              package,
              opts
              |> Keyword.put(:actor, actor)
              |> Keyword.put(:profile, profile)
              |> Keyword.put(:purpose, purpose)
            )
          end
      end
    else
      false -> {:ok, skip_summary(:owner_not_authoritative)}
      {:error, _reason} = error -> error
    end
  end

  defp current_rule(rule_id, actor) do
    case NetworkCredentialRule.get_by_id(rule_id, actor: actor) do
      {:ok, nil} -> {:error, :rule_not_found}
      {:ok, rule} -> {:ok, rule}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_reconcile_provider_for_agent(profile, agent_id, purpose, actor, opts) do
    with {:ok, rules} <- rules_for_agent_scope(profile, agent_id, purpose, actor, opts) do
      case rules do
        [] ->
          {:ok, skip_summary(:no_matching_rules)}

        _ ->
          with {:ok, package} <-
                 approved_plugin_package(profile.plugin_id(purpose), actor, opts) do
            opts =
              opts
              |> Keyword.put(:actor, actor)
              |> Keyword.put(:purpose, purpose)
              |> Keyword.put(:profile, profile)

            reconcile_rules(rules, agent_id, package, opts)
          end
      end
    end
  end

  defp emit_reconcile_telemetry(profile, purpose, agent_id, {:ok, summary}) do
    :telemetry.execute(
      @reconcile_telemetry_event,
      summary_measurements(summary),
      %{
        provider: profile.provider(),
        purpose: purpose,
        agent_id: agent_id,
        status: :ok,
        skips: Map.get(summary, :skips, %{}),
        error: nil
      }
    )
  end

  defp emit_reconcile_telemetry(profile, purpose, agent_id, {:error, reason}) do
    :telemetry.execute(
      @reconcile_telemetry_event,
      summary_measurements(empty_summary()),
      %{
        provider: profile.provider(),
        purpose: purpose,
        agent_id: agent_id,
        status: :error,
        skips: %{},
        error: reason
      }
    )
  end

  defp summary_measurements(summary) do
    %{
      rules_matched: Map.get(summary, :rules, 0),
      targets_resolved: Map.get(summary, :resolved_inputs, 0),
      desired_assignments: Map.get(summary, :desired_assignments, 0),
      assignments_written: Map.get(summary, :upserted, 0),
      assignments_unchanged: Map.get(summary, :unchanged, 0),
      assignments_disabled: Map.get(summary, :disabled, 0)
    }
  end

  @doc """
  Enabled credential rules for a provider profile + purpose whose scope covers
  the agent.

  Used by assignment-time credential coverage checks: it answers "would the
  materializer feed this agent for this provider/purpose right now?" without
  materializing anything or issuing grants. Rules can be injected via
  `opts[:rules]` for database-free checks.
  """
  @spec covering_rules_for_agent(module(), String.t(), atom(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def covering_rules_for_agent(profile, agent_id, purpose, opts \\ [])
      when is_atom(profile) and is_binary(agent_id) and is_atom(purpose) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:credential_coverage))

    with {:ok, rules} <- rules_for_agent_scope(profile, agent_id, purpose, actor, opts) do
      {:ok, Enum.filter(rules, &(rule_enabled?(&1) and scope_allows_agent?(&1, agent_id)))}
    end
  end

  @doc """
  Dry-runs a credential rule: renders what the rule would materialize NOW.

  Returns the resolved SRQL target list (bounded by `opts[:target_limit]`,
  default 50) plus, per eligible purpose, the stored params template with
  secret material redacted. Secret refs are preserved (they are references, not
  material); the credential-broker grant is ephemeral — no grant is persisted
  and no secret is ever resolved.

  Options: `:actor`, `:resolver` (default `SRQLInputResolver`),
  `:target_limit`, `:agent_id` (defaults to the rule's agent scope value),
  `:plugin_package` (skip the approved-package lookup), `:username_resolver`.
  """
  @spec dry_run_rule(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def dry_run_rule(rule, opts \\ []) when is_map(rule) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:credential_rule_dry_run))
    resolver = Keyword.get(opts, :resolver, SRQLInputResolver)
    target_limit = Keyword.get(opts, :target_limit, 50)

    opts =
      opts
      |> Keyword.put(:actor, actor)
      |> Keyword.put(:grant_issuer, &issue_ephemeral_test_grant/1)

    with {:ok, provider} <- required_string(rule, [:provider, "provider"], "provider"),
         {:ok, profile} <- profile_for_provider(provider),
         {:ok, input_defs} <- input_defs_for_rule(rule, nil),
         {:ok, resolved_inputs} <- resolver.resolve(input_defs, opts),
         {:ok, purposes} <- dry_run_purposes(profile, rule, actor, opts) do
      {:ok,
       %{
         rule_id: value_string(rule, [:id, "id"]),
         provider: provider,
         target_query: value_string(rule, [:target_query, "target_query"]),
         targets: bounded_targets(resolved_inputs, target_limit, rule),
         purposes: purposes
       }}
    end
  end

  defp profile_for_provider(provider) do
    case CredentialProviderProfile.profile_for(provider) do
      {:ok, profile} -> {:ok, profile}
      :error -> {:error, {:unknown_credential_provider, provider}}
    end
  end

  defp dry_run_purposes(profile, rule, actor, opts) do
    agent_id = dry_run_agent_id(rule, opts)

    profile.purposes()
    |> Enum.filter(&profile.rule_has_purpose?(rule, &1))
    |> Enum.reduce_while({:ok, []}, fn purpose, {:ok, acc} ->
      case dry_run_purpose(profile, rule, purpose, agent_id, actor, opts) do
        {:ok, entry} -> {:cont, {:ok, acc ++ [entry]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp dry_run_agent_id(rule, opts) do
    explicit = Keyword.get(opts, :agent_id)

    if is_binary(explicit) and explicit != "" do
      explicit
    else
      rule_scope_agent(rule) || "dry-run-agent"
    end
  end

  defp rule_scope_agent(rule) do
    case {raw_rule_value(rule, [:scope_type, "scope_type"]),
          value_string(rule, [:scope_value, "scope_value"])} do
      {scope, value} when scope in [:agent, "agent"] and is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp dry_run_purpose(profile, rule, purpose, agent_id, actor, opts) do
    {package, package_found?} =
      case approved_plugin_package(profile.plugin_id(purpose), actor, opts) do
        {:ok, package} -> {package, true}
        {:error, _reason} -> {%{id: "missing-approved-package"}, false}
      end

    with {:ok, policy} <- policy_for_rule(profile, rule, package, purpose, agent_id, actor, opts) do
      {:ok,
       %{
         purpose: purpose,
         plugin_id: profile.plugin_id(purpose),
         policy_id: policy.policy_id,
         package_found?: package_found?,
         enabled: policy.enabled,
         interval_seconds: policy.interval_seconds,
         timeout_seconds: policy.timeout_seconds,
         params_template: redacted_template(policy.params_template)
       }}
    end
  end

  defp redacted_template(template) do
    template
    |> CredentialRedactor.redact()
    |> mask_dry_run_grant()
  end

  defp mask_dry_run_grant(%{"credential_broker" => %{} = grant} = template) do
    Map.put(
      template,
      "credential_broker",
      Map.put(grant, "grant_id", "(issued at materialization)")
    )
  end

  defp mask_dry_run_grant(template), do: template

  defp bounded_targets(resolved_inputs, limit, rule) do
    rows =
      resolved_inputs
      |> Enum.flat_map(fn input ->
        ValueUtils.list_value(input, [:rows, "rows"]) || []
      end)
      |> Enum.filter(&target_in_rule_scope?(&1, rule))

    total = length(rows)

    %{total: total, sample: Enum.take(rows, limit), truncated?: total > limit}
  end

  defp target_in_rule_scope?(row, rule) when is_map(row) do
    case {raw_rule_value(rule, [:scope_type, "scope_type"]),
          value_string(rule, [:scope_value, "scope_value"])} do
      {scope, value} when scope in [:agent, "agent"] ->
        case value_string(row, [:agent_id, "agent_id", :agent_uid, "agent_uid"]) do
          nil -> true
          "" -> true
          row_scope -> row_scope == value
        end

      {scope, value} when scope in [:gateway, "gateway"] ->
        value_string(row, [:gateway_id, "gateway_id"]) == value

      {scope, value} when scope in [:partition, "partition"] ->
        value_string(row, [:partition_id, "partition_id", :partition, "partition", :site, "site"]) ==
          value

      _ ->
        false
    end
  end

  defp target_in_rule_scope?(_row, _rule), do: false

  @doc """
  Reconciles already-loaded credential rules.

  This is public so workers/tests can inject a package and avoid a database round
  trip when the surrounding orchestration already has the records loaded.
  """
  @spec reconcile_rules([map()], String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile_rules(rules, agent_id, package, opts \\ [])
      when is_list(rules) and is_binary(agent_id) and is_map(package) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:credential_rule_reconcile))
    reconciler = Keyword.get(opts, :reconciler, PolicyAssignmentReconciler)
    profile = Keyword.get(opts, :profile, ProxmoxProfile)
    purpose = Keyword.get(opts, :purpose, @inventory_purpose)

    with {:ok, selected_rules} <- selected_rules_for_agent(profile, rules, agent_id, purpose) do
      Enum.reduce_while(selected_rules, {:ok, empty_summary()}, fn rule, {:ok, acc} ->
        case reconcile_rule(profile, rule, agent_id, package, purpose, actor, reconciler, opts) do
          {:ok, result} ->
            {:cont, {:ok, merge_summary(acc, result)}}

          {:error, reason} when profile == ProxmoxProfile ->
            if stable_policy_rejection?(reason) do
              {:cont, {:ok, merge_summary(acc, skip_summary(reason))}}
            else
              {:halt, {:error, reason}}
            end

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp reconcile_rule(profile, rule, agent_id, package, purpose, actor, reconciler, opts) do
    with :ok <- validate_rule(profile, purpose, rule),
         {:ok, policy} <- policy_for_rule(profile, rule, package, purpose, agent_id, actor, opts),
         {:ok, input_defs} <- input_defs_for_rule(rule, purpose) do
      reconcile_opts =
        opts
        |> Keyword.put(:actor, actor)
        |> Keyword.put(:chunk_size, metadata_int(rule, "chunk_size", 100))
        |> Keyword.put(:target_agent_uid, agent_id)
        # A policy id is shared by every agent covered by a credential rule.
        # This invocation is for one agent only, so stale-row retraction must
        # not disable assignments owned by another agent in the same rule.
        |> Keyword.put(:agent_scope, [agent_id])

      reconciler.reconcile(policy, input_defs, reconcile_opts)
    end
  end

  defp validate_rule(profile, purpose, rule) do
    if function_exported?(profile, :validate_rule, 2) do
      profile.validate_rule(purpose, rule)
    else
      :ok
    end
  end

  defp stable_policy_rejection?(reason) do
    reason in [
      :proxmox_tls_verification_required,
      :proxmox_ssh_host_key_verification_required,
      :unsupported_proxmox_console_auth_method
    ]
  end

  defp policy_for_rule(profile, rule, package, purpose, agent_id, actor, opts) do
    with {:ok, rule_id} <- required_string(rule, [:id, "id"], "id"),
         {:ok, secret_id} <- required_string(rule, [:secret_id, "secret_id"], "secret_id"),
         {:ok, package_id} <- required_string(package, [:id, "id"], "plugin package id"),
         {:ok, params_template} <-
           build_params_template(profile, rule, secret_id, purpose, agent_id, actor, opts) do
      {:ok,
       %{
         policy_id: policy_id_for_rule(rule_id, purpose),
         policy_version: rule_version(rule),
         plugin_package_id: package_id,
         params_template: params_template,
         enabled: rule_enabled?(rule),
         interval_seconds: metadata_int(rule, "interval_seconds", 300),
         timeout_seconds: metadata_int(rule, "timeout_seconds", 30)
       }}
    end
  end

  defp input_defs_for_rule(rule, _purpose) do
    with {:ok, query} <- required_string(rule, [:target_query, "target_query"], "target_query") do
      {:ok, [%{name: "targets", entity: "devices", query: query}]}
    end
  end

  # Issues the credential-broker grant for the profile/purpose, resolves the
  # public (non-secret) username when the profile requires it, then delegates to
  # the profile to build the stored params template embedding the grant payload.
  defp build_params_template(profile, rule, secret_id, purpose, agent_id, actor, opts) do
    {grant_attrs, extras} = profile.grant_spec(purpose, rule, secret_id, agent_id)

    with {:ok, grant} <- issue_grant(grant_attrs, actor, opts, extras),
         {:ok, username} <-
           maybe_resolve_username(profile, purpose, rule, secret_id, actor, opts) do
      ctx = %{
        grant: grant,
        secret_ref: SecretRefs.network_credential_ref(secret_id),
        username: username
      }

      profile.params_template(purpose, rule, secret_id, ctx)
    end
  end

  defp maybe_resolve_username(profile, purpose, rule, secret_id, actor, opts) do
    if profile.resolve_username?(purpose, rule) do
      resolver = Keyword.get(opts, :username_resolver, &default_username_resolver/2)
      resolver.(secret_id, actor)
    else
      {:ok, nil}
    end
  end

  defp default_username_resolver(secret_id, actor) do
    case NetworkCredentialSecret.get_by_id(secret_id, actor: actor) do
      {:ok, nil} -> {:ok, nil}
      {:ok, secret} -> {:ok, value_string(secret, [:username, "username"])}
      {:error, reason} -> {:error, reason}
    end
  end

  defp issue_grant(attrs, actor, opts, extras) do
    issuer = Keyword.get(opts, :grant_issuer, default_grant_issuer(actor))

    case issuer.(attrs) do
      {:ok, %{} = grant} -> {:ok, CredentialBrokerGrant.to_payload(grant, extras)}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_credential_broker_grant_issuer_result, other}}
    end
  end

  defp default_grant_issuer(actor) do
    if SystemActor.system_actor?(actor) do
      &issue_persisted_grant(&1, actor)
    else
      &issue_ephemeral_test_grant/1
    end
  end

  defp issue_persisted_grant(attrs, actor) do
    attrs
    |> CredentialBrokerGrant.issue_attrs()
    |> CredentialBrokerGrant.issue_grant(actor: actor)
  end

  defp issue_ephemeral_test_grant(attrs) do
    grant =
      attrs
      |> CredentialBrokerGrant.issue_attrs()
      |> Map.put(:id, "test-grant-#{System.unique_integer([:positive])}")

    {:ok, grant}
  end

  defp rules_for_agent_scope(profile, agent_id, purpose, actor, opts) do
    case Keyword.fetch(opts, :rules) do
      {:ok, rules} ->
        # Mirror the loaded path, which is provider-scoped via
        # `list_enabled_for_scope/4`: camera reconciles iterate every camera
        # profile, so injected rules must not leak across providers.
        {:ok,
         Enum.filter(
           rules,
           &(rule_matches_provider?(&1, profile) and profile.rule_has_purpose?(&1, purpose))
         )}

      :error ->
        scopes = agent_scopes(agent_id, actor)

        scopes
        |> Enum.reduce_while({:ok, []}, fn {scope_type, scope_value}, {:ok, acc} ->
          case NetworkCredentialRule.list_enabled_for_scope(
                 profile.provider(),
                 scope_type,
                 scope_value,
                 actor: actor
               ) do
            {:ok, rules} ->
              {:cont, {:ok, acc ++ Enum.filter(rules, &profile.rule_has_purpose?(&1, purpose))}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, rules} -> {:ok, Enum.uniq_by(rules, &value_string(&1, [:id, "id"]))}
          error -> error
        end
    end
  end

  defp rule_matches_provider?(rule, profile) do
    RuleAccessors.value_string(rule, [:provider, "provider"]) == profile.provider()
  end

  defp selected_rules_for_agent(profile, rules, agent_id, purpose) do
    rules
    |> Enum.filter(
      &(profile.rule_has_purpose?(&1, purpose) and rule_enabled?(&1) and
          scope_allows_agent?(&1, agent_id))
    )
    |> Enum.sort_by(&{rule_priority(&1), value_string(&1, [:inserted_at, "inserted_at"]) || ""})
    |> collapse_by_target_query()
  end

  defp collapse_by_target_query(rules) do
    rules
    |> Enum.group_by(&value_string(&1, [:target_query, "target_query"]))
    |> Enum.reduce_while({:ok, []}, fn
      {nil, grouped}, {:ok, acc} ->
        {:cont, {:ok, acc ++ grouped}}

      {query, grouped}, {:ok, acc} ->
        case selected_rule_for_query(query, grouped) do
          {:ok, rule} -> {:cont, {:ok, acc ++ [rule]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
    end)
  end

  defp selected_rule_for_query(query, [winner | _] = rules) do
    priority = rule_priority(winner)
    equal_priority = Enum.filter(rules, &(rule_priority(&1) == priority))

    if length(equal_priority) > 1 do
      {:error, {:equal_priority_credential_rule_conflict, query, priority}}
    else
      {:ok, winner}
    end
  end

  defp approved_plugin_package(plugin_id, actor, opts) do
    case Keyword.fetch(opts, :plugin_package) do
      {:ok, package} ->
        {:ok, package}

      :error ->
        PluginPackage
        |> Ash.Query.for_read(:approved, %{}, actor: actor)
        |> Ash.Query.filter(plugin_id == ^plugin_id)
        |> Ash.read(actor: actor)
        |> case do
          {:ok, packages} when is_list(packages) and packages != [] ->
            package = Enum.max_by(packages, &package_sort_key/1)
            {:ok, package}

          {:ok, []} ->
            {:error, {:plugin_package_not_found, plugin_id}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp package_sort_key(package) do
    {
      semver_sort_key(value_string(package, [:version, "version"])),
      timestamp_sort_key(ValueUtils.raw_value(package, [:imported_at, "imported_at"])),
      timestamp_sort_key(ValueUtils.raw_value(package, [:approved_at, "approved_at"])),
      timestamp_sort_key(ValueUtils.raw_value(package, [:inserted_at, "inserted_at"]))
    }
  end

  defp semver_sort_key(version) when is_binary(version) do
    case Regex.run(~r/^v?(\d+)\.(\d+)\.(\d+)/, version) do
      [_match, major, minor, patch] ->
        {String.to_integer(major), String.to_integer(minor), String.to_integer(patch), version}

      _ ->
        {-1, -1, -1, version}
    end
  end

  defp semver_sort_key(_version), do: {-1, -1, -1, ""}

  defp timestamp_sort_key(%DateTime{} = timestamp), do: DateTime.to_unix(timestamp, :microsecond)

  defp timestamp_sort_key(%NaiveDateTime{} = timestamp),
    do: NaiveDateTime.to_gregorian_seconds(timestamp)

  defp timestamp_sort_key(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} -> timestamp_sort_key(datetime)
      _ -> 0
    end
  end

  defp timestamp_sort_key(_timestamp), do: 0

  defp agent_scopes(agent_id, actor) do
    agent = load_agent(agent_id, actor)

    [
      {:agent, agent_id},
      {:gateway, agent && value_string(agent, [:gateway_id, "gateway_id"])},
      {:partition, agent_partition(agent_id, agent)}
    ]
    |> Enum.reject(fn {_type, value} -> ValueUtils.blank_string?(value) end)
    |> Enum.uniq()
  end

  defp load_agent(agent_id, actor) do
    case Agent.get_by_uid(agent_id, actor: actor) do
      {:ok, %Agent{} = agent} -> agent
      _ -> nil
    end
  end

  defp agent_partition(agent_id, agent) do
    # A persisted Agent row can represent a later re-enrollment of the same UID
    # and is not proof for this operation. Only live registry metadata stamped
    # by the authenticated control session may select a partition-scoped rule.
    _ = agent
    registry_partition(agent_id)
  end

  defp registry_partition(agent_id) do
    case AgentCommandBus.resolve_control_session_evidence(agent_id) do
      {:ok, %{agent_id: ^agent_id, partition_id: partition_id}}
      when is_binary(partition_id) and partition_id != "" ->
        partition_id

      _missing_or_ambiguous ->
        nil
    end
  end

  defp policy_id_for_rule(rule_id, @inventory_purpose), do: "network-credential-rule:#{rule_id}"
  defp policy_id_for_rule(rule_id, purpose), do: "network-credential-rule:#{rule_id}:#{purpose}"

  defp rule_enabled?(rule) do
    case raw_rule_value(rule, [:enabled, "enabled"]) do
      value when is_boolean(value) -> value
      _ -> true
    end
  end

  defp scope_allows_agent?(rule, agent_id) do
    case {raw_rule_value(rule, [:scope_type, "scope_type"]),
          value_string(rule, [:scope_value, "scope_value"])} do
      {scope, value} when scope in [:agent, "agent"] -> value in [nil, "", agent_id]
      _ -> true
    end
  end

  defp rule_priority(rule) do
    ValueUtils.int_value(rule, [:priority, "priority"], 100)
  end

  defp rule_version(rule) do
    timestamp =
      ValueUtils.raw_value(rule, [:updated_at, "updated_at"]) ||
        ValueUtils.raw_value(rule, [:inserted_at, "inserted_at"])

    case timestamp do
      %DateTime{} -> max(DateTime.to_unix(timestamp, :second), 1)
      _ -> 1
    end
  end

  defp metadata_int(rule, key, default) do
    RuleAccessors.metadata_int(rule, key, default)
  end

  defp value_string(map, keys), do: RuleAccessors.value_string(map, keys)

  defp raw_rule_value(map, keys) when is_map(map) do
    Enum.reduce_while(keys, nil, fn key, _acc ->
      if Map.has_key?(map, key) do
        {:halt, Map.get(map, key)}
      else
        {:cont, nil}
      end
    end)
  end

  defp required_string(map, keys, label) do
    case value_string(map, keys) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_required_field, label}}
    end
  end

  defp empty_summary do
    %{
      rules: 0,
      resolved_inputs: 0,
      desired_assignments: 0,
      upserted: 0,
      unchanged: 0,
      disabled: 0,
      skips: %{}
    }
  end

  defp skip_summary(reason) do
    %{empty_summary() | skips: %{reason => 1}}
  end

  defp merge_skips(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _reason, a, b -> a + b end)
  end

  defp merge_summary(acc, result) do
    %{
      rules: acc.rules + 1,
      resolved_inputs: acc.resolved_inputs + Map.get(result, :resolved_inputs, 0),
      desired_assignments: acc.desired_assignments + Map.get(result, :desired_assignments, 0),
      upserted: acc.upserted + Map.get(result, :upserted, 0),
      unchanged: acc.unchanged + Map.get(result, :unchanged, 0),
      disabled: acc.disabled + Map.get(result, :disabled, 0),
      skips: merge_skips(acc.skips, Map.get(result, :skips, %{}))
    }
  end

  defp add_summaries(acc, summary) do
    %{
      rules: acc.rules + Map.get(summary, :rules, 0),
      resolved_inputs: acc.resolved_inputs + Map.get(summary, :resolved_inputs, 0),
      desired_assignments: acc.desired_assignments + Map.get(summary, :desired_assignments, 0),
      upserted: acc.upserted + Map.get(summary, :upserted, 0),
      unchanged: acc.unchanged + Map.get(summary, :unchanged, 0),
      disabled: acc.disabled + Map.get(summary, :disabled, 0),
      skips: merge_skips(Map.get(acc, :skips, %{}), Map.get(summary, :skips, %{}))
    }
  end
end
