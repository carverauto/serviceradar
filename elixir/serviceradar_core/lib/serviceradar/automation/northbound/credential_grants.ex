defmodule ServiceRadar.Automation.Northbound.CredentialGrants do
  @moduledoc """
  Builds scoped credential broker grants for northbound action dispatch.

  Action descriptors may declare concrete credential requirements directly or
  point at invocation input keys that carry selected credential references. This
  module converts those requirements into persisted broker grants and returns
  the redacted command payload fields that are safe to send to agents.

  A requirement of a plugin action may instead declare a `credential_source`
  (see `ServiceRadar.Plugins.ActionCredentialRequirements`). Its secret is then
  resolved server-side from the plugin package's own provisioning records by
  `ServiceRadar.Automation.Northbound.PluginPackageContext`, and the static and
  input-selected secret keys are ignored for it. A declared source that cannot
  be resolved fails the launch before anything is dispatched.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Northbound.ActionInvocation
  alias ServiceRadar.Automation.Northbound.ActionInvocationTarget
  alias ServiceRadar.Automation.Northbound.PluginPackageContext
  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Plugins.ActionCredentialRequirements
  alias ServiceRadar.SRQLAst
  alias ServiceRadar.SRQLDeviceMatcher

  require Ash.Query

  @default_ttl_seconds 300

  @type prepared :: %{
          payload_fields: map(),
          context: map()
        }

  @spec prepare_launch(ActionInvocation.t(), map(), keyword()) ::
          {:ok, prepared()} | {:error, term()}
  def prepare_launch(%ActionInvocation{} = invocation, assignment, opts \\ []) do
    prepare(invocation, nil, assignment, "launch", opts)
  end

  @spec prepare_poll(ActionInvocation.t(), ActionInvocationTarget.t(), map(), keyword()) ::
          {:ok, prepared()} | {:error, term()}
  def prepare_poll(
        %ActionInvocation{} = invocation,
        %ActionInvocationTarget{} = target,
        assignment,
        opts \\ []
      ) do
    prepare(invocation, target, assignment, "poll", opts)
  end

  def issue_persisted_grant(attrs, opts \\ []) when is_map(attrs) do
    system_actor =
      Keyword.get(opts, :system_actor, SystemActor.system(:northbound_credential_grants))

    attrs = CredentialBrokerGrant.issue_attrs(attrs)

    with {:ok, grant} <- CredentialBrokerGrant.issue_grant(attrs, actor: system_actor) do
      {:ok, CredentialBrokerGrant.to_payload(grant)}
    end
  end

  defp prepare(invocation, target, assignment, phase, opts) do
    requirements = credential_requirements(invocation)

    if requirements == [] do
      {:ok, empty_prepared()}
    else
      requirements
      |> Enum.reduce_while({:ok, []}, fn requirement, {:ok, grants} ->
        case issue_requirement(requirement, invocation, target, assignment, phase, opts) do
          {:ok, nil} ->
            {:cont, {:ok, grants}}

          {:ok, grant} ->
            {:cont, {:ok, [grant | grants]}}

          {:error, reason} ->
            revoke_issued_grants(grants)
            {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, grants} -> {:ok, prepared_payload(Enum.reverse(grants))}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp empty_prepared, do: %{payload_fields: %{}, context: %{}}

  defp prepared_payload([]), do: empty_prepared()

  defp prepared_payload([grant]) do
    grant_ids = grant_ids([grant])

    %{
      payload_fields: %{"credential_brokers" => [grant]},
      context: %{credential_broker_grant_ids: grant_ids}
    }
  end

  defp prepared_payload(grants) do
    %{
      payload_fields: %{"credential_brokers" => grants},
      context: %{credential_broker_grant_ids: grant_ids(grants)}
    }
  end

  defp grant_ids(grants) do
    grants
    |> Enum.map(&map_get(&1, "grant_id"))
    |> Enum.filter(&present?/1)
  end

  defp revoke_issued_grants(grants) do
    actor = SystemActor.system(:northbound_credential_grants_cleanup)

    grants
    |> grant_ids()
    |> Enum.each(fn grant_id ->
      case CredentialBrokerGrant.get_by_id(grant_id, actor: actor) do
        {:ok, %CredentialBrokerGrant{status: status} = grant} when status in [:issued, :active] ->
          _ = CredentialBrokerGrant.revoke(grant, %{reason: "grant_issue_failed"}, actor: actor)
          :ok

        _ ->
          :ok
      end
    end)
  rescue
    _ -> :ok
  end

  defp issue_requirement(requirement, invocation, target, assignment, phase, opts) do
    case grant_attrs(requirement, invocation, target, assignment, phase, opts) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, attrs} ->
        issue_grant(attrs, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp issue_grant(attrs, opts) do
    issuer = Keyword.get(opts, :grant_issuer, {__MODULE__, :issue_persisted_grant})

    case call_issuer(issuer, attrs, opts) do
      {:ok, %{} = grant} -> {:ok, grant}
      {:ok, other} -> {:error, {:invalid_credential_broker_grant_payload, other}}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_credential_broker_grant_issuer_result, other}}
    end
  end

  defp call_issuer({module, function}, attrs, opts), do: apply(module, function, [attrs, opts])
  defp call_issuer(fun, attrs, opts) when is_function(fun, 2), do: fun.(attrs, opts)
  defp call_issuer(fun, attrs, _opts) when is_function(fun, 1), do: fun.(attrs)

  defp grant_attrs(requirement, invocation, target, assignment, phase, opts) do
    case ActionCredentialRequirements.credential_source(requirement) do
      nil ->
        if present?(map_get(requirement, "credential_source")) do
          {:error,
           {:unsupported_credential_source, requirement_name(requirement),
            map_get(requirement, "credential_source")}}
        else
          selected_grant_attrs(requirement, invocation, target, assignment, phase)
        end

      source ->
        declared_grant_attrs(source, requirement, invocation, target, assignment, phase, opts)
    end
  end

  # A declared source resolves the secret from the package's own provisioning
  # records. The static and input-selected secret keys are never consulted for
  # it, so no invocation input can retarget the grant.
  defp declared_grant_attrs(source, requirement, invocation, target, assignment, phase, opts) do
    case resolve_declared_source(source, requirement, invocation, assignment, opts) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, %{} = resolved} ->
        requirement = Map.put(requirement, "credential_rule_id", resolved.credential_rule_id)

        {:ok,
         build_attrs(
           requirement,
           invocation,
           target,
           assignment,
           phase,
           Map.get(resolved, :secret_id),
           Map.get(resolved, :secret_ref)
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_declared_source(source, requirement, invocation, assignment, opts) do
    context = Keyword.get(opts, :plugin_package_context, PluginPackageContext)
    name = requirement_name(requirement)

    cond do
      not plugin_package_invocation?(invocation, assignment) ->
        {:error, {:credential_source_requires_plugin_package, name, source}}

      source == "assignment_schedule" ->
        resolve_schedule_source(context, requirement, assignment, name)

      source == "package_rule" ->
        resolve_package_rule_source(context, requirement, invocation, assignment, name, opts)

      true ->
        {:error, {:unsupported_credential_source, name, source}}
    end
  end

  defp resolve_schedule_source(context, requirement, assignment, name) do
    ref_name = requirement |> map_get("requirement") |> trimmed()

    case ref_name && context.schedule_credential(assignment, ref_name, []) do
      {:ok, %{secret_ref: secret_ref} = resolved} when is_binary(secret_ref) ->
        {:ok, %{secret_ref: secret_ref, credential_rule_id: resolved.credential_rule_id}}

      {:error, :no_bound_schedule} ->
        {:error, {:no_bound_schedule_credential, name, ref_name}}

      {:error, reason} ->
        {:error, reason}

      _missing ->
        {:error, {:no_bound_schedule_credential, name, ref_name}}
    end
  end

  defp resolve_package_rule_source(context, requirement, invocation, assignment, name, opts) do
    input_key = requirement |> map_get("rule_input") |> trimmed()
    rule_id = input_value(normalize_map(invocation.input_values), input_key)

    cond do
      is_nil(input_key) ->
        {:error, {:credential_rule_not_eligible, name, input_key}}

      not present?(rule_id) and required_requirement?(requirement) ->
        {:error, {:missing_credential_rule_input, name, input_key}}

      not present?(rule_id) ->
        {:ok, nil}

      true ->
        with {:ok, actor} <- package_rule_actor(invocation, opts),
             {:ok, rule} <-
               context.eligible_rule(invocation.provider.plugin_package_id, rule_id, actor: actor),
             :ok <- ensure_rule_scope(rule, assignment, invocation) do
          {:ok, %{secret_id: to_string(rule.secret_id), credential_rule_id: to_string(rule.id)}}
        else
          {:error, :credential_rule_permission_required} ->
            {:error, :credential_rule_permission_required}

          {:error, :credential_rule_not_eligible} ->
            {:error, {:credential_rule_not_eligible, name, input_key}}

          {:error, _reason} ->
            {:error, {:credential_rule_not_eligible, name, input_key}}
        end
    end
  end

  defp package_rule_actor(%{source: source}, _opts)
       when source in [:schedule, :event_handler, :system],
       do: {:ok, SystemActor.system(:northbound_credential_grants)}

  defp package_rule_actor(_invocation, opts) do
    actor = Keyword.get(opts, :actor)

    if not SystemActor.system_actor?(actor) and
         not RBAC.has_permission?(actor, "settings.credentials.manage") do
      {:error, :credential_rule_permission_required}
    else
      {:ok, actor || SystemActor.system(:northbound_credential_grants)}
    end
  end

  defp ensure_rule_scope(rule, assignment, invocation) do
    assignment_agent = to_string(Map.get(assignment, :agent_uid) || "")
    scope_value = to_string(rule_field(rule, :scope_value, "scope_value") || "")

    case grant_target_snapshots(invocation) do
      [] ->
        {:error, :credential_rule_not_eligible}

      snapshots ->
        if Enum.all?(snapshots, fn snapshot ->
             rule_covers_target?(rule, scope_value, assignment_agent, assignment, snapshot)
           end) do
          :ok
        else
          {:error, :credential_rule_not_eligible}
        end
    end
  end

  defp rule_covers_target?(rule, scope_value, assignment_agent, assignment, snapshot) do
    target_agent = map_get(snapshot, "agent_id") || map_get(snapshot, "device_agent_id")
    target_gateway = map_get(snapshot, "gateway_id") || map_get(snapshot, "device_gateway_id")
    target_uid = map_get(snapshot, "device_uid")

    edge_matches =
      case rule_field(rule, :scope_type, "scope_type") do
        scope when scope in [:agent, "agent"] ->
          scope_value == assignment_agent and to_string(target_agent || "") == assignment_agent

        scope when scope in [:gateway, "gateway"] ->
          is_binary(target_agent) and target_agent == assignment_agent and
            to_string(target_gateway || "") == scope_value

        scope when scope in [:partition, "partition"] ->
          is_binary(target_agent) and target_agent == assignment_agent and
            to_string(Map.get(assignment, :partition_id) || "") == scope_value

        _scope ->
          false
      end

    edge_matches and is_binary(target_uid) and
      target_query_matches?(rule_field(rule, :target_query, "target_query"), target_uid) == :ok
  end

  defp rule_field(rule, atom_key, string_key) do
    Map.get(rule, atom_key) || Map.get(rule, string_key)
  end

  defp grant_target_snapshots(%ActionInvocationTarget{target_snapshot: snapshot}),
    do: [normalize_map(snapshot)]

  defp grant_target_snapshots(invocation) do
    Enum.map(List.wrap(invocation.target_snapshots), &normalize_map/1)
  end

  defp target_query_matches?(query, target_uid) when is_binary(query) do
    with {:ok, ast} <- SRQLAst.parse(query),
         filters <- SRQLDeviceMatcher.extract_filters(ast),
         true <- filters == [] or target_matches_filters?(target_uid, filters) do
      :ok
    else
      _ -> {:error, :credential_rule_not_eligible}
    end
  end

  defp target_query_matches?(_query, _target_uid), do: {:error, :credential_rule_not_eligible}

  defp target_matches_filters?(target_uid, filters) do
    actor = SystemActor.system(:northbound_credential_rule_scope)

    Device
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(uid == ^target_uid)
    |> SRQLDeviceMatcher.apply_filters(filters)
    |> Ash.Query.limit(1)
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, %Device{}} -> true
      _ -> false
    end
  end

  defp plugin_package_invocation?(invocation, assignment) do
    provider = invocation.provider

    match?(%{provider_type: :wasm_plugin}, provider) and
      present?(Map.get(provider, :plugin_package_id)) and
      to_string(provider.plugin_package_id) == to_string(Map.get(assignment, :plugin_package_id))
  end

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trimmed(_value), do: nil

  defp selected_grant_attrs(requirement, invocation, target, assignment, phase) do
    input_values = normalize_map(invocation.input_values)

    secret_id =
      first_present([
        map_get(requirement, "credential_secret_id"),
        map_get(requirement, "secret_id"),
        input_value(input_values, map_get(requirement, "credential_secret_input")),
        input_value(input_values, map_get(requirement, "secret_input")),
        input_value(input_values, map_get(requirement, "input_key"))
      ])

    secret_ref =
      first_present([
        map_get(requirement, "credential_secret_ref"),
        map_get(requirement, "secret_ref"),
        input_value(input_values, map_get(requirement, "credential_secret_ref_input")),
        input_value(input_values, map_get(requirement, "secret_ref_input"))
      ])

    cond do
      present?(secret_id) or present?(secret_ref) ->
        {:ok,
         build_attrs(requirement, invocation, target, assignment, phase, secret_id, secret_ref)}

      required_requirement?(requirement) ->
        {:error, {:missing_credential_for_requirement, requirement_name(requirement)}}

      true ->
        {:ok, nil}
    end
  end

  defp build_attrs(requirement, invocation, target, assignment, phase, secret_id, secret_ref) do
    ttl_seconds = ttl_seconds(requirement, invocation, assignment)
    target_scope = target_scope(requirement, invocation, target)
    allow = normalize_map(map_get(requirement, "allow"))

    %{
      secret_id: secret_id,
      secret_ref: secret_ref,
      credential_rule_id: map_get(requirement, "credential_rule_id"),
      grant_type: map_get(requirement, "grant_type") || "northbound_action_credential",
      consumer_kind: :northbound_action,
      consumer_id: invocation.id,
      purpose: map_get(requirement, "purpose") || "#{invocation.action_id}:#{phase}",
      target_kind: target_scope.kind,
      target_id: target_scope.id,
      agent_id: assignment.agent_uid,
      resolution_location:
        normalize_resolution_location(map_get(requirement, "resolution_location")),
      allowed_methods:
        string_list(map_get(allow, "methods") || map_get(requirement, "allowed_methods")),
      allowed_paths:
        string_list(map_get(allow, "paths") || map_get(requirement, "allowed_paths")),
      allowed_hosts:
        string_list(map_get(allow, "hosts") || map_get(requirement, "allowed_hosts")),
      allowed_ports:
        integer_list(map_get(allow, "ports") || map_get(requirement, "allowed_ports")),
      inject: normalize_map(map_get(requirement, "inject")),
      metadata: grant_metadata(requirement, invocation, phase),
      ttl_seconds: ttl_seconds,
      issued_by_actor_id: invocation.requested_by_actor_id
    }
  end

  defp grant_metadata(requirement, invocation, phase) do
    %{
      "phase" => phase,
      "action_id" => invocation.action_id,
      "descriptor_id" => invocation.descriptor_id,
      "provider_id" => invocation.provider_id,
      "requirement_name" => requirement_name(requirement),
      "credential_source" => ActionCredentialRequirements.credential_source(requirement)
    }
    |> Enum.reject(fn {_key, value} -> !present?(value) end)
    |> Map.new()
  end

  defp target_scope(requirement, invocation, target) do
    explicit_kind = map_get(requirement, "target_kind")
    explicit_id = map_get(requirement, "target_id")

    cond do
      present?(explicit_kind) or present?(explicit_id) ->
        %{kind: explicit_kind || "northbound_action", id: explicit_id || invocation.id}

      match?(%ActionInvocationTarget{}, target) ->
        snapshot_scope(normalize_map(target.target_snapshot), target.id)

      true ->
        invocation.target_snapshots
        |> List.wrap()
        |> List.first()
        |> normalize_map()
        |> snapshot_scope(invocation.id)
    end
  end

  defp snapshot_scope(snapshot, fallback_id) do
    cond do
      present?(map_get(snapshot, "device_uid")) ->
        %{kind: "device", id: map_get(snapshot, "device_uid")}

      present?(map_get(snapshot, "interface_uid")) ->
        %{kind: "interface", id: map_get(snapshot, "interface_uid")}

      present?(map_get(snapshot, "event_id")) ->
        %{kind: "event", id: map_get(snapshot, "event_id")}

      true ->
        %{kind: "northbound_action", id: fallback_id}
    end
  end

  defp ttl_seconds(requirement, invocation, assignment) do
    first_positive_integer([
      map_get(requirement, "ttl_seconds"),
      map_get(requirement, "credential_ttl_seconds"),
      invocation.descriptor && invocation.descriptor.timeout_seconds,
      assignment.timeout_seconds,
      @default_ttl_seconds
    ])
  end

  defp credential_requirements(invocation) do
    Enum.flat_map(
      [
        invocation.provider && invocation.provider.credential_requirements,
        invocation.descriptor && invocation.descriptor.credential_requirements
      ],
      &ActionCredentialRequirements.flatten/1
    )
  end

  defp required_requirement?(requirement) do
    map_get(requirement, "required") == true or map_get(requirement, "required?") == true
  end

  defp requirement_name(requirement) do
    first_present([
      map_get(requirement, "name"),
      map_get(requirement, "id"),
      map_get(requirement, "purpose"),
      map_get(requirement, "grant_type")
    ])
  end

  defp input_value(_input_values, nil), do: nil
  defp input_value(input_values, key) when is_binary(key), do: map_get(input_values, key)

  defp input_value(input_values, key) when is_atom(key),
    do: map_get(input_values, Atom.to_string(key))

  defp input_value(_input_values, _key), do: nil

  defp normalize_resolution_location(nil), do: :agent

  defp normalize_resolution_location(value) when value in [:agent, :control_plane, :hybrid],
    do: value

  defp normalize_resolution_location("agent"), do: :agent
  defp normalize_resolution_location("control_plane"), do: :control_plane
  defp normalize_resolution_location("hybrid"), do: :hybrid
  defp normalize_resolution_location(_value), do: :agent

  defp string_list(value) do
    value
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp integer_list(value) do
    value
    |> List.wrap()
    |> Enum.flat_map(fn
      integer when is_integer(integer) -> [integer]
      value when is_binary(value) -> parse_integer_list(value)
      _ -> []
    end)
    |> Enum.filter(&(&1 > 0))
    |> Enum.uniq()
  end

  defp parse_integer_list(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.flat_map(fn part ->
      case Integer.parse(String.trim(part)) do
        {integer, ""} -> [integer]
        _ -> []
      end
    end)
  end

  defp first_positive_integer(values) do
    values
    |> Enum.find_value(&positive_integer/1)
    |> case do
      nil -> @default_ttl_seconds
      integer -> integer
    end
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: value

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer > 0 -> integer
      _ -> nil
    end
  end

  defp positive_integer(_value), do: nil

  defp first_present(values), do: Enum.find(values, &present?/1)

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?([]), do: false
  defp present?(%{} = value), do: map_size(value) > 0
  defp present?(_value), do: true

  defp normalize_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {normalize_key(key), value} end)
  end

  defp normalize_map(_map), do: %{}

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: key

  defp map_get(map, key) when is_map(map) and is_atom(key), do: Map.get(map, Atom.to_string(key))
  defp map_get(map, key) when is_map(map), do: Map.get(map, key)
  defp map_get(_map, _key), do: nil
end
