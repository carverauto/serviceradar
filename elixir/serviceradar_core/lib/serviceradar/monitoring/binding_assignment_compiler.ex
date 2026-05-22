defmodule ServiceRadar.Monitoring.BindingAssignmentCompiler do
  @moduledoc """
  Materializes active monitoring bindings into runtime plugin assignments.

  The compiler keeps the declarative monitoring model as the source of truth:
  a binding selects targets, each target becomes a stable `CheckInstance`, and
  the selected plugin package receives concrete check targets through the
  existing `serviceradar.plugin_inputs.v1` assignment payload.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Monitoring.CheckInstance
  alias ServiceRadar.Monitoring.CredentialPolicyCompiler
  alias ServiceRadar.Monitoring.MonitoredService
  alias ServiceRadar.Monitoring.MonitoringBinding
  alias ServiceRadar.Monitoring.ServiceGroupMembership
  alias ServiceRadar.Plugins.MapUtils
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Plugins.ValueUtils

  require Ash.Query

  @source :monitoring_binding
  @policy_version 1
  @default_chunk_size 100

  @type reconcile_result :: %{
          binding_id: String.t(),
          targets: non_neg_integer(),
          check_instances: non_neg_integer(),
          desired_assignments: non_neg_integer(),
          upserted: non_neg_integer(),
          unchanged: non_neg_integer(),
          disabled: non_neg_integer(),
          skipped_targets: non_neg_integer()
        }

  @spec reconcile_binding(String.t() | MonitoringBinding.t(), keyword()) ::
          {:ok, reconcile_result()} | {:error, term()}
  def reconcile_binding(binding_or_id, opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:monitoring_binding_assignment_compiler))

    with {:ok, %MonitoringBinding{} = binding} <- load_binding(binding_or_id, actor),
         :ok <- require_active_binding(binding),
         {:ok, %PluginPackage{} = package} <- load_approved_package(binding, actor),
         {:ok, descriptor} <- descriptor_for_binding(binding, package),
         {:ok, target_rows} <- resolve_targets(binding, actor),
         {:ok, materialized} <-
           materialize_targets(
             binding,
             target_rows,
             actor,
             Keyword.put(opts, :check_descriptor, descriptor)
           ),
         {:ok, specs} <- build_assignment_specs(binding, package, materialized, opts),
         {:ok, stats} <- reconcile_assignments(binding, package, specs, actor),
         {:ok, _binding} <- record_reconcile(binding, materialized, specs, stats, actor) do
      {:ok,
       %{
         binding_id: binding.id,
         targets: length(target_rows),
         check_instances: length(materialized.check_instances),
         desired_assignments: length(specs),
         upserted: stats.upserted,
         unchanged: stats.unchanged,
         disabled: stats.disabled,
         skipped_targets: materialized.skipped_targets
       }}
    end
  end

  defp load_binding(%MonitoringBinding{} = binding, _actor), do: {:ok, binding}

  defp load_binding(id, actor) when is_binary(id) do
    MonitoringBinding.get_by_id(id, actor: actor)
  end

  defp load_binding(_value, _actor), do: {:error, :invalid_binding}

  defp require_active_binding(%MonitoringBinding{status: :active}), do: :ok

  defp require_active_binding(%MonitoringBinding{status: status}),
    do: {:error, {:binding_not_active, status}}

  defp load_approved_package(%MonitoringBinding{capability_kind: :builtin}, _actor),
    do: {:error, :builtin_bindings_not_supported}

  defp load_approved_package(%MonitoringBinding{plugin_package_id: nil}, _actor),
    do: {:error, :missing_plugin_package}

  defp load_approved_package(%MonitoringBinding{plugin_package_id: package_id}, actor) do
    PluginPackage
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^package_id)
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, %PluginPackage{status: :approved} = package} -> {:ok, package}
      {:ok, %PluginPackage{}} -> {:error, :plugin_package_not_approved}
      {:ok, nil} -> {:error, :plugin_package_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp descriptor_for_binding(%MonitoringBinding{} = binding, %PluginPackage{} = package) do
    descriptors =
      package.check_descriptors
      |> map_value("items", [])
      |> List.wrap()

    descriptors
    |> Enum.find(&descriptor_matches?(&1, binding))
    |> case do
      nil -> {:error, :descriptor_not_declared_by_package}
      descriptor -> {:ok, MapUtils.stringify_keys(descriptor)}
    end
  end

  defp descriptor_matches?(descriptor, %MonitoringBinding{} = binding) when is_map(descriptor) do
    ValueUtils.string_value(descriptor, [:descriptor_id, "descriptor_id"]) ==
      binding.descriptor_id and
      ValueUtils.string_value(descriptor, [:version, "version"]) == binding.descriptor_version
  end

  defp descriptor_matches?(_descriptor, _binding), do: false

  defp resolve_targets(
         %MonitoringBinding{target_set_type: :service_group, service_group_id: group_id},
         actor
       )
       when not is_nil(group_id) do
    with {:ok, memberships} <-
           ServiceGroupMembership
           |> Ash.Query.for_read(:by_group, %{service_group_id: group_id})
           |> Ash.read(actor: actor) do
      service_ids = Enum.map(memberships, & &1.monitored_service_id)
      read_active_services(service_ids, actor)
    end
  end

  defp resolve_targets(
         %MonitoringBinding{target_set_type: :explicit_services, target_filters: filters},
         actor
       ) do
    filters
    |> map_value("service_ids", [])
    |> read_active_services(actor)
  end

  defp resolve_targets(%MonitoringBinding{target_set_type: unsupported}, _actor) do
    {:error, {:unsupported_target_set_type, unsupported}}
  end

  defp read_active_services([], _actor), do: {:ok, []}

  defp read_active_services(service_ids, actor) when is_list(service_ids) do
    ids =
      service_ids
      |> Enum.map(&to_string/1)
      |> Enum.reject(&ValueUtils.blank_string?/1)

    MonitoredService
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id in ^ids and status == :active)
    |> Ash.Query.sort(display_name: :asc)
    |> Ash.read(actor: actor)
  end

  defp materialize_targets(%MonitoringBinding{} = binding, targets, actor, opts) do
    now =
      opts
      |> Keyword.get(:materialized_at, DateTime.utc_now())
      |> truncate_datetime()

    Enum.reduce_while(targets, {:ok, %{check_instances: [], skipped_targets: 0}}, fn target,
                                                                                     {:ok, acc} ->
      case materialize_target(binding, target, actor, now, opts) do
        {:ok, nil} ->
          {:cont, {:ok, %{acc | skipped_targets: acc.skipped_targets + 1}}}

        {:ok, %CheckInstance{} = check_instance} ->
          {:cont, {:ok, %{acc | check_instances: acc.check_instances ++ [check_instance]}}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp materialize_target(
         %MonitoringBinding{} = binding,
         %MonitoredService{} = service,
         actor,
         now,
         opts
       ) do
    case agent_uid_for(binding, service) do
      nil ->
        {:ok, nil}

      agent_uid ->
        check_key = check_key(binding, "service", service.id, agent_uid)
        descriptor = Keyword.get(opts, :check_descriptor, %{})

        with :ok <- validate_service_target_descriptor(service, descriptor),
             {:ok, credential_policy_snapshot} <-
               CredentialPolicyCompiler.compile_for_service(
                 binding,
                 service,
                 agent_uid,
                 check_key,
                 Keyword.put(opts, :actor, actor)
               ) do
          attrs = %{
            check_key: check_key,
            monitoring_binding_id: binding.id,
            monitored_service_id: service.id,
            device_uid: service.device_uid,
            descriptor_id: binding.descriptor_id,
            descriptor_version: binding.descriptor_version,
            capability_kind: binding.capability_kind,
            plugin_package_id: binding.plugin_package_id,
            vantage_kind: :agent,
            vantage_id: agent_uid,
            agent_id: known_agent_id(agent_uid, actor),
            target_snapshot: service_target_snapshot(service),
            credential_policy_snapshot: credential_policy_snapshot,
            event_policy_snapshot: binding.event_policy,
            metadata: %{
              "source" => "monitoring_binding",
              "monitoring_binding_id" => binding.id,
              "target_kind" => "service",
              "materialized_at" => DateTime.to_iso8601(now)
            }
          }

          CheckInstance.materialize(attrs, actor: actor)
        end
    end
  end

  defp validate_service_target_descriptor(%MonitoredService{} = service, descriptor) do
    descriptor = MapUtils.stringify_keys(descriptor || %{})
    snapshot = service_target_snapshot(service)

    with :ok <- descriptor_allows_value(descriptor, "target_kinds", "service"),
         :ok <-
           descriptor_allows_value(
             descriptor,
             "service_kinds",
             atom_to_string(service.service_kind)
           ),
         :ok <- descriptor_allows_value(descriptor, "protocols", service.protocol) do
      descriptor
      |> map_value("required_target_fields", [])
      |> List.wrap()
      |> Enum.reduce_while(:ok, fn field, :ok ->
        if nil_or_empty?(Map.get(snapshot, to_string(field))) do
          {:halt, {:error, {:missing_required_target_field, to_string(field)}}}
        else
          {:cont, :ok}
        end
      end)
    end
  end

  defp descriptor_allows_value(descriptor, key, value) do
    allowed =
      descriptor
      |> map_value(key, [])
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&ValueUtils.blank_string?/1)

    cond do
      allowed == [] -> :ok
      ValueUtils.blank_string?(value) -> {:error, {:descriptor_target_value_missing, key}}
      to_string(value) in allowed -> :ok
      true -> {:error, {:descriptor_target_value_not_allowed, key, value}}
    end
  end

  defp agent_uid_for(
         %MonitoringBinding{agent_scope_type: :agent, agent_scope_value: value},
         _service
       )
       when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp agent_uid_for(%MonitoringBinding{agent_scope_type: :any}, %MonitoredService{} = service) do
    service.metadata
    |> MapUtils.stringify_keys()
    |> ValueUtils.string_value(["agent_uid", "agent_id", "vantage_id"])
  end

  defp agent_uid_for(_binding, _service), do: nil

  defp known_agent_id(agent_uid, actor) do
    case Agent.get_by_uid(agent_uid, actor: actor) do
      {:ok, %Agent{uid: uid}} -> uid
      _ -> nil
    end
  end

  defp build_assignment_specs(
         %MonitoringBinding{} = binding,
         %PluginPackage{} = package,
         materialized,
         opts
       ) do
    generated_at = generated_at(binding, opts)
    chunk_size = Keyword.get(opts, :chunk_size, @default_chunk_size)

    materialized.check_instances
    |> Enum.group_by(& &1.vantage_id)
    |> Enum.sort_by(fn {agent_uid, _checks} -> agent_uid end)
    |> Enum.reduce_while({:ok, []}, fn {agent_uid, checks}, {:ok, acc} ->
      base_payload = %{
        "policy_id" => policy_id(binding),
        "policy_version" => @policy_version,
        "agent_id" => agent_uid,
        "generated_at" => generated_at,
        "template" => %{
          "source" => "monitoring_binding",
          "monitoring_binding_id" => binding.id,
          "descriptor_id" => binding.descriptor_id,
          "descriptor_version" => binding.descriptor_version,
          "plugin_package_id" => package.id
        }
      }

      input = %{
        name: "monitoring_binding:#{binding.id}",
        entity: "monitoring_checks",
        query: "monitoring_binding_id=#{binding.id}",
        rows: Enum.map(checks, &check_item(binding, &1))
      }

      case ServiceRadar.Plugins.PluginInputPayloadBuilder.build_payloads(base_payload, [input],
             chunk_size: chunk_size
           ) do
        {:ok, payloads} ->
          specs = Enum.map(payloads, &assignment_spec(binding, package, agent_uid, &1))
          {:cont, {:ok, acc ++ specs}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp check_item(%MonitoringBinding{} = binding, %CheckInstance{} = check_instance) do
    %{
      "uid" => check_instance.id,
      "check_instance_id" => check_instance.id,
      "check_key" => check_instance.check_key,
      "monitoring_binding_id" => binding.id,
      "descriptor_id" => binding.descriptor_id,
      "descriptor_version" => binding.descriptor_version,
      "target_kind" => map_value(check_instance.metadata, "target_kind", "service"),
      "target" => check_instance.target_snapshot,
      "credential_policy" => check_instance.credential_policy_snapshot,
      "event_policy" => check_instance.event_policy_snapshot
    }
  end

  defp assignment_spec(
         %MonitoringBinding{} = binding,
         %PluginPackage{} = package,
         agent_uid,
         payload
       ) do
    input = hd(payload["inputs"])

    %{
      assignment_key: assignment_key(binding.id, package.id, agent_uid, input),
      agent_uid: agent_uid,
      plugin_package_id: package.id,
      enabled: true,
      interval_seconds: binding.interval_seconds,
      timeout_seconds: binding.timeout_seconds,
      params: payload,
      metadata: %{
        "source" => "monitoring_binding",
        "policy_id" => policy_id(binding),
        "monitoring_binding_id" => binding.id,
        "input_name" => input["name"],
        "input_entity" => input["entity"],
        "chunk_index" => input["chunk_index"],
        "chunk_total" => input["chunk_total"],
        "chunk_hash" => input["chunk_hash"]
      }
    }
  end

  defp reconcile_assignments(
         %MonitoringBinding{} = binding,
         %PluginPackage{} = package,
         specs,
         actor
       ) do
    policy_id = policy_id(binding)

    with {:ok, existing} <- list_existing_assignments(policy_id, actor),
         {:ok, stale_disabled} <- disable_stale_assignments(specs, existing, actor),
         {:ok, upsert_stats} <- upsert_assignments(specs, existing, package, actor) do
      {:ok,
       %{
         upserted: upsert_stats.upserted,
         unchanged: upsert_stats.unchanged,
         disabled: stale_disabled
       }}
    end
  end

  defp list_existing_assignments(policy_id, actor) do
    PluginAssignment
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(source == ^@source and policy_id == ^policy_id)
    |> Ash.read(actor: actor)
  end

  defp disable_stale_assignments(specs, existing, actor) do
    desired_keys = MapSet.new(specs, & &1.assignment_key)

    existing
    |> Enum.reject(&MapSet.member?(desired_keys, &1.source_key))
    |> Enum.reduce_while({:ok, 0}, fn assignment, {:ok, count} ->
      if assignment.enabled do
        case update_assignment(assignment, %{enabled: false}, actor) do
          {:ok, _assignment} -> {:cont, {:ok, count + 1}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      else
        {:cont, {:ok, count}}
      end
    end)
  end

  defp upsert_assignments(specs, existing, package, actor) do
    existing_by_key = Map.new(existing, &{&1.source_key, &1})

    Enum.reduce_while(specs, {:ok, %{upserted: 0, unchanged: 0}}, fn spec, {:ok, stats} ->
      existing_assignment = Map.get(existing_by_key, spec.assignment_key)

      cond do
        is_nil(existing_assignment) ->
          create_spec_assignment(spec, package, stats, actor)

        assignment_matches_spec?(existing_assignment, spec) ->
          {:cont, {:ok, %{stats | unchanged: stats.unchanged + 1}}}

        true ->
          update_spec_assignment(existing_assignment, spec, stats, actor)
      end
    end)
  end

  defp create_spec_assignment(spec, package, stats, actor) do
    with :ok <- disable_manual_duplicate(spec.agent_uid, package.plugin_id, actor),
         {:ok, _assignment} <- create_assignment(spec, actor) do
      {:cont, {:ok, %{stats | upserted: stats.upserted + 1}}}
    else
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp update_spec_assignment(existing, spec, stats, actor) do
    case update_assignment(existing, assignment_attrs(spec), actor) do
      {:ok, _assignment} -> {:cont, {:ok, %{stats | upserted: stats.upserted + 1}}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp create_assignment(spec, actor) do
    PluginAssignment
    |> Ash.Changeset.for_create(
      :create,
      Map.put(assignment_attrs(spec), :agent_uid, spec.agent_uid)
    )
    |> Ash.create(actor: actor)
  end

  defp update_assignment(assignment, attrs, actor) do
    assignment
    |> Ash.Changeset.for_update(:update, attrs)
    |> Ash.update(actor: actor)
  end

  defp assignment_attrs(spec) do
    %{
      plugin_package_id: spec.plugin_package_id,
      source: @source,
      source_key: spec.assignment_key,
      policy_id: spec.metadata["policy_id"],
      enabled: spec.enabled,
      interval_seconds: spec.interval_seconds,
      timeout_seconds: spec.timeout_seconds,
      params: spec.params
    }
  end

  defp disable_manual_duplicate(agent_uid, plugin_id, actor) do
    PluginAssignment
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(
      source == :manual and enabled == true and agent_uid == ^agent_uid and
        plugin_id == ^plugin_id
    )
    |> Ash.read(actor: actor)
    |> case do
      {:ok, assignments} ->
        Enum.reduce_while(assignments, :ok, fn assignment, :ok ->
          case update_assignment(assignment, %{enabled: false}, actor) do
            {:ok, _assignment} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp assignment_matches_spec?(%PluginAssignment{} = assignment, spec) do
    assignment.enabled == spec.enabled and
      assignment.interval_seconds == spec.interval_seconds and
      assignment.timeout_seconds == spec.timeout_seconds and
      assignment.plugin_package_id == spec.plugin_package_id and
      assignment.source == @source and
      assignment.source_key == spec.assignment_key and
      assignment.policy_id == spec.metadata["policy_id"] and
      assignment.params == spec.params
  end

  defp record_reconcile(binding, materialized, specs, stats, actor) do
    summary = %{
      "targets" => length(materialized.check_instances) + materialized.skipped_targets,
      "check_instances" => length(materialized.check_instances),
      "desired_assignments" => length(specs),
      "upserted" => stats.upserted,
      "unchanged" => stats.unchanged,
      "disabled" => stats.disabled,
      "skipped_targets" => materialized.skipped_targets
    }

    binding
    |> Ash.Changeset.for_update(:record_reconcile, %{last_reconcile_summary: summary})
    |> Ash.update(actor: actor)
  end

  defp service_target_snapshot(%MonitoredService{} = service) do
    %{
      "target_kind" => "service",
      "monitored_service_id" => service.id,
      "service_key" => service.service_key,
      "display_name" => service.display_name,
      "service_kind" => atom_to_string(service.service_kind),
      "protocol" => service.protocol,
      "endpoint_url" => service.endpoint_url,
      "host" => service.host,
      "port" => service.port,
      "path" => service.path,
      "device_uid" => service.device_uid,
      "database_name" => service.database_name,
      "tags" => service.tags
    }
    |> Enum.reject(fn {_key, value} -> nil_or_empty?(value) end)
    |> Map.new()
  end

  defp check_key(%MonitoringBinding{} = binding, target_kind, target_id, agent_uid) do
    digest =
      [
        binding.id,
        target_kind,
        target_id,
        agent_uid,
        binding.descriptor_id,
        binding.descriptor_version
      ]
      |> Enum.join(":")
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    "monitoring-binding:#{digest}"
  end

  defp assignment_key(binding_id, package_id, agent_uid, input) do
    payload =
      %{
        source: "monitoring_binding",
        binding_id: binding_id,
        package_id: package_id,
        agent_uid: agent_uid,
        input_name: input["name"],
        chunk_index: input["chunk_index"],
        chunk_hash: input["chunk_hash"]
      }
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))

    Base.encode16(payload, case: :lower)
  end

  defp generated_at(%MonitoringBinding{} = binding, opts) do
    opts
    |> Keyword.get(:generated_at)
    |> case do
      %DateTime{} = value -> DateTime.to_iso8601(value)
      value when is_binary(value) -> value
      _ -> binding.updated_at || binding.inserted_at || DateTime.utc_now()
    end
    |> case do
      %DateTime{} = value -> DateTime.to_iso8601(value)
      value -> value
    end
  end

  defp truncate_datetime(%DateTime{} = value), do: DateTime.truncate(value, :second)
  defp truncate_datetime(value), do: value

  defp policy_id(%MonitoringBinding{id: id}), do: "monitoring_binding:#{id}"

  defp map_value(map, key, default) when is_map(map) and is_binary(key) do
    map = MapUtils.stringify_keys(map)
    Map.get(map, key, default)
  end

  defp map_value(_map, _key, default), do: default

  defp atom_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_to_string(value), do: value

  defp nil_or_empty?(nil), do: true
  defp nil_or_empty?(""), do: true
  defp nil_or_empty?([]), do: true
  defp nil_or_empty?(%{} = value), do: map_size(value) == 0
  defp nil_or_empty?(_value), do: false
end
