defmodule ServiceRadar.Automation.Northbound.CredentialGrants do
  @moduledoc """
  Builds scoped credential broker grants for northbound action dispatch.

  Action descriptors may declare concrete credential requirements directly or
  point at invocation input keys that carry selected credential references. This
  module converts those requirements into persisted broker grants and returns
  the redacted command payload fields that are safe to send to agents.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Northbound.ActionInvocation
  alias ServiceRadar.Automation.Northbound.ActionInvocationTarget
  alias ServiceRadar.Credentials.CredentialBrokerGrant

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
    case grant_attrs(requirement, invocation, target, assignment, phase) do
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

  defp grant_attrs(requirement, invocation, target, assignment, phase) do
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
      "requirement_name" => requirement_name(requirement)
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
      &normalize_requirements/1
    )
  end

  defp normalize_requirements(nil), do: []
  defp normalize_requirements([]), do: []

  defp normalize_requirements(requirements) when is_list(requirements) do
    requirements
    |> Enum.filter(&is_map/1)
    |> Enum.map(&normalize_map/1)
  end

  defp normalize_requirements(%{} = requirements) do
    cond do
      is_list(map_get(requirements, "credentials")) ->
        normalize_requirements(map_get(requirements, "credentials"))

      is_list(map_get(requirements, "requirements")) ->
        normalize_requirements(map_get(requirements, "requirements"))

      map_size(requirements) == 0 ->
        []

      credential_requirement?(requirements) ->
        [normalize_map(requirements)]

      true ->
        requirements
        |> Map.values()
        |> normalize_requirements()
    end
  end

  defp normalize_requirements(_requirements), do: []

  defp credential_requirement?(requirement) do
    Enum.any?(
      [
        "credential_secret_id",
        "secret_id",
        "credential_secret_ref",
        "secret_ref",
        "credential_secret_input",
        "secret_input",
        "input_key",
        "credential_secret_ref_input",
        "secret_ref_input"
      ],
      &present?(map_get(requirement, &1))
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
