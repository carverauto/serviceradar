defmodule ServiceRadar.Plugins.ProducerScheduleDispatcher do
  @moduledoc """
  Dispatches package-owned producer schedules through existing agent command paths.

  Producer packages own provider-specific download, validation, and normalization
  details. The dispatcher only understands the generic schedule contract and the
  runtime command envelope needed to reach the assigned producer.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Plugins.AddonAssignment
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.SRQLInputResolver
  alias ServiceRadar.Plugins.ValueUtils

  require Ash.Query

  @plugin_run_action "plugin.run_action"
  @addon_run_command "addon.run_command"
  @credential_grant_schema "serviceradar.edge_credential_broker_grant.v1"
  @dispatch_scope_assignment "assignment"
  @dispatch_scope_package "package"
  @dispatch_scope_target_query "target_query"
  @target_query_input_name "targets"
  @nnm_token_path "/idp/oauth2/token"
  @direct_na_token_path "/nom-na/idp/oauth2/token"

  @spec dispatch(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def dispatch(schedule, opts \\ []) do
    case normalize_kind(schedule.producer_kind) do
      :wasm_plugin -> dispatch_wasm_plugin(schedule, opts)
      :native_addon -> dispatch_native_addon(schedule, opts)
      other -> {:error, {:unsupported_producer_kind, other}}
    end
  end

  @spec build_plugin_payload(map(), map()) :: map()
  def build_plugin_payload(schedule, assignment) do
    contract = schedule.contract || %{}
    template = map_get(contract, "payload_template") || %{}
    action_id = map_get(contract, "action_id") || schedule.schedule_id

    Map.merge(template, %{
      "schema" => "serviceradar.producer_schedule_run.v1",
      "invocation_id" => Ash.UUID.generate(),
      "action_id" => action_id,
      "plugin_assignment_id" => to_string(assignment.id),
      "plugin_package_id" => to_string(assignment.plugin_package_id),
      "producer_schedule_id" => to_string(schedule.id),
      "schedule_id" => schedule.schedule_id,
      "input_values" => schedule.params || %{},
      "credential_refs" => schedule.credential_refs || %{},
      "metadata" =>
        Map.merge(schedule.metadata || %{}, %{
          "producer_kind" => "wasm_plugin",
          "schedule_id" => schedule.schedule_id,
          "producer_schedule_id" => to_string(schedule.id)
        })
    })
  end

  @spec build_addon_payload(map(), map()) :: map()
  def build_addon_payload(schedule, assignment) do
    contract = schedule.contract || %{}
    template = map_get(contract, "payload_template") || %{}
    action_id = map_get(contract, "action_id") || schedule.schedule_id

    Map.merge(template, %{
      "schema" => "serviceradar.producer_schedule_run.v1",
      "invocation_id" => Ash.UUID.generate(),
      "action_id" => action_id,
      "addon_assignment_id" => to_string(assignment.id),
      "addon_package_id" => to_string(assignment.addon_package_id),
      "addon_id" => assignment.addon_id,
      "producer_schedule_id" => to_string(schedule.id),
      "schedule_id" => schedule.schedule_id,
      "input_values" => schedule.params || %{},
      "credential_refs" => schedule.credential_refs || %{},
      "metadata" =>
        Map.merge(schedule.metadata || %{}, %{
          "producer_kind" => "native_addon",
          "schedule_id" => schedule.schedule_id,
          "producer_schedule_id" => to_string(schedule.id)
        })
    })
  end

  @spec build_plugin_transmit_payload(map(), [map()]) :: map()
  def build_plugin_transmit_payload(payload, credential_grants \\ []) when is_map(payload),
    do: build_transmit_payload(payload, credential_grants)

  @spec build_addon_transmit_payload(map(), [map()]) :: map()
  def build_addon_transmit_payload(payload, credential_grants \\ []) when is_map(payload),
    do: build_transmit_payload(payload, credential_grants)

  defp build_transmit_payload(payload, credential_grants) do
    credential_ref_keys =
      payload
      |> map_get("credential_refs")
      |> normalize_map()
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.sort()

    payload
    |> Map.delete("credential_refs")
    |> put_credential_grants(credential_grants)
    |> Map.update("metadata", credential_ref_metadata(credential_ref_keys), fn metadata ->
      metadata
      |> normalize_map()
      |> Map.merge(credential_ref_metadata(credential_ref_keys))
    end)
  end

  defp dispatch_wasm_plugin(schedule, opts) do
    command_type = map_get(schedule.contract || %{}, "command_type") || @plugin_run_action

    with :ok <- ensure_command_type(command_type, @plugin_run_action),
         {:ok, assignments} <- resolve_plugin_assignments(schedule, opts) do
      dispatch_plugin_assignments(schedule, assignments, command_type, opts)
    end
  end

  defp dispatch_native_addon(schedule, opts) do
    command_type = map_get(schedule.contract || %{}, "command_type") || @addon_run_command

    with :ok <- ensure_command_type(command_type, @addon_run_command),
         {:ok, assignments} <- resolve_addon_assignments(schedule, opts) do
      dispatch_addon_assignments(schedule, assignments, command_type, opts)
    end
  end

  defp resolve_plugin_assignments(schedule, opts) do
    case dispatch_scope(schedule.contract) do
      @dispatch_scope_assignment ->
        with {:ok, assignment} <- load_plugin_assignment(schedule.plugin_assignment_id, opts) do
          {:ok, [assignment]}
        end

      @dispatch_scope_package ->
        load_plugin_package_assignments(schedule.plugin_package_id, opts)

      @dispatch_scope_target_query ->
        resolve_target_query_assignments(schedule, opts)

      other ->
        {:error, {:unsupported_dispatch_scope, other}}
    end
  end

  defp dispatch_plugin_assignments(_schedule, [], _command_type, _opts),
    do: {:error, :no_matching_plugin_assignments}

  defp dispatch_plugin_assignments(schedule, assignments, command_type, opts) do
    assignments
    |> Enum.map(&dispatch_plugin_assignment(schedule, &1, command_type, opts))
    |> summarize_dispatch_results()
  end

  defp dispatch_plugin_assignment(schedule, assignment, command_type, opts) do
    case issue_credential_grants(schedule, assignment, opts) do
      {:ok, credential_grants} ->
        payload = build_plugin_payload(schedule, assignment)
        transmit_payload = build_plugin_transmit_payload(payload, credential_grants)
        timeout_seconds = timeout_seconds(schedule.contract)
        command_bus = Keyword.get(opts, :command_bus, AgentCommandBus)

        command_bus
        |> dispatch_command(
          assignment.agent_uid,
          command_type,
          transmit_payload,
          ttl_seconds: timeout_seconds,
          required_partition: assignment.partition_id,
          source: :automation,
          context: %{
            producer_schedule_id: to_string(schedule.id),
            plugin_assignment_id: to_string(assignment.id),
            plugin_package_id: to_string(assignment.plugin_package_id),
            schedule_id: schedule.schedule_id,
            action_id: payload["action_id"]
          }
        )
        |> case do
          {:ok, command_id} ->
            {:ok, %{agent_uid: assignment.agent_uid, command_id: command_id}}

          {:error, reason} ->
            {:error, %{agent_uid: assignment.agent_uid, reason: reason}}
        end

      {:error, reason} ->
        {:error, %{agent_uid: assignment.agent_uid, reason: reason}}
    end
  end

  defp dispatch_command(command_bus, agent_uid, command_type, payload, opts) do
    command_bus.dispatch(agent_uid, command_type, payload, opts)
  end

  defp summarize_dispatch_results(results) do
    {successes, failures} =
      Enum.split_with(results, fn
        {:ok, _result} -> true
        {:error, _reason} -> false
      end)

    command_ids =
      Enum.map(successes, fn {:ok, %{command_id: command_id}} -> command_id end)

    failure_summaries =
      Enum.map(failures, fn {:error, failure} -> failure end)

    cond do
      failures == [] and command_ids != [] ->
        {:ok, hd(command_ids)}

      command_ids == [] ->
        {:error, {:producer_schedule_dispatch_failed, failure_summaries}}

      true ->
        {:error,
         {:producer_schedule_partial_dispatch_failed,
          %{command_ids: command_ids, failures: failure_summaries}}}
    end
  end

  def issue_persisted_credential_grant(attrs, opts \\ []) when is_map(attrs) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:producer_schedule_credentials))

    attrs
    |> CredentialBrokerGrant.issue_attrs()
    |> CredentialBrokerGrant.issue_grant(actor: actor)
    |> case do
      {:ok, grant} -> {:ok, CredentialBrokerGrant.to_payload(grant)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_command_type(expected, expected), do: :ok

  defp ensure_command_type(command_type, expected),
    do: {:error, {:unsupported_command_type, %{got: command_type, expected: expected}}}

  defp load_plugin_assignment(nil, _opts), do: {:error, :missing_plugin_assignment_id}

  defp load_plugin_assignment(assignment_id, opts) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:producer_schedule_dispatcher))

    PluginAssignment
    |> Ash.Query.filter(id == ^assignment_id and enabled == true)
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, nil} -> {:error, :plugin_assignment_not_found}
      {:ok, assignment} -> {:ok, assignment}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_plugin_package_assignments(nil, _opts), do: {:error, :missing_plugin_package_id}

  defp load_plugin_package_assignments(package_id, opts) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:producer_schedule_dispatcher))

    PluginAssignment
    |> Ash.Query.filter(plugin_package_id == ^package_id and enabled == true)
    |> Ash.Query.sort(agent_uid: :asc)
    |> Ash.read(actor: actor)
  end

  defp resolve_target_query_assignments(schedule, opts) do
    with {:ok, agent_uids} <- resolve_target_query_agent_uids(schedule, opts) do
      load_plugin_assignments_for_agents(schedule.plugin_package_id, agent_uids, opts)
    end
  end

  defp resolve_target_query_agent_uids(schedule, opts) do
    query = normalize_optional_string(schedule.target_query)

    if query == nil do
      {:error, :missing_target_query}
    else
      input_def = %{
        "name" => @target_query_input_name,
        "entity" => target_query_entity(query),
        "query" => query
      }

      resolver_opts =
        opts
        |> Keyword.take([:runner, :query_opts])
        |> maybe_put_query_scope(opts)

      with {:ok, resolved_inputs} <- SRQLInputResolver.resolve([input_def], resolver_opts) do
        agent_uids = resolved_inputs |> Enum.flat_map(&target_agent_uids/1) |> Enum.uniq()

        case agent_uids do
          [] -> {:error, :target_query_matched_no_agents}
          agent_uids -> {:ok, agent_uids}
        end
      end
    end
  end

  defp maybe_put_query_scope(resolver_opts, opts) do
    case Keyword.get(opts, :scope) do
      nil ->
        resolver_opts

      scope ->
        Keyword.update(resolver_opts, :query_opts, [scope: scope], fn query_opts ->
          Keyword.put_new(query_opts, :scope, scope)
        end)
    end
  end

  defp target_agent_uids(%{rows: rows}) when is_list(rows) do
    rows
    |> Enum.map(&target_agent_uid/1)
    |> Enum.reject(&ValueUtils.blank_string?/1)
  end

  defp target_agent_uids(_input), do: []

  defp target_agent_uid(row) when is_map(row) do
    ValueUtils.string_value(row, [
      "agent_uid",
      :agent_uid,
      "agent_id",
      :agent_id,
      "agent",
      :agent,
      "uid",
      :uid
    ])
  end

  defp target_agent_uid(_row), do: nil

  defp load_plugin_assignments_for_agents(nil, _agent_uids, _opts),
    do: {:error, :missing_plugin_package_id}

  defp load_plugin_assignments_for_agents(_package_id, [], _opts), do: {:ok, []}

  defp load_plugin_assignments_for_agents(package_id, agent_uids, opts) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:producer_schedule_dispatcher))

    PluginAssignment
    |> Ash.Query.filter(
      plugin_package_id == ^package_id and enabled == true and agent_uid in ^agent_uids
    )
    |> Ash.Query.sort(agent_uid: :asc)
    |> Ash.read(actor: actor)
  end

  defp resolve_addon_assignments(schedule, opts) do
    case dispatch_scope(schedule.contract) do
      @dispatch_scope_assignment ->
        with {:ok, assignment} <- load_addon_assignment(schedule.addon_assignment_id, opts) do
          {:ok, [assignment]}
        end

      @dispatch_scope_package ->
        load_addon_package_assignments(schedule.addon_package_id, opts)

      @dispatch_scope_target_query ->
        resolve_target_query_addon_assignments(schedule, opts)

      other ->
        {:error, {:unsupported_dispatch_scope, other}}
    end
  end

  defp dispatch_addon_assignments(_schedule, [], _command_type, _opts),
    do: {:error, :no_matching_addon_assignments}

  defp dispatch_addon_assignments(schedule, assignments, command_type, opts) do
    assignments
    |> Enum.map(&dispatch_addon_assignment(schedule, &1, command_type, opts))
    |> summarize_dispatch_results()
  end

  defp dispatch_addon_assignment(schedule, assignment, command_type, opts) do
    case issue_credential_grants(schedule, assignment, opts) do
      {:ok, credential_grants} ->
        payload = build_addon_payload(schedule, assignment)
        transmit_payload = build_addon_transmit_payload(payload, credential_grants)
        timeout_seconds = timeout_seconds(schedule.contract)
        command_bus = Keyword.get(opts, :command_bus, AgentCommandBus)

        command_bus
        |> dispatch_command(assignment.agent_uid, command_type, transmit_payload,
          ttl_seconds: timeout_seconds,
          source: :automation,
          context: %{
            producer_schedule_id: to_string(schedule.id),
            addon_assignment_id: to_string(assignment.id),
            addon_package_id: to_string(assignment.addon_package_id),
            schedule_id: schedule.schedule_id,
            action_id: payload["action_id"]
          }
        )
        |> case do
          {:ok, command_id} ->
            {:ok, %{agent_uid: assignment.agent_uid, command_id: command_id}}

          {:error, reason} ->
            {:error, %{agent_uid: assignment.agent_uid, reason: reason}}
        end

      {:error, reason} ->
        {:error, %{agent_uid: assignment.agent_uid, reason: reason}}
    end
  end

  defp load_addon_assignment(nil, _opts), do: {:error, :missing_addon_assignment_id}

  defp load_addon_assignment(assignment_id, opts) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:producer_schedule_dispatcher))

    AddonAssignment
    |> Ash.Query.filter(id == ^assignment_id and enabled == true)
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, nil} -> {:error, :addon_assignment_not_found}
      {:ok, assignment} -> {:ok, assignment}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_addon_package_assignments(nil, _opts), do: {:error, :missing_addon_package_id}

  defp load_addon_package_assignments(package_id, opts) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:producer_schedule_dispatcher))

    AddonAssignment
    |> Ash.Query.filter(addon_package_id == ^package_id and enabled == true)
    |> Ash.Query.sort(agent_uid: :asc)
    |> Ash.read(actor: actor)
  end

  defp resolve_target_query_addon_assignments(schedule, opts) do
    with {:ok, agent_uids} <- resolve_target_query_agent_uids(schedule, opts) do
      load_addon_assignments_for_agents(schedule.addon_package_id, agent_uids, opts)
    end
  end

  defp load_addon_assignments_for_agents(nil, _agent_uids, _opts),
    do: {:error, :missing_addon_package_id}

  defp load_addon_assignments_for_agents(_package_id, [], _opts), do: {:ok, []}

  defp load_addon_assignments_for_agents(package_id, agent_uids, opts) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:producer_schedule_dispatcher))

    AddonAssignment
    |> Ash.Query.filter(
      addon_package_id == ^package_id and enabled == true and agent_uid in ^agent_uids
    )
    |> Ash.Query.sort(agent_uid: :asc)
    |> Ash.read(actor: actor)
  end

  defp timeout_seconds(contract) do
    case map_get(contract || %{}, "timeout_seconds") do
      value when is_integer(value) and value > 0 -> value
      value when is_binary(value) -> parse_positive_int(value, 300)
      _ -> 300
    end
  end

  defp issue_credential_grants(schedule, assignment, opts) do
    refs = normalize_map(schedule.credential_refs)
    requirements = credential_requirements(schedule.contract || %{})

    with :ok <- ensure_required_credentials(requirements, refs) do
      refs
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.reduce_while({:ok, []}, fn {key, secret_ref}, {:ok, grants} ->
        key = to_string(key)

        if present?(secret_ref) do
          requirement = Map.get(requirements, key, %{})

          case issue_credential_grants_for_requirement(
                 key,
                 secret_ref,
                 requirement,
                 schedule,
                 assignment,
                 opts
               ) do
            {:ok, issued} -> {:cont, {:ok, [issued | grants]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        else
          {:cont, {:ok, grants}}
        end
      end)
      |> case do
        {:ok, grants} -> {:ok, grants |> Enum.reverse() |> List.flatten()}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp issue_credential_grants_for_requirement(
         key,
         secret_ref,
         requirement,
         schedule,
         assignment,
         opts
       ) do
    with {:ok, requirements} <- expand_credential_grant_requirements(key, requirement) do
      requirements
      |> Enum.reduce_while({:ok, []}, fn grant_requirement, {:ok, grants} ->
        with {:ok, resolved_requirement} <-
               resolve_credential_grant_endpoint(key, grant_requirement, schedule),
             {:ok, grant} <-
               issue_credential_grant(
                 key,
                 secret_ref,
                 resolved_requirement,
                 schedule,
                 assignment,
                 opts
               ) do
          {:cont, {:ok, [grant | grants]}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, grants} -> {:ok, Enum.reverse(grants)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp expand_credential_grant_requirements(key, requirement) do
    requirement = normalize_map(requirement)

    case map_get(requirement, "grants") do
      nil ->
        {:ok, [requirement]}

      grants when is_list(grants) and grants != [] ->
        if Enum.all?(grants, &is_map/1) do
          parent = Map.delete(requirement, "grants")

          {:ok,
           Enum.map(grants, fn grant ->
             Map.merge(parent, normalize_map(grant))
           end)}
        else
          {:error, {:invalid_schedule_credential_grants, key}}
        end

      _other ->
        {:error, {:invalid_schedule_credential_grants, key}}
    end
  end

  defp resolve_credential_grant_endpoint(key, requirement, schedule) do
    allow = normalize_map(map_get(requirement, "allow"))

    case normalize_optional_string(map_get(allow, "url_param")) do
      nil ->
        {:ok, requirement}

      url_param ->
        with {:ok, endpoint} <- schedule_https_endpoint(schedule, url_param),
             {:ok, inject} <-
               resolve_credential_grant_injection(
                 key,
                 normalize_map(map_get(requirement, "inject")),
                 url_param,
                 endpoint,
                 allow,
                 schedule
               ) do
          resolved_allow =
            allow
            |> Map.delete("url_param")
            |> Map.delete("url_params")
            |> Map.put("hosts", [endpoint.host])
            |> Map.put("ports", [endpoint.port])
            |> Map.put("paths", [endpoint.path])

          {:ok,
           requirement
           |> Map.put("allow", resolved_allow)
           |> Map.put("inject", inject)}
        end
    end
  end

  defp schedule_https_endpoint(schedule, url_param) do
    schedule
    |> schedule_param(url_param)
    |> parse_https_endpoint()
    |> case do
      {:ok, endpoint} -> {:ok, endpoint}
      :error -> {:error, {:invalid_schedule_credential_endpoint, url_param}}
    end
  end

  # OpenText NOM (and the plugin itself) derive the OAuth token URL when the
  # operator leaves token_url blank: NNMi-integrated installs use
  # {nnm_url}/idp/oauth2/token; standalone NA uses {api_url origin}/nom-na/idp/oauth2/token.
  defp schedule_token_endpoint(schedule, token_url_param) do
    case schedule_param(schedule, token_url_param) do
      nil -> derive_oauth_token_endpoint(schedule, token_url_param)
      _present -> schedule_https_endpoint(schedule, token_url_param)
    end
  end

  defp derive_oauth_token_endpoint(schedule, "token_url") do
    params = normalize_map(schedule.params)

    cond do
      origin = https_origin(map_get(params, "nnm_url")) ->
        (origin <> @nnm_token_path)
        |> parse_https_endpoint()
        |> map_endpoint_error("token_url")

      origin = https_origin(map_get(params, "api_url")) ->
        (origin <> @direct_na_token_path)
        |> parse_https_endpoint()
        |> map_endpoint_error("token_url")

      true ->
        {:error, {:invalid_schedule_credential_endpoint, "token_url"}}
    end
  end

  defp derive_oauth_token_endpoint(_schedule, url_param),
    do: {:error, {:invalid_schedule_credential_endpoint, url_param}}

  defp map_endpoint_error({:ok, endpoint}, _url_param), do: {:ok, endpoint}

  defp map_endpoint_error(:error, url_param),
    do: {:error, {:invalid_schedule_credential_endpoint, url_param}}

  defp schedule_param(schedule, url_param) do
    schedule.params
    |> normalize_map()
    |> map_get(url_param)
    |> normalize_optional_string()
  end

  defp parse_https_endpoint(value) when is_binary(value) do
    with %URI{} = uri <- URI.parse(value),
         true <- uri.scheme == "https",
         true <- valid_credential_endpoint_host?(uri.host),
         true <- is_nil(uri.userinfo),
         true <- is_nil(uri.query),
         true <- is_nil(uri.fragment),
         port when is_integer(port) and port > 0 and port <= 65_535 <- uri.port || 443,
         path when is_binary(path) <- uri.path,
         true <- path != "" and path != "/" and not String.ends_with?(path, "/") do
      {:ok, %{host: uri.host, port: port, path: path}}
    else
      _ -> :error
    end
  end

  defp parse_https_endpoint(_value), do: :error

  defp https_origin(value) when is_binary(value) do
    uri = URI.parse(String.trim(value))

    if uri.scheme == "https" and valid_credential_endpoint_host?(uri.host) and
         is_nil(uri.userinfo) and is_binary(uri.authority) do
      "https://" <> uri.authority
    end
  end

  defp https_origin(_value), do: nil

  defp valid_credential_endpoint_host?(host) when is_binary(host) do
    host == String.trim(host) and host != "" and
      String.match?(host, ~r/^[A-Za-z0-9._:-]+$/)
  end

  defp valid_credential_endpoint_host?(_host), do: false

  defp resolve_credential_grant_injection(key, inject, url_param, endpoint, allow, schedule) do
    inject_url_param = normalize_optional_string(map_get(inject, "url_param"))
    methods = string_list(map_get(allow, "methods"))

    cond do
      map_size(inject) == 0 ->
        {:ok, inject}

      inject_url_param != url_param ->
        {:error, {:invalid_schedule_credential_injection_endpoint, key}}

      length(methods) != 1 ->
        {:error, {:invalid_schedule_credential_injection_method, key}}

      true ->
        inject =
          inject
          |> Map.delete("url_param")
          |> Map.put("host", endpoint.host)
          |> Map.put("path", endpoint.path)
          |> Map.put("method", methods |> hd() |> String.upcase())

        resolve_derived_token_endpoint(key, inject, schedule)
    end
  end

  defp resolve_derived_token_endpoint(key, %{"type" => type} = inject, schedule)
       when type in ~w(oauth2_password_bearer oauth2_client_credentials) do
    case normalize_optional_string(map_get(inject, "token_url_param")) do
      nil ->
        {:error, {:missing_schedule_credential_token_endpoint, key}}

      token_url_param ->
        with {:ok, endpoint} <- schedule_token_endpoint(schedule, token_url_param),
             token_method when token_method in ["POST"] <-
               inject
               |> map_get("token_method")
               |> normalize_optional_string()
               |> then(&String.upcase(&1 || "POST")) do
          {:ok,
           inject
           |> Map.delete("token_url_param")
           |> Map.put("token_method", token_method)
           |> Map.put("token_host", endpoint.host)
           |> Map.put("token_port", to_string(endpoint.port))
           |> Map.put("token_path", endpoint.path)}
        else
          {:error, reason} -> {:error, reason}
          _ -> {:error, {:invalid_schedule_credential_token_method, key}}
        end
    end
  end

  defp resolve_derived_token_endpoint(_key, inject, _schedule), do: {:ok, inject}

  defp issue_credential_grant(key, secret_ref, requirement, schedule, assignment, opts) do
    attrs = credential_grant_attrs(key, secret_ref, requirement, schedule, assignment)
    issuer = Keyword.get(opts, :grant_issuer, {__MODULE__, :issue_persisted_credential_grant})

    case call_grant_issuer(issuer, attrs, opts) do
      {:ok, %{} = grant} -> {:ok, normalize_grant_payload(grant)}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_producer_schedule_credential_grant_result, other}}
    end
  end

  defp credential_grant_attrs(key, secret_ref, requirement, schedule, assignment) do
    allow = normalize_map(map_get(requirement, "allow"))

    %{
      secret_ref: secret_ref,
      credential_rule_id:
        map_get(requirement, "credential_rule_id") ||
          map_get(schedule.metadata || %{}, "credential_rule_id"),
      grant_type: map_get(requirement, "grant_type") || "producer_schedule_credential",
      consumer_kind: credential_consumer_kind(schedule),
      consumer_id: credential_consumer_id(schedule, assignment),
      purpose: map_get(requirement, "purpose") || "#{schedule.schedule_id}:run",
      target_kind: map_get(requirement, "target_kind") || "producer_schedule",
      target_id: to_string(schedule.id),
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
      metadata: %{
        "producer_schedule_id" => to_string(schedule.id),
        "schedule_id" => schedule.schedule_id,
        "credential_key" => key,
        "producer_kind" => producer_kind_string(schedule.producer_kind)
      },
      ttl_seconds: timeout_seconds(schedule.contract)
    }
  end

  defp credential_consumer_kind(schedule) do
    case normalize_kind(schedule.producer_kind) do
      :native_addon -> :addon
      _ -> :plugin
    end
  end

  defp credential_consumer_id(schedule, assignment) do
    case normalize_kind(schedule.producer_kind) do
      :native_addon -> to_string(assignment.addon_package_id)
      _ -> to_string(assignment.plugin_package_id)
    end
  end

  defp call_grant_issuer({module, function}, attrs, opts),
    do: apply(module, function, [attrs, opts])

  defp call_grant_issuer(fun, attrs, opts) when is_function(fun, 2), do: fun.(attrs, opts)
  defp call_grant_issuer(fun, attrs, _opts) when is_function(fun, 1), do: fun.(attrs)

  defp normalize_grant_payload(%{"schema" => @credential_grant_schema} = grant), do: grant

  defp normalize_grant_payload(%{schema: @credential_grant_schema} = grant) do
    Map.new(grant, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_grant_payload(%{} = grant), do: CredentialBrokerGrant.to_payload(grant)

  defp put_credential_grants(payload, []), do: payload

  defp put_credential_grants(payload, credential_grants) do
    Map.put(payload, "credential_brokers", credential_grants)
  end

  defp credential_ref_metadata([]) do
    %{"credential_ref_keys" => [], "credential_ref_count" => 0}
  end

  defp credential_ref_metadata(keys) do
    %{"credential_ref_keys" => keys, "credential_ref_count" => length(keys)}
  end

  defp credential_requirements(contract) do
    contract
    |> map_get("credential_requirements")
    |> normalize_requirement_map()
  end

  defp normalize_requirement_map(requirements) when is_map(requirements) do
    Enum.reduce(requirements, %{}, fn {key, value}, acc ->
      key = to_string(key)

      requirement =
        value
        |> normalize_map()
        |> Map.put_new("name", key)

      Map.put(acc, key, requirement)
    end)
  end

  defp normalize_requirement_map(_requirements), do: %{}

  defp ensure_required_credentials(requirements, refs) do
    missing =
      requirements
      |> Enum.filter(fn {_key, requirement} -> required_requirement?(requirement) end)
      |> Enum.map(fn {key, _requirement} -> key end)
      |> Enum.reject(fn key -> present?(Map.get(refs, key)) end)

    case missing do
      [] -> :ok
      missing -> {:error, {:missing_schedule_credentials, missing}}
    end
  end

  defp required_requirement?(requirement) do
    map_get(requirement, "required") == true or map_get(requirement, "required?") == true
  end

  defp normalize_resolution_location(value) when value in [:agent, :control_plane, :hybrid],
    do: value

  defp normalize_resolution_location("control_plane"), do: :control_plane
  defp normalize_resolution_location("hybrid"), do: :hybrid
  defp normalize_resolution_location(_value), do: :agent

  defp normalize_kind(:wasm_plugin), do: :wasm_plugin
  defp normalize_kind("wasm_plugin"), do: :wasm_plugin
  defp normalize_kind(:native_addon), do: :native_addon
  defp normalize_kind("native_addon"), do: :native_addon
  defp normalize_kind(other), do: other

  defp producer_kind_string(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp producer_kind_string(kind) when is_binary(kind), do: kind
  defp producer_kind_string(kind), do: to_string(kind)

  defp dispatch_scope(contract) do
    contract
    |> map_get("dispatch_scope")
    |> normalize_optional_string()
    |> case do
      nil -> @dispatch_scope_assignment
      scope -> scope
    end
  end

  defp target_query_entity(query) when is_binary(query) do
    case Regex.run(~r/^\s*in:([a-zA-Z0-9_]+)/, query) do
      [_, entity] -> ValueUtils.normalize_entity(entity)
      _ -> "devices"
    end
  end

  defp target_query_entity(_query), do: "devices"

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key)
  end

  defp map_get(_map, _key), do: nil

  defp normalize_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_map(_map), do: %{}

  defp string_list(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp string_list(value) when is_binary(value), do: string_list([value])
  defp string_list(_values), do: []

  defp integer_list(values) when is_list(values) do
    values
    |> Enum.map(&parse_integer/1)
    |> Enum.reject(&is_nil/1)
  end

  defp integer_list(value) when is_integer(value), do: [value]
  defp integer_list(value) when is_binary(value), do: integer_list([value])
  defp integer_list(_values), do: []

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_integer(_value), do: nil

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_value), do: true

  defp normalize_optional_string(nil), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_optional_string()

  defp normalize_optional_string(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_optional_string(_value), do: nil

  defp parse_positive_int(value, default) do
    case Integer.parse(String.trim(value)) do
      {int, ""} when int > 0 -> int
      _ -> default
    end
  end
end
