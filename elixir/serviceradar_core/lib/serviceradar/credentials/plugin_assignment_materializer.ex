defmodule ServiceRadar.Credentials.PluginAssignmentMaterializer do
  @moduledoc """
  Materializes network credential rules into policy-derived plugin assignments.

  Credential rules own the API-key and scope decisions. This module translates
  matching rules into the existing SRQL plugin targeting path so edge agents get
  normal `serviceradar.plugin_inputs.v1` assignments without plugin-specific
  host lists.

  Provider names, auth methods, purposes, plugin routes, broker grants, and
  parameter templates come exclusively from approved plugin package manifests.
  Core interprets the validated bounded descriptor and contains no provider
  registry or provider-specific materialization modules.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Credentials.CredentialIntegration
  alias ServiceRadar.Credentials.CredentialRedactor
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Credentials.RuleAccessors
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Plugins.IntegrationCatalog
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Plugins.PolicyAssignmentReconciler
  alias ServiceRadar.Plugins.SRQLInputResolver
  alias ServiceRadar.Plugins.ValueUtils

  require Ash.Query

  @reconcile_telemetry_event [:serviceradar, :credential_rules, :reconcile]
  @policy_recovery_executor SystemActor.system(:plugin_policy_assignment_recovery_executor)

  @doc "Telemetry event emitted once per provider/purpose/agent reconcile."
  @spec reconcile_telemetry_event() :: [atom()]
  def reconcile_telemetry_event, do: @reconcile_telemetry_event

  @doc "Reconciles every package-declared target-policy integration for one agent."
  @spec reconcile_all_for_agent(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile_all_for_agent(agent_id, opts \\ []) when is_binary(agent_id) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:credential_materializer))

    with {:ok, profiles} <- target_policy_profiles(actor, opts) do
      Enum.reduce_while(profiles, {:ok, empty_summary()}, fn profile, {:ok, acc} ->
        # The inner reduce_while returns {:ok, acc} | {:error, reason}, which are not
        # valid reduce_while accumulators. Returning it directly made the *outer*
        # reduce_while hand {:ok, acc} to the Enumerable protocol, which only accepts
        # :cont / :halt / :suspend -- a FunctionClauseError in Enumerable.List.reduce/3.
        # An empty catalog hid this for as long as it existed: with no profiles the
        # callback never ran, so the crash only appeared once a package was approved.
        profile
        |> CredentialIntegration.purposes()
        |> Enum.reduce_while({:ok, acc}, fn purpose, {:ok, nested_acc} ->
          case reconcile_provider_for_agent(profile, agent_id, purpose, opts) do
            {:ok, summary} -> {:cont, {:ok, add_summaries(nested_acc, summary)}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, merged} -> {:cont, {:ok, merged}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  @doc """
  Reconciles enabled credential rules for a provider profile + purpose in scope for an agent.
  """
  @spec reconcile_provider_for_agent(
          map() | String.t(),
          String.t(),
          String.t() | atom(),
          keyword()
        ) ::
          {:ok, map()} | {:error, term()}
  def reconcile_provider_for_agent(profile_or_provider, agent_id, purpose, opts \\ [])
      when (is_map(profile_or_provider) or is_binary(profile_or_provider)) and is_binary(agent_id) and
             (is_binary(purpose) or is_atom(purpose)) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:credential_materializer))
    purpose = to_string(purpose)

    with {:ok, profile} <- resolve_profile(profile_or_provider, actor, opts) do
      result = do_reconcile_provider_for_agent(profile, agent_id, purpose, actor, opts)
      emit_reconcile_telemetry(profile, purpose, agent_id, result)
      result
    end
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
  @spec reconcile_current_rule_for_agent(String.t(), String.t(), String.t() | atom(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def reconcile_current_rule_for_agent(rule_id, agent_id, purpose, opts \\ [])

  def reconcile_current_rule_for_agent(rule_id, agent_id, purpose, opts)
      when is_binary(rule_id) and is_binary(agent_id) and (is_binary(purpose) or is_atom(purpose)) do
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
    purpose = to_string(purpose)

    with {:ok, rule} <- current_rule(rule_id, actor),
         {:ok, provider} <- required_string(rule, [:provider, "provider"], "provider"),
         {:ok, profile} <- profile_for_provider(provider, actor, opts),
         true <-
           CredentialIntegration.rule_has_purpose?(profile, rule, purpose) ||
             {:error, :rule_purpose_mismatch},
         {:ok, rules} <- rules_for_agent_scope(profile, agent_id, purpose, actor, opts),
         {:ok, selected_rules} <- selected_rules_for_agent(profile, rules, agent_id, purpose) do
      case Enum.find(selected_rules, &(value_string(&1, [:id, "id"]) == rule_id)) do
        nil ->
          {:ok, skip_summary(:owner_not_authoritative)}

        selected_rule ->
          reconcile_selected_rules(
            [selected_rule],
            agent_id,
            nil,
            profile,
            purpose,
            actor,
            opts
          )
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
          reconcile_selected_rules(rules, agent_id, nil, profile, purpose, actor, opts)
      end
    end
  end

  defp emit_reconcile_telemetry(profile, purpose, agent_id, {:ok, summary}) do
    :telemetry.execute(
      @reconcile_telemetry_event,
      summary_measurements(summary),
      %{
        provider: CredentialIntegration.provider(profile),
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
        provider: CredentialIntegration.provider(profile),
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
  @spec covering_rules_for_agent(map() | String.t(), String.t(), String.t() | atom(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def covering_rules_for_agent(profile_or_provider, agent_id, purpose, opts \\ [])
      when (is_map(profile_or_provider) or is_binary(profile_or_provider)) and is_binary(agent_id) and
             (is_binary(purpose) or is_atom(purpose)) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:credential_coverage))
    purpose = to_string(purpose)

    with {:ok, profile} <- resolve_profile(profile_or_provider, actor, opts),
         {:ok, rules} <- rules_for_agent_scope(profile, agent_id, purpose, actor, opts) do
      {:ok,
       Enum.filter(
         rules,
         &(rule_enabled?(&1) and scope_allows_agent?(&1, agent_id) and
             rule_runs_on_agent?(profile, &1, purpose, agent_id))
       )}
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
         {:ok, profile} <- profile_for_provider(provider, actor, opts),
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

  defp dry_run_purposes(profile, rule, actor, opts) do
    agent_id = dry_run_agent_id(rule, opts)

    profile
    |> CredentialIntegration.purposes()
    |> Enum.filter(&CredentialIntegration.rule_has_purpose?(profile, rule, &1))
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
    with {:ok, consumer} <- CredentialIntegration.consumer_for_rule(profile, rule, purpose) do
      {package, package_found?} =
        case approved_plugin_package(CredentialIntegration.plugin_id(consumer), actor, opts) do
          {:ok, package} -> {package, true}
          {:error, _reason} -> {%{id: "missing-approved-package"}, false}
        end

      with {:ok, policy} <-
             policy_for_rule(consumer, rule, package, purpose, agent_id, actor, opts) do
        {:ok,
         %{
           purpose: purpose,
           plugin_id: CredentialIntegration.plugin_id(consumer),
           policy_id: policy.policy_id,
           package_found?: package_found?,
           enabled: policy.enabled,
           interval_seconds: policy.interval_seconds,
           timeout_seconds: policy.timeout_seconds,
           params_template: redacted_template(policy.params_template)
         }}
      end
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

    with {:ok, profile} <- required_profile(opts),
         {:ok, purpose} <- required_purpose(opts) do
      reconcile_selected_rules(rules, agent_id, package, profile, purpose, actor, opts)
    end
  end

  defp reconcile_selected_rules(rules, agent_id, package, profile, purpose, actor, opts) do
    reconciler = Keyword.get(opts, :reconciler, PolicyAssignmentReconciler)

    with {:ok, selected_rules} <- selected_rules_for_agent(profile, rules, agent_id, purpose) do
      Enum.reduce_while(selected_rules, {:ok, empty_summary()}, fn rule, {:ok, acc} ->
        case CredentialIntegration.consumer_for_rule(profile, rule, purpose) do
          {:ok, consumer} ->
            reconcile_selected_rule(
              consumer,
              rule,
              agent_id,
              package,
              profile,
              purpose,
              actor,
              reconciler,
              acc,
              opts
            )

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp reconcile_selected_rule(
         consumer,
         rule,
         agent_id,
         package,
         profile,
         purpose,
         actor,
         reconciler,
         acc,
         opts
       ) do
    if single_instance_owner?(consumer, rule, agent_id) do
      case resolve_consumer_package(package, consumer, actor, opts) do
        {:ok, resolved_package} ->
          case reconcile_rule(
                 profile,
                 consumer,
                 rule,
                 agent_id,
                 resolved_package,
                 purpose,
                 actor,
                 reconciler,
                 opts
               ) do
            {:ok, result} -> {:cont, {:ok, merge_summary(acc, result)}}
            {:error, reason} -> maybe_skip_policy_rejection(consumer, reason, acc)
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    else
      {:cont, {:ok, merge_summary(acc, skip_summary(:single_target_rule_not_agent_scoped))}}
    end
  end

  # A `single` consumer does the rule's whole job in one run, so exactly one
  # agent may run it. This function is reconciled per agent, and a gateway- or
  # partition-scoped rule is in scope for every agent underneath it, so without
  # this the rule would be delivered once per agent -- for NetBox, one complete
  # /api/dcim/devices/ walk and one complete DeviceDiscovery snapshot each, all
  # under the same source_instance. Core does not elect a runner instead:
  # whether an agent can reach the instance is not something core knows, so the
  # rule has to name it. Approved manifests can no longer offer a wider scope
  # (`IntegrationDescriptor.validate_single_cardinality_scope_types/4`); this
  # covers rows written before that, or by something other than the rule form.
  defp single_instance_owner?(consumer, rule, agent_id) do
    not CredentialIntegration.single_target_cardinality?(consumer) or
      rule_scope_agent(rule) == agent_id
  end

  defp rule_runs_on_agent?(profile, rule, purpose, agent_id) do
    case CredentialIntegration.consumer_for_rule(profile, rule, purpose) do
      {:ok, consumer} -> single_instance_owner?(consumer, rule, agent_id)
      {:error, _reason} -> true
    end
  end

  defp reconcile_rule(
         profile,
         consumer,
         rule,
         agent_id,
         package,
         purpose,
         actor,
         reconciler,
         opts
       ) do
    with :ok <- CredentialIntegration.validate_rule(profile, consumer, rule),
         {:ok, policy} <-
           policy_for_rule(consumer, rule, package, purpose, agent_id, actor, opts),
         {:ok, input_defs} <- input_defs_for_rule(rule, purpose) do
      # A `target_cardinality: single` consumer syncs the rule's own endpoint,
      # not the resolved targets, so chunking it would run one complete sync
      # per chunk against the same base URL. The manifest declares that; the
      # rule's chunk_size metadata must not be able to override it.
      single_assignment? = CredentialIntegration.single_target_cardinality?(consumer)

      reconcile_opts =
        opts
        |> Keyword.put(:actor, actor)
        |> Keyword.put(:chunk_size, metadata_int(rule, "chunk_size", 100))
        |> Keyword.put(:single_assignment, single_assignment?)
        |> Keyword.put(:target_agent_uid, agent_id)
        # A policy id is shared by every agent covered by a credential rule.
        # This invocation is for one agent only, so stale-row retraction must
        # not disable assignments owned by another agent in the same rule.
        |> Keyword.put(:agent_scope, [agent_id])

      reconciler.reconcile(policy, input_defs, reconcile_opts)
    end
  end

  defp maybe_skip_policy_rejection(consumer, reason, acc) do
    if CredentialIntegration.failure_mode(consumer) == "skip" and policy_rejection?(reason) do
      {:cont, {:ok, merge_summary(acc, skip_summary(reason))}}
    else
      {:halt, {:error, reason}}
    end
  end

  defp policy_rejection?(reason) do
    reason in [
      :credential_auth_method_not_allowed,
      :credential_tls_policy_not_allowed,
      :credential_ssh_host_key_policy_not_allowed
    ]
  end

  defp policy_for_rule(consumer, rule, package, purpose, agent_id, actor, opts) do
    with {:ok, rule_id} <- required_string(rule, [:id, "id"], "id"),
         {:ok, secret_id} <- required_string(rule, [:secret_id, "secret_id"], "secret_id"),
         {:ok, package_id} <- required_string(package, [:id, "id"], "plugin package id"),
         {:ok, params_template} <-
           build_params_template(consumer, rule, secret_id, agent_id, actor, opts) do
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

  defp build_params_template(consumer, rule, secret_id, agent_id, actor, opts) do
    with {:ok, username} <- maybe_resolve_username(consumer, secret_id, actor, opts),
         {:ok, {grant_attrs, extras}} <-
           CredentialIntegration.grant_spec(consumer, rule, secret_id, agent_id, username),
         {:ok, grant} <- issue_grant(grant_attrs, actor, opts, extras) do
      CredentialIntegration.params_template(consumer, rule, secret_id, grant, username)
    end
  end

  defp maybe_resolve_username(consumer, secret_id, actor, opts) do
    if CredentialIntegration.requires_public_username?(consumer) do
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
        # `list_enabled_for_scope/4`: target-policy reconciles iterate every target
        # profile, so injected rules must not leak across providers.
        {:ok,
         Enum.filter(
           rules,
           &(rule_matches_provider?(&1, profile) and
               CredentialIntegration.rule_has_purpose?(profile, &1, purpose))
         )}

      :error ->
        scopes = agent_scopes(agent_id, actor)

        scopes
        |> Enum.reduce_while({:ok, []}, fn {scope_type, scope_value}, {:ok, acc} ->
          case NetworkCredentialRule.list_enabled_for_scope(
                 CredentialIntegration.provider(profile),
                 scope_type,
                 scope_value,
                 actor: actor
               ) do
            {:ok, rules} ->
              {:cont,
               {:ok,
                acc ++
                  Enum.filter(
                    rules,
                    &CredentialIntegration.rule_has_purpose?(profile, &1, purpose)
                  )}}

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
    RuleAccessors.value_string(rule, [:provider, "provider"]) ==
      CredentialIntegration.provider(profile)
  end

  defp selected_rules_for_agent(profile, rules, agent_id, purpose) do
    rules
    |> Enum.filter(
      &(CredentialIntegration.rule_has_purpose?(profile, &1, purpose) and rule_enabled?(&1) and
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

  defp required_profile(opts) do
    case Keyword.get(opts, :profile) do
      %{} = profile -> validate_target_policy_profile(profile)
      _ -> {:error, :credential_profile_required}
    end
  end

  defp required_purpose(opts) do
    case Keyword.get(opts, :purpose) do
      purpose when is_binary(purpose) and purpose != "" -> {:ok, purpose}
      purpose when is_atom(purpose) -> {:ok, Atom.to_string(purpose)}
      _ -> {:error, :credential_purpose_required}
    end
  end

  defp resolve_profile(%{} = profile, _actor, _opts), do: validate_target_policy_profile(profile)

  defp resolve_profile(provider, actor, opts) when is_binary(provider) do
    profile_for_provider(provider, actor, opts)
  end

  defp validate_target_policy_profile(profile) do
    if CredentialIntegration.target_policy?(profile) and
         is_binary(CredentialIntegration.provider(profile)) do
      {:ok, profile}
    else
      {:error, :invalid_target_policy_credential_profile}
    end
  end

  defp profile_for_provider(provider, actor, opts) do
    with {:ok, profiles} <- integration_profiles(actor, opts) do
      case Enum.find(profiles, &(CredentialIntegration.provider(&1) == provider)) do
        nil -> {:error, {:unknown_credential_provider, provider}}
        profile -> validate_target_policy_profile(profile)
      end
    end
  end

  defp target_policy_profiles(actor, opts) do
    with {:ok, profiles} <- integration_profiles(actor, opts) do
      {:ok, Enum.filter(profiles, &CredentialIntegration.target_policy?/1)}
    end
  end

  defp integration_profiles(actor, opts) do
    case Keyword.get(opts, :integration_catalog) do
      %{credential_profiles: profiles} when is_list(profiles) -> {:ok, profiles}
      %{"credential_profiles" => profiles} when is_list(profiles) -> {:ok, profiles}
      profiles when is_list(profiles) -> {:ok, profiles}
      nil -> load_integration_profiles(actor, opts)
      _ -> {:error, :invalid_plugin_integration_catalog}
    end
  end

  defp load_integration_profiles(actor, opts) do
    catalog_loader = Keyword.get(opts, :catalog_loader, &IntegrationCatalog.load/1)

    case catalog_loader.(actor: actor) do
      {:ok, %{credential_profiles: profiles}} -> {:ok, profiles}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_plugin_integration_catalog}
    end
  end

  defp resolve_consumer_package(%{} = package, consumer, _actor, _opts) do
    expected_plugin_id = CredentialIntegration.plugin_id(consumer)

    case value_string(package, [:plugin_id, "plugin_id"]) do
      nil -> {:ok, package}
      ^expected_plugin_id -> {:ok, package}
      _ -> {:error, {:plugin_package_mismatch, expected_plugin_id}}
    end
  end

  defp resolve_consumer_package(nil, consumer, actor, opts) do
    approved_plugin_package(CredentialIntegration.plugin_id(consumer), actor, opts)
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

  # Preserve the original inventory policy id for upgrade compatibility.
  defp policy_id_for_rule(rule_id, "inventory_enrichment"),
    do: "network-credential-rule:#{rule_id}"

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
