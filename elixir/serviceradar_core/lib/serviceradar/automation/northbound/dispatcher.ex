defmodule ServiceRadar.Automation.Northbound.Dispatcher do
  @moduledoc """
  Dispatches persisted northbound action invocations to concrete providers.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.RunLauncher
  alias ServiceRadar.Automation.Northbound.ActionInvocation
  alias ServiceRadar.Automation.Northbound.ActionInvocationTarget
  alias ServiceRadar.Automation.Northbound.CredentialGrants
  alias ServiceRadar.Automation.Northbound.TargetPayloadContract
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Edge.Crypto
  alias ServiceRadar.Plugins
  alias ServiceRadar.Plugins.PluginAssignment

  require Ash.Query
  require Logger

  @command_type "plugin.run_action"
  @callback_token_header "x-serviceradar-callback-token"
  @callback_signature_header "x-serviceradar-callback-signature"
  @callback_timestamp_header "x-serviceradar-callback-timestamp"
  @callback_hmac_algorithm "hmac-sha256"
  @callback_signature_format "sha256=<hex>"
  @callback_signed_payload "<timestamp>.<raw_body>"
  @default_callback_tolerance_seconds 300

  @spec dispatch_invocation(ActionInvocation.t() | String.t(), keyword()) ::
          {:ok, ActionInvocation.t()} | {:error, term()}
  def dispatch_invocation(invocation_or_id, opts \\ [])

  def dispatch_invocation(%ActionInvocation{} = invocation, opts) do
    system_actor = Keyword.get(opts, :system_actor, SystemActor.system(:northbound_dispatcher))

    with {:ok, invocation} <- load_invocation(invocation.id, system_actor),
         :ok <- validate_dispatchable(invocation),
         {:ok, invocation} <- dispatch_by_provider(invocation, opts, system_actor) do
      {:ok, invocation}
    else
      {:error, reason} ->
        _ = mark_invocation_failed(invocation, reason, system_actor)
        {:error, reason}
    end
  end

  def dispatch_invocation(invocation_id, opts) when is_binary(invocation_id) do
    system_actor = Keyword.get(opts, :system_actor, SystemActor.system(:northbound_dispatcher))

    with {:ok, invocation} <- load_invocation(invocation_id, system_actor) do
      dispatch_invocation(invocation, opts)
    end
  end

  def dispatch_invocation(_invocation, _opts), do: {:error, :invalid_invocation}

  @spec dispatch_poll(ActionInvocationTarget.t() | String.t(), keyword()) ::
          {:ok, ActionInvocationTarget.t()} | {:error, term()}
  def dispatch_poll(target_or_id, opts \\ [])

  def dispatch_poll(%ActionInvocationTarget{} = target, opts) do
    system_actor = Keyword.get(opts, :system_actor, SystemActor.system(:northbound_dispatcher))

    with {:ok, target} <- load_target(target.id, system_actor),
         :ok <- validate_pollable(target),
         {:ok, invocation} <- load_invocation(target.invocation_id, system_actor),
         :ok <- validate_pollable_invocation(invocation),
         {:ok, assignment} <- resolve_plugin_assignment(invocation, system_actor),
         {:ok, _command} <-
           dispatch_poll_to_assignment(invocation, target, assignment, opts, system_actor),
         {:ok, target} <- mark_target_poll_dispatched(target, system_actor),
         {:ok, _invocation} <- mark_invocation_polling(invocation, system_actor) do
      {:ok, target}
    end
  end

  def dispatch_poll(target_id, opts) when is_binary(target_id) do
    system_actor = Keyword.get(opts, :system_actor, SystemActor.system(:northbound_dispatcher))

    with {:ok, target} <- load_target(target_id, system_actor) do
      dispatch_poll(target, opts)
    end
  end

  def dispatch_poll(_target, _opts), do: {:error, :invalid_target}

  defp load_invocation(id, actor) do
    case ActionInvocation.get_by_id(id, actor: actor) do
      {:ok, nil} -> {:error, :invocation_not_found}
      {:ok, invocation} -> {:ok, invocation}
      {:error, reason} -> {:error, reason}
      nil -> {:error, :invocation_not_found}
    end
  end

  defp load_target(id, actor) do
    case ActionInvocationTarget.get_by_id(id, actor: actor) do
      {:ok, nil} -> {:error, :target_not_found}
      {:ok, target} -> {:ok, target}
      {:error, reason} -> {:error, reason}
      nil -> {:error, :target_not_found}
    end
  end

  defp validate_dispatchable(%ActionInvocation{state: :pending}), do: :ok

  defp validate_dispatchable(%ActionInvocation{state: state}),
    do: {:error, {:not_dispatchable, state}}

  defp validate_pollable(%ActionInvocationTarget{status: status})
       when status in [:polling, :result_fetching], do: :ok

  defp validate_pollable(%ActionInvocationTarget{status: status}),
    do: {:error, {:not_pollable, status}}

  defp validate_pollable_invocation(%ActionInvocation{state: state})
       when state in [:running, :polling, :result_fetching],
       do: :ok

  defp validate_pollable_invocation(%ActionInvocation{state: :canceled}),
    do: {:error, :invocation_canceled}

  defp validate_pollable_invocation(%ActionInvocation{state: state}),
    do: {:error, {:invocation_not_pollable, state}}

  defp dispatch_by_provider(
         %ActionInvocation{provider: %{provider_type: :wasm_plugin}} = invocation,
         opts,
         actor
       ) do
    with {:ok, assignment} <- resolve_plugin_assignment(invocation, actor),
         {:ok, command} <- dispatch_to_assignment(invocation, assignment, opts, actor),
         {:ok, invocation} <- mark_invocation_dispatched(invocation, command, assignment, actor),
         :ok <- mark_targets_running(invocation, actor) do
      {:ok, invocation}
    end
  end

  defp dispatch_by_provider(
         %ActionInvocation{provider: %{provider_type: :ansible}} = invocation,
         _opts,
         actor
       ) do
    with {:ok, playbook_id} <- ansible_playbook_id(invocation),
         {:ok, device_uids} <- ansible_device_uids(invocation),
         {:ok, run} <- launch_ansible_run(invocation, playbook_id, device_uids, actor),
         {:ok, invocation} <- mark_ansible_dispatched(invocation, run, actor),
         {:ok, invocation} <- mark_invocation_running(invocation, actor),
         :ok <- mark_targets_running(invocation, actor) do
      {:ok, invocation}
    end
  end

  defp dispatch_by_provider(
         %ActionInvocation{provider: %{provider_type: provider_type}},
         _opts,
         _actor
       ) do
    {:error, {:unsupported_provider_type, provider_type}}
  end

  defp dispatch_by_provider(_invocation, _opts, _actor), do: {:error, :provider_not_loaded}

  defp resolve_plugin_assignment(%ActionInvocation{provider: provider} = invocation, actor) do
    with :ok <- validate_wasm_provider(provider),
         {:ok, assignments} <- list_package_assignments(provider.plugin_package_id, actor) do
      select_assignment(assignments, preferred_agent_ids(invocation))
    end
  end

  defp validate_wasm_provider(%{provider_type: :wasm_plugin, plugin_package_id: package_id})
       when is_binary(package_id),
       do: :ok

  defp validate_wasm_provider(%{provider_type: provider_type}),
    do: {:error, {:unsupported_provider_type, provider_type}}

  defp validate_wasm_provider(_provider), do: {:error, :provider_not_loaded}

  defp ansible_playbook_id(%ActionInvocation{descriptor: %{metadata: metadata}}) do
    case map_get(metadata, "playbook_id") do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing_ansible_playbook_id}
    end
  end

  defp ansible_device_uids(%ActionInvocation{target_snapshots: snapshots})
       when is_list(snapshots) do
    uids =
      snapshots
      |> Enum.map(&map_get(&1, "device_uid"))
      |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
      |> Enum.uniq()

    if uids == [], do: {:error, :targets_required}, else: {:ok, uids}
  end

  defp ansible_device_uids(_invocation), do: {:error, :targets_required}

  defp launch_ansible_run(invocation, playbook_id, device_uids, actor) do
    RunLauncher.launch(
      %{
        playbook_id: playbook_id,
        device_uids: device_uids,
        extra_vars: ansible_extra_vars(invocation),
        requested_by_actor_id: invocation.requested_by_actor_id,
        northbound_invocation_id: invocation.id
      },
      actor: actor
    )
  end

  defp ansible_extra_vars(%ActionInvocation{input_values: input_values})
       when is_map(input_values) do
    case map_get(input_values, "extra_vars") do
      %{} = extra_vars -> extra_vars
      _ -> %{}
    end
  end

  defp ansible_extra_vars(_invocation), do: %{}

  defp list_package_assignments(plugin_package_id, actor) do
    PluginAssignment
    |> Ash.Query.for_read(:by_package, %{plugin_package_id: plugin_package_id}, actor: actor)
    |> Ash.read(actor: actor, domain: Plugins)
  end

  defp select_assignment([], _preferred_agent_ids), do: {:error, :no_enabled_plugin_assignment}

  defp select_assignment(assignments, preferred_agent_ids) do
    preferred =
      Enum.find(assignments, fn assignment ->
        assignment.agent_uid in preferred_agent_ids
      end)

    {:ok, preferred || List.first(assignments)}
  end

  defp preferred_agent_ids(%ActionInvocation{target_snapshots: snapshots})
       when is_list(snapshots) do
    snapshots
    |> Enum.flat_map(fn snapshot ->
      [
        map_get(snapshot, "agent_id"),
        map_get(snapshot, "device_agent_id")
      ]
    end)
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.uniq()
  end

  defp preferred_agent_ids(_invocation), do: []

  defp dispatch_to_assignment(invocation, assignment, opts, actor) do
    with {:ok, target_payloads} <- prepare_callback_targets(invocation, actor),
         {:ok, credential_grants} <- CredentialGrants.prepare_launch(invocation, assignment, opts) do
      payload = build_payload(invocation, assignment, target_payloads, credential_grants)
      ttl_seconds = invocation.descriptor.timeout_seconds || assignment.timeout_seconds || 60
      command_bus = Keyword.get(opts, :command_bus, AgentCommandBus)

      command_bus.dispatch(
        assignment.agent_uid,
        @command_type,
        payload,
        ttl_seconds: ttl_seconds,
        required_partition: assignment.partition_id,
        source: :automation,
        actor: actor,
        context:
          Map.merge(credential_grants.context, %{
            northbound_invocation_id: invocation.id,
            northbound_descriptor_id: invocation.descriptor_id,
            northbound_provider_id: invocation.provider_id,
            plugin_assignment_id: assignment.id,
            plugin_package_id: assignment.plugin_package_id,
            action_id: invocation.action_id
          })
      )
    end
  end

  defp dispatch_poll_to_assignment(invocation, target, assignment, opts, actor) do
    with {:ok, credential_grants} <-
           CredentialGrants.prepare_poll(invocation, target, assignment, opts) do
      payload = build_poll_payload(invocation, target, assignment, credential_grants)
      ttl_seconds = invocation.descriptor.timeout_seconds || assignment.timeout_seconds || 60
      command_bus = Keyword.get(opts, :command_bus, AgentCommandBus)

      command_bus.dispatch(
        assignment.agent_uid,
        @command_type,
        payload,
        ttl_seconds: ttl_seconds,
        required_partition: assignment.partition_id,
        source: :automation,
        actor: actor,
        context:
          Map.merge(credential_grants.context, %{
            northbound_invocation_id: invocation.id,
            northbound_invocation_target_id: target.id,
            northbound_descriptor_id: invocation.descriptor_id,
            northbound_provider_id: invocation.provider_id,
            plugin_assignment_id: assignment.id,
            plugin_package_id: assignment.plugin_package_id,
            action_id: invocation.action_id,
            action_phase: "poll"
          })
      )
    end
  end

  defp build_payload(invocation, assignment, target_payloads, credential_grants) do
    target_payloads = TargetPayloadContract.apply(invocation.descriptor, target_payloads)

    base_payload = %{
      "schema" => "serviceradar.northbound_action_invocation.v1",
      "phase" => "launch",
      "invocation_id" => invocation.id,
      "provider_id" => invocation.provider_id,
      "descriptor_id" => invocation.descriptor_id,
      "action_id" => invocation.action_id,
      "action_version" => invocation.action_version,
      "descriptor_hash" => invocation.descriptor_hash,
      "result_schema_version" => invocation.descriptor.result_schema_version,
      "plugin_assignment_id" => assignment.id,
      "plugin_package_id" => assignment.plugin_package_id,
      "targets" => target_payloads,
      "input_values" => invocation.input_values || %{},
      "redacted_input_values" => invocation.redacted_input_values || %{},
      "requested_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "metadata" => Map.put(invocation.metadata || %{}, "dispatch_agent_id", assignment.agent_uid)
    }

    merge_credential_grants(base_payload, credential_grants)
  end

  defp build_poll_payload(invocation, target, assignment, credential_grants) do
    target_payloads =
      TargetPayloadContract.apply(invocation.descriptor, [
        target_snapshot_with_callback(target, nil)
      ])

    base_payload = %{
      "schema" => "serviceradar.northbound_action_invocation.v1",
      "phase" => "poll",
      "invocation_id" => invocation.id,
      "invocation_target_id" => target.id,
      "provider_id" => invocation.provider_id,
      "descriptor_id" => invocation.descriptor_id,
      "action_id" => invocation.action_id,
      "action_version" => invocation.action_version,
      "descriptor_hash" => invocation.descriptor_hash,
      "result_schema_version" => invocation.descriptor.result_schema_version,
      "plugin_assignment_id" => assignment.id,
      "plugin_package_id" => assignment.plugin_package_id,
      "targets" => target_payloads,
      "input_values" => invocation.input_values || %{},
      "redacted_input_values" => invocation.redacted_input_values || %{},
      "continuation_state" => target.continuation_state || %{},
      "external_correlation_id" =>
        target.external_correlation_id || invocation.external_correlation_id,
      "poll_attempt_count" => target.poll_attempt_count || 0,
      "requested_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "metadata" =>
        invocation.metadata
        |> normalize_map()
        |> Map.merge(%{
          "dispatch_agent_id" => assignment.agent_uid,
          "action_phase" => "poll",
          "invocation_target_id" => target.id
        })
    }

    merge_credential_grants(base_payload, credential_grants)
  end

  defp merge_credential_grants(payload, %{payload_fields: fields, context: context}) do
    credential_metadata =
      context
      |> normalize_map()
      |> Map.take(["credential_broker_grant_ids"])

    payload
    |> Map.merge(fields || %{})
    |> Map.update!("metadata", &Map.merge(&1 || %{}, credential_metadata))
  end

  defp prepare_callback_targets(invocation, actor) do
    targets = list_targets(invocation.id, actor)

    if targets == [] do
      {:ok, invocation.target_snapshots || []}
    else
      auth_config = callback_auth_config(invocation)

      {:ok, Enum.map(targets, &prepare_callback_target(&1, auth_config, actor))}
    end
  end

  defp prepare_callback_target(target, auth_config, actor) do
    token = callback_token()
    signing_secret = callback_signing_secret(auth_config)
    callback = callback_metadata(target, token, auth_config, signing_secret)

    _ =
      ActionInvocationTarget.prepare_callback(
        target,
        callback_persistence_attrs(callback, token, auth_config, signing_secret),
        actor: actor
      )

    target_snapshot_with_callback(target, callback)
  end

  defp target_snapshot_with_callback(target, callback) do
    callback = callback || callback_metadata(target, nil, callback_auth_config(target), nil)

    target.target_snapshot
    |> normalize_map()
    |> Map.put("northbound_job_id", target.id)
    |> Map.put("callback", callback)
  end

  defp callback_metadata(target, token, auth_config, signing_secret) do
    path = "/api/northbound/action-callbacks/#{target.id}"

    metadata = %{
      "job_id" => target.id,
      "path" => path,
      "url" => callback_url(path),
      "token" => token,
      "token_header" => @callback_token_header,
      "auth_mode" => Atom.to_string(auth_config.mode)
    }

    metadata =
      if hmac_callback?(auth_config.mode) do
        Map.merge(metadata, %{
          "signature_algorithm" => @callback_hmac_algorithm,
          "signature_header" => @callback_signature_header,
          "timestamp_header" => @callback_timestamp_header,
          "signature_format" => @callback_signature_format,
          "signed_payload" => @callback_signed_payload,
          "timestamp_tolerance_seconds" => auth_config.timestamp_tolerance_seconds,
          "signing_secret" => signing_secret
        })
      else
        metadata
      end

    metadata
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp callback_persistence_attrs(callback, token, auth_config, signing_secret) do
    attrs = %{
      callback_token_hash: sha256_hex(token),
      callback_url: callback["url"],
      callback_auth_mode: auth_config.mode
    }

    if hmac_callback?(auth_config.mode) and is_binary(signing_secret) and signing_secret != "" do
      Map.merge(attrs, %{
        callback_hmac_secret_ciphertext: Crypto.encrypt(signing_secret),
        callback_hmac_algorithm: @callback_hmac_algorithm,
        callback_hmac_signature_header: @callback_signature_header,
        callback_hmac_timestamp_header: @callback_timestamp_header,
        callback_hmac_timestamp_tolerance_seconds: auth_config.timestamp_tolerance_seconds
      })
    else
      attrs
    end
  end

  defp callback_auth_config(%ActionInvocation{} = invocation) do
    metadata_candidates = [
      normalize_map(invocation.descriptor && invocation.descriptor.metadata),
      normalize_map(invocation.provider && invocation.provider.metadata),
      normalize_map(invocation.metadata)
    ]

    %{
      mode: callback_auth_mode(metadata_candidates),
      timestamp_tolerance_seconds: callback_timestamp_tolerance(metadata_candidates)
    }
  end

  defp callback_auth_config(%ActionInvocationTarget{} = target) do
    %{
      mode: target.callback_auth_mode || :token,
      timestamp_tolerance_seconds:
        target.callback_hmac_timestamp_tolerance_seconds || @default_callback_tolerance_seconds
    }
  end

  defp callback_auth_mode(metadata_candidates) when is_list(metadata_candidates) do
    metadata_candidates
    |> Enum.find_value(&metadata_callback_auth_mode/1)
    |> case do
      mode when mode in [:token, :hmac_optional, :hmac_required] -> mode
      _ -> :token
    end
  end

  defp metadata_callback_auth_mode(metadata) when is_map(metadata) do
    Enum.find_value(
      [
        map_get(metadata, "callback_auth_mode"),
        map_get(metadata, "callback_hmac_mode"),
        map_get(metadata, "callback_mode"),
        metadata |> map_get("callback") |> map_get("auth_mode"),
        metadata |> map_get("callback") |> map_get("hmac_mode"),
        metadata |> map_get("webhook") |> map_get("auth_mode"),
        metadata |> map_get("webhook") |> map_get("hmac_mode")
      ],
      &normalize_callback_auth_mode/1
    )
  end

  defp metadata_callback_auth_mode(_metadata), do: nil

  defp normalize_callback_auth_mode(value) when is_atom(value),
    do: normalize_callback_auth_mode(Atom.to_string(value))

  defp normalize_callback_auth_mode(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "token" -> :token
      "token_only" -> :token
      "none" -> :token
      "hmac" -> :hmac_required
      "signed" -> :hmac_required
      "hmac-sha256" -> :hmac_required
      "hmac_sha256" -> :hmac_required
      "required" -> :hmac_required
      "hmac_required" -> :hmac_required
      "hmac-required" -> :hmac_required
      "optional" -> :hmac_optional
      "hmac_optional" -> :hmac_optional
      "hmac-optional" -> :hmac_optional
      _ -> nil
    end
  end

  defp normalize_callback_auth_mode(_value), do: nil

  defp callback_timestamp_tolerance(metadata_candidates) when is_list(metadata_candidates) do
    metadata_candidates
    |> Enum.find_value(&metadata_callback_timestamp_tolerance/1)
    |> case do
      seconds when is_integer(seconds) and seconds > 0 -> min(seconds, 86_400)
      _ -> @default_callback_tolerance_seconds
    end
  end

  defp metadata_callback_timestamp_tolerance(metadata) when is_map(metadata) do
    Enum.find_value(
      [
        map_get(metadata, "callback_timestamp_tolerance_seconds"),
        map_get(metadata, "callback_hmac_timestamp_tolerance_seconds"),
        metadata |> map_get("callback") |> map_get("timestamp_tolerance_seconds"),
        metadata |> map_get("webhook") |> map_get("timestamp_tolerance_seconds")
      ],
      &positive_integer/1
    )
  end

  defp metadata_callback_timestamp_tolerance(_metadata), do: nil

  defp positive_integer(value) when is_integer(value) and value > 0, do: value

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer > 0 -> integer
      _ -> nil
    end
  end

  defp positive_integer(_value), do: nil

  defp hmac_callback?(mode), do: mode in [:hmac_optional, :hmac_required]

  defp callback_signing_secret(%{mode: mode}) when mode in [:hmac_optional, :hmac_required],
    do: callback_token()

  defp callback_signing_secret(_auth_config), do: nil

  defp callback_url(path) do
    case callback_base_url() do
      nil -> nil
      base_url -> base_url |> URI.parse() |> URI.merge(path) |> URI.to_string()
    end
  end

  defp callback_base_url do
    Application.get_env(:serviceradar_core, :northbound_callback_base_url) ||
      System.get_env("SERVICERADAR_NORTHBOUND_CALLBACK_BASE_URL")
  end

  defp callback_token do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp sha256_hex(value) when is_binary(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.encode16(case: :lower)
  end

  defp mark_invocation_dispatched(invocation, command, assignment, actor) do
    metadata =
      invocation.metadata
      |> normalize_map()
      |> Map.merge(%{
        "agent_command_id" => command_id(command),
        "dispatch_agent_id" => assignment.agent_uid,
        "plugin_assignment_id" => assignment.id
      })

    ActionInvocation.record_dispatch(invocation, %{metadata: metadata}, actor: actor)
  end

  defp mark_ansible_dispatched(invocation, run, actor) do
    metadata =
      invocation.metadata
      |> normalize_map()
      |> Map.merge(%{
        "ansible_playbook_run_id" => run.id,
        "ansible_controller_id" => run.controller_id,
        "ansible_awx_job_id" => run.awx_job_id
      })

    ActionInvocation.record_dispatch(invocation, %{metadata: metadata}, actor: actor)
  end

  defp mark_invocation_running(invocation, actor) do
    ActionInvocation.record_running(invocation, actor: actor)
  end

  defp mark_invocation_polling(invocation, actor) do
    ActionInvocation.record_polling(invocation, %{}, actor: actor)
  end

  defp mark_target_poll_dispatched(target, actor) do
    attrs = %{
      last_poll_at: DateTime.utc_now(),
      poll_attempt_count: (target.poll_attempt_count || 0) + 1
    }

    case target.status do
      :result_fetching ->
        ActionInvocationTarget.record_result_fetching(target, attrs, actor: actor)

      _ ->
        ActionInvocationTarget.record_polling(target, attrs, actor: actor)
    end
  end

  defp mark_targets_running(invocation, actor) do
    invocation.id
    |> list_targets(actor)
    |> Enum.each(fn target ->
      _ = ActionInvocationTarget.record_running(target, %{}, actor: actor)
    end)

    :ok
  end

  defp mark_invocation_failed(%ActionInvocation{} = invocation, reason, actor) do
    _ =
      ActionInvocation.record_failed(
        invocation,
        %{
          error_class: "dispatch_failed",
          error_message: inspect(reason),
          result_summary: %{"status" => "failed", "reason" => inspect(reason)}
        },
        actor: actor
      )

    invocation.id
    |> list_targets(actor)
    |> Enum.each(fn target ->
      _ =
        ActionInvocationTarget.record_failed(
          target,
          %{result: %{"reason" => inspect(reason)}},
          actor: actor
        )
    end)
  end

  defp mark_invocation_failed(_invocation, _reason, _actor), do: :ok

  defp list_targets(invocation_id, actor) do
    case ActionInvocationTarget.list_for_invocation(invocation_id, actor: actor) do
      {:ok, targets} -> targets
      _ -> []
    end
  end

  defp command_id(%{id: id}), do: id
  defp command_id(%{command_id: id}), do: id
  defp command_id(command), do: inspect(command)

  defp normalize_map(map) when is_map(map), do: map
  defp normalize_map(_), do: %{}

  defp map_get(map, key) when is_map(map), do: Map.get(map, key)
  defp map_get(_map, _key), do: nil
end
