defmodule ServiceRadar.Automation.Ansible.AWXResultProjection do
  @moduledoc """
  Schema-specific, secret-free projections for AWX command results.

  AWX API objects contain arbitrary controller-managed metadata, variables,
  module output, and related-resource URLs. None of those objects are safe to
  persist wholesale. This module accepts only the bounded fields needed by the
  ServiceRadar control plane and rebuilds fresh maps from those fields.
  """

  alias ServiceRadar.Automation.Ansible.AwxLaunchContract
  alias ServiceRadar.Automation.Ansible.DispatchMarkerContract
  alias ServiceRadar.Automation.Ansible.Targeting
  alias ServiceRadar.Automation.Ansible.VariableSchema

  @max_id 2_147_483_647
  @max_int64 9_223_372_036_854_775_807
  @max_rows 10_000
  @max_pages 50
  @page_size 200
  @max_survey_fields 100
  @max_event_jobs 10
  @max_events_per_job 10
  @max_legacy_events_per_job 10_000
  @max_stats_hosts 10_000
  @max_ping_topology_rows 1_000
  @max_projected_payload_bytes 3 * 1024 * 1024
  @event_contract_version 2

  @inventory_kinds ["", "smart", "constructed"]
  @job_types ~w(run check)
  @survey_types ~w(text textarea integer float multiplechoice multiselect)
  @handled_events ~w(
    playbook_on_play_start
    playbook_on_task_start
    playbook_on_handler_task_start
    runner_on_ok
    runner_on_failed
    runner_on_skipped
    runner_on_unreachable
    runner_item_on_ok
    runner_item_on_failed
    runner_item_on_skipped
    playbook_on_stats
  )
  @runner_events ~w(
    runner_on_ok
    runner_on_failed
    runner_on_skipped
    runner_on_unreachable
    runner_item_on_ok
    runner_item_on_failed
    runner_item_on_skipped
  )
  @task_events ~w(playbook_on_task_start playbook_on_handler_task_start)
  @stats_keys ~w(ok failures dark skipped changed)

  @type projection_result :: {:ok, map()} | :error

  @spec project(String.t(), term()) :: projection_result()
  def project(verb, payload), do: verb |> do_project(payload) |> enforce_aggregate_budget()

  defp do_project("awx.ping" = verb, payload) do
    with {:ok, shape} <- ping_shape(payload),
         true <- value(payload, :verb) == verb,
         true <- value(payload, :ok) == true,
         {:ok, version} <- bounded_text(value(payload, :version), 64),
         {:ok, active_node} <- bounded_text(value(payload, :active_node), 255),
         :ok <- validate_legacy_ping_topology(shape, payload) do
      {:ok,
       %{
         "verb" => verb,
         "ok" => true,
         "version" => version,
         "active_node" => active_node
       }}
    else
      _ -> :error
    end
  end

  defp do_project("awx.current_user" = verb, payload) do
    expected_keys =
      if is_nil(value(payload, :username)),
        do: ~w(verb ok user_id),
        else: ~w(verb ok user_id username)

    with true <- exact_keys?(payload, expected_keys),
         true <- value(payload, :verb) == verb,
         true <- value(payload, :ok) == true,
         {:ok, user_id} <- positive_integer(value(payload, :user_id)),
         {:ok, username} <- optional_text(value(payload, :username), 150) do
      {:ok,
       maybe_put(%{"verb" => verb, "ok" => true, "user_id" => user_id}, "username", username)}
    else
      _ -> :error
    end
  end

  defp do_project("awx.list_inventories" = verb, payload),
    do: list_projection(verb, payload, &inventory/1, :no_extra)

  defp do_project("awx.list_hosts" = verb, payload),
    do: list_projection(verb, payload, &host/1, :inventory_extra)

  defp do_project("awx.list_inventory_groups" = verb, payload),
    do: list_projection(verb, payload, &inventory_group/1, :inventory_extra)

  defp do_project("awx.list_projects" = verb, payload),
    do: list_projection(verb, payload, &project/1, :no_extra)

  defp do_project("awx.list_templates" = verb, payload),
    do: list_projection(verb, payload, &template/1, :no_extra)

  defp do_project("awx.fetch_template" = verb, payload) do
    with true <- exact_keys?(payload, ~w(verb ok template_id template survey_spec)),
         true <- value(payload, :verb) == verb,
         true <- value(payload, :ok) == true,
         {:ok, template_id} <- positive_integer(value(payload, :template_id)),
         {:ok, template} <- template(value(payload, :template)),
         true <- template["id"] == template_id,
         {:ok, survey_spec} <- survey_spec(value(payload, :survey_spec)) do
      {:ok,
       %{
         "verb" => verb,
         "ok" => true,
         "template_id" => template_id,
         "template" => template,
         "survey_spec" => survey_spec
       }}
    else
      _ -> :error
    end
  end

  # The launch gate needs the complete, secret-free contract rather than a
  # catalog-shaped subset. Re-validate and rebuild the exact typed envelope so
  # no raw AWX object, survey default, credential input, or unrecognized field
  # can cross the durable AgentCommand boundary.
  defp do_project("awx.fetch_launch_preflight", payload) do
    case AwxLaunchContract.from_plugin_result(payload) do
      {:ok, result} ->
        {:ok,
         %{
           "schema" => AwxLaunchContract.result_schema(),
           "verb" => AwxLaunchContract.result_verb(),
           "ok" => true,
           "request_digest" => result.request_digest,
           "preflight" => result.preflight,
           "preflight_digest" => result.preflight_digest
         }}

      _ ->
        :error
    end
  end

  defp do_project("awx.fetch_events_for_jobs" = verb, payload) do
    if has_key?(payload, :contract_version) do
      project_current_event_batch(verb, payload)
    else
      project_legacy_event_batch(verb, payload)
    end
  end

  defp do_project(_verb, _payload), do: :error

  defp project_current_event_batch(verb, payload) do
    with true <- exact_keys?(payload, ~w(verb ok contract_version jobs)),
         true <- value(payload, :verb) == verb,
         true <- value(payload, :ok) == true,
         @event_contract_version <- value(payload, :contract_version),
         {:ok, jobs} <- event_jobs(value(payload, :jobs)) do
      {:ok,
       %{
         "verb" => verb,
         "ok" => true,
         "contract_version" => @event_contract_version,
         "jobs" => jobs
       }}
    else
      _ -> :error
    end
  end

  # Rolling compatibility for the last source contract (AWX package v0.1.5).
  # Legacy controller objects are never retained: every event is projected,
  # arbitrary per-job errors are replaced with a fixed code, and at most one
  # ten-event window is emitted so the normal watermark loop can drain it.
  defp project_legacy_event_batch(verb, payload) do
    with true <- exact_keys?(payload, ~w(verb ok jobs)),
         true <- value(payload, :verb) == verb,
         true <- value(payload, :ok) == true,
         {:ok, jobs} <- legacy_event_jobs(value(payload, :jobs)) do
      {:ok,
       %{
         "verb" => verb,
         "ok" => true,
         "contract_version" => @event_contract_version,
         "jobs" => jobs
       }}
    else
      _ -> :error
    end
  end

  defp enforce_aggregate_budget({:ok, projection}) do
    case Jason.encode_to_iodata(projection) do
      {:ok, encoded} ->
        if IO.iodata_length(encoded) <= @max_projected_payload_bytes,
          do: {:ok, projection},
          else: :error

      _other ->
        :error
    end
  end

  defp enforce_aggregate_budget(:error), do: :error

  defp list_projection(verb, payload, row_projector, extra_policy) do
    expected_keys =
      case extra_policy do
        :no_extra -> ~w(verb ok count pages_walked results)
        :inventory_extra -> ~w(verb ok count pages_walked results extra)
      end

    with true <- exact_keys?(payload, expected_keys),
         true <- value(payload, :verb) == verb,
         true <- value(payload, :ok) == true,
         {:ok, count} <- bounded_integer(value(payload, :count), 0, @max_rows),
         {:ok, pages_walked} <- bounded_integer(value(payload, :pages_walked), 0, @max_pages),
         true <- pages_walked == expected_pages(count),
         {:ok, results} <- project_rows(value(payload, :results), row_projector),
         true <- count == length(results),
         {:ok, extra} <- list_extra(value(payload, :extra), extra_policy) do
      safe = %{
        "verb" => verb,
        "ok" => true,
        "count" => count,
        "pages_walked" => pages_walked,
        "results" => results
      }

      {:ok, if(extra_policy == :inventory_extra, do: Map.put(safe, "extra", extra), else: safe)}
    else
      _ -> :error
    end
  end

  defp expected_pages(0), do: 0
  defp expected_pages(count), do: div(count + @page_size - 1, @page_size)

  defp ping_shape(payload) do
    cond do
      exact_keys?(payload, ~w(verb ok version active_node)) ->
        {:ok, :projected}

      exact_keys?(
        payload,
        ~w(verb ok version active_node install_uuid ha instances groups)
      ) ->
        {:ok, :legacy}

      true ->
        :error
    end
  end

  defp validate_legacy_ping_topology(:projected, _payload), do: :ok

  defp validate_legacy_ping_topology(:legacy, payload) do
    with {:ok, _install_uuid} <- bounded_token(value(payload, :install_uuid), 255),
         {:ok, _ha?} <- boolean(value(payload, :ha)),
         :ok <- ping_instances(value(payload, :instances)),
         :ok <- ping_groups(value(payload, :groups)) do
      :ok
    else
      _ -> :error
    end
  end

  defp ping_instances(instances)
       when is_list(instances) and length(instances) <= @max_ping_topology_rows do
    Enum.reduce_while(instances, :ok, fn instance, :ok ->
      with true <-
             exact_keys?(
               instance,
               ~w(node node_type uuid version capacity heartbeat cpu memory)
             ),
           {:ok, _node} <- bounded_text(value(instance, :node), 255),
           {:ok, _node_type} <- bounded_token(value(instance, :node_type), 64),
           {:ok, _uuid} <- bounded_token(value(instance, :uuid), 255),
           {:ok, _version} <- bounded_text(value(instance, :version), 64),
           {:ok, _capacity} <- bounded_integer(value(instance, :capacity), 0, @max_id),
           {:ok, _heartbeat} <- bounded_text(value(instance, :heartbeat), 128),
           {:ok, _cpu} <- nonnegative_number(value(instance, :cpu)),
           {:ok, _memory} <- bounded_integer(value(instance, :memory), 0, @max_int64) do
        {:cont, :ok}
      else
        _ -> {:halt, :error}
      end
    end)
  end

  defp ping_instances(nil), do: :ok
  defp ping_instances(_instances), do: :error

  defp ping_groups(groups) when is_list(groups) and length(groups) <= @max_ping_topology_rows do
    Enum.reduce_while(groups, :ok, fn group, :ok ->
      with true <- exact_keys?(group, ~w(name capacity instances)),
           {:ok, _name} <- bounded_text(value(group, :name), 255),
           {:ok, _capacity} <- bounded_integer(value(group, :capacity), 0, @max_id),
           :ok <- ping_group_instances(value(group, :instances)) do
        {:cont, :ok}
      else
        _ -> {:halt, :error}
      end
    end)
  end

  defp ping_groups(nil), do: :ok
  defp ping_groups(_groups), do: :error

  defp ping_group_instances(instances)
       when is_list(instances) and length(instances) <= @max_ping_topology_rows do
    if Enum.all?(instances, &match?({:ok, _}, bounded_text(&1, 255))), do: :ok, else: :error
  end

  defp ping_group_instances(_instances), do: :error

  defp project_rows(rows, projector) when is_list(rows) and length(rows) <= @max_rows,
    do: reduce_list(rows, projector)

  defp project_rows(_rows, _projector), do: :error

  defp list_extra(nil, :no_extra), do: {:ok, nil}

  defp list_extra(extra, :inventory_extra) do
    with true <- exact_keys?(extra, ["inventory_id"]),
         {:ok, inventory_id} <- positive_integer(value(extra, :inventory_id)) do
      {:ok, %{"inventory_id" => inventory_id}}
    else
      _ -> :error
    end
  end

  defp list_extra(_extra, _policy), do: :error

  defp inventory(row) when is_map(row) do
    with {:ok, id} <- positive_integer(value(row, :id)),
         {:ok, name} <- bounded_text(value(row, :name), 512, allow_empty?: false),
         {:ok, kind} <- enum(value(row, :kind), @inventory_kinds),
         {:ok, organization} <- optional_positive_integer(value(row, :organization)),
         {:ok, total_hosts} <- bounded_integer(value(row, :total_hosts), 0, @max_id) do
      {:ok,
       maybe_put(
         %{"id" => id, "name" => name, "kind" => kind, "total_hosts" => total_hosts},
         "organization",
         organization
       )}
    else
      _ -> :error
    end
  end

  defp inventory(_row), do: :error

  defp host(row) when is_map(row) do
    with {:ok, id} <- positive_integer(value(row, :id)),
         {:ok, name} <- host_token(value(row, :name)),
         {:ok, inventory_id} <- positive_integer(value(row, :inventory)),
         {:ok, enabled?} <- boolean(value(row, :enabled)) do
      {:ok, %{"id" => id, "name" => name, "inventory" => inventory_id, "enabled" => enabled?}}
    else
      _ -> :error
    end
  end

  defp host(_row), do: :error

  defp inventory_group(row) when is_map(row) do
    with {:ok, id} <- positive_integer(value(row, :id)),
         {:ok, name} <- host_token(value(row, :name)) do
      {:ok, %{"id" => id, "name" => name}}
    else
      _ -> :error
    end
  end

  defp inventory_group(_row), do: :error

  defp project(row) when is_map(row) do
    with {:ok, id} <- positive_integer(value(row, :id)),
         {:ok, name} <- bounded_text(value(row, :name), 512, allow_empty?: false),
         {:ok, organization} <- optional_positive_integer(value(row, :organization)),
         {:ok, status} <- bounded_text(value(row, :status), 64),
         {:ok, scm_type} <- bounded_token(value(row, :scm_type), 64, allow_empty?: true),
         {:ok, scm_revision} <- bounded_token(value(row, :scm_revision), 128, allow_empty?: true),
         {:ok, update_on_launch?} <- project_update_on_launch(row) do
      {:ok,
       maybe_put(
         %{
           "id" => id,
           "name" => name,
           "status" => status,
           "scm_type" => scm_type,
           "scm_revision" => scm_revision,
           "update_on_launch" => update_on_launch?
         },
         "organization",
         organization
       )}
    else
      _ -> :error
    end
  end

  defp project(_row), do: :error

  defp project_update_on_launch(row) do
    projected? = has_key?(row, :update_on_launch)
    legacy? = has_key?(row, :scm_update_on_launch)

    case {projected?, legacy?} do
      {true, false} -> boolean(value(row, :update_on_launch))
      {false, true} -> boolean(value(row, :scm_update_on_launch))
      _ -> :error
    end
  end

  defp template(row) when is_map(row) do
    with {:ok, id} <- positive_integer(value(row, :id)),
         {:ok, name} <- bounded_text(value(row, :name), 512, allow_empty?: false),
         {:ok, description} <- optional_text(value(row, :description), 8_192),
         {:ok, job_tags} <- optional_text(value(row, :job_tags), 4_096),
         {:ok, limit} <- optional_text(value(row, :limit), 16_384),
         {:ok, job_type} <- enum(value(row, :job_type), @job_types),
         {:ok, playbook} <- optional_playbook_path(value(row, :playbook)),
         {:ok, project_id} <- optional_positive_integer(value(row, :project)),
         {:ok, inventory_id} <- optional_positive_integer(value(row, :inventory)),
         {:ok, survey_enabled?} <- boolean(value(row, :survey_enabled)),
         {:ok, ask_variables?} <- boolean(value(row, :ask_variables_on_launch)),
         {:ok, ask_inventory?} <- boolean(value(row, :ask_inventory_on_launch)),
         {:ok, ask_limit?} <- boolean(value(row, :ask_limit_on_launch)),
         {:ok, ask_credential?} <- boolean(value(row, :ask_credential_on_launch)) do
      {:ok,
       %{
         "id" => id,
         "name" => name,
         "job_type" => job_type,
         "survey_enabled" => survey_enabled?,
         "ask_variables_on_launch" => ask_variables?,
         "ask_inventory_on_launch" => ask_inventory?,
         "ask_limit_on_launch" => ask_limit?,
         "ask_credential_on_launch" => ask_credential?
       }
       |> maybe_put("description", description)
       |> maybe_put("job_tags", job_tags)
       |> maybe_put("limit", limit)
       |> maybe_put("playbook", playbook)
       |> maybe_put("project", project_id)
       |> maybe_put("inventory", inventory_id)}
    else
      _ -> :error
    end
  end

  defp template(_row), do: :error

  defp survey_spec(spec) when is_map(spec) and map_size(spec) == 0, do: {:ok, %{}}

  defp survey_spec(spec) when is_map(spec) do
    with true <- survey_spec_keys?(spec),
         {:ok, _name} <- optional_text(value(spec, :name), 512),
         {:ok, _description} <- optional_text(value(spec, :description), 4_096),
         fields when is_list(fields) <- value(spec, :spec),
         true <- length(fields) <= @max_survey_fields,
         {:ok, safe_fields} <- reduce_list(fields, &survey_field/1),
         true <- unique_survey_variables?(safe_fields) do
      {:ok, %{"spec" => safe_fields}}
    else
      _ -> :error
    end
  end

  defp survey_spec(_spec), do: :error

  defp survey_spec_keys?(spec) do
    case normalized_keys(spec) do
      {:ok, keys} ->
        key_set = MapSet.new(keys)

        length(keys) == MapSet.size(key_set) and MapSet.member?(key_set, "spec") and
          MapSet.subset?(key_set, MapSet.new(~w(name description spec)))

      :error ->
        false
    end
  end

  defp survey_field(field) when is_map(field) do
    with variable when is_binary(variable) <- value(field, :variable),
         true <- reviewed_or_dispatcher_owned_survey_field?(field, variable),
         {:ok, question_name} <- bounded_text(value(field, :question_name), 512),
         {:ok, type} <- enum(value(field, :type), @survey_types),
         {:ok, required?} <- boolean(value(field, :required)),
         {:ok, choices} <- survey_choices(value(field, :choices), type),
         {:ok, min} <- optional_number(value(field, :min)),
         {:ok, max} <- optional_number(value(field, :max)),
         true <- valid_bounds?(min, max),
         {:ok, description} <- optional_text(value(field, :question_description), 4_096) do
      {:ok,
       %{
         "variable" => variable,
         "question_name" => question_name,
         "type" => type,
         "required" => required?
       }
       |> maybe_put("choices", choices)
       |> maybe_put("min", min)
       |> maybe_put("max", max)
       |> maybe_put("question_description", description)}
    else
      _ -> :error
    end
  end

  defp survey_field(_field), do: :error

  defp reviewed_or_dispatcher_owned_survey_field?(field, variable) do
    case DispatchMarkerContract.validate_survey_field(field) do
      :ok -> true
      :not_marker -> VariableSchema.reviewed_input_name?(variable)
      {:error, _reason} -> false
    end
  end

  defp unique_survey_variables?(fields) do
    names = Enum.map(fields, &String.downcase(&1["variable"]))
    length(names) == length(Enum.uniq(names))
  end

  defp survey_choices(nil, _type), do: {:ok, nil}

  defp survey_choices(choices, type)
       when is_binary(choices) and type in ["multiplechoice", "multiselect"] do
    with {:ok, choices} <- bounded_choices_text(choices),
         items = String.split(choices, ["\n", ","], trim: true),
         true <- length(items) <= 100,
         true <- Enum.all?(items, &match?({:ok, _}, bounded_text(String.trim(&1), 1_024))) do
      {:ok, choices}
    else
      _ -> :error
    end
  end

  defp survey_choices(choices, type)
       when is_list(choices) and type in ["multiplechoice", "multiselect"] and
              length(choices) <= 100 do
    reduce_list(choices, &bounded_text(&1, 1_024, allow_empty?: false))
  end

  defp survey_choices(choices, type) when choices in [nil, "", []] and is_binary(type),
    do: {:ok, choices}

  defp survey_choices(_choices, _type), do: :error

  defp valid_bounds?(nil, nil), do: true
  defp valid_bounds?(min, nil), do: is_number(min)
  defp valid_bounds?(nil, max), do: is_number(max)
  defp valid_bounds?(min, max), do: min <= max

  defp event_jobs(jobs) when is_list(jobs) and jobs != [] and length(jobs) <= @max_event_jobs do
    with {:ok, safe_jobs} <- reduce_list(jobs, &event_job/1),
         job_ids = Enum.map(safe_jobs, & &1["job_id"]),
         true <- length(job_ids) == length(Enum.uniq(job_ids)) do
      {:ok, safe_jobs}
    else
      _ -> :error
    end
  end

  defp event_jobs(_jobs), do: :error

  defp legacy_event_jobs(jobs)
       when is_list(jobs) and jobs != [] and length(jobs) <= @max_event_jobs do
    with {:ok, safe_jobs} <- reduce_list(jobs, &legacy_event_job/1),
         job_ids = Enum.map(safe_jobs, & &1["job_id"]),
         true <- length(job_ids) == length(Enum.uniq(job_ids)) do
      {:ok, safe_jobs}
    else
      _ -> :error
    end
  end

  defp legacy_event_jobs(_jobs), do: :error

  defp event_job(job) when is_map(job) do
    case value(job, :ok) do
      true -> successful_event_job(job)
      false -> failed_event_job(job)
      _ -> :error
    end
  end

  defp event_job(_job), do: :error

  defp legacy_event_job(job) when is_map(job) do
    case value(job, :ok) do
      true -> legacy_successful_event_job(job)
      false -> legacy_failed_event_job(job)
      _ -> :error
    end
  end

  defp legacy_event_job(_job), do: :error

  defp legacy_successful_event_job(job) do
    with true <- exact_keys?(job, ~w(job_id ok events max_counter count)),
         {:ok, job_id} <- positive_integer(value(job, :job_id)),
         {:ok, raw_events} <- legacy_raw_events(value(job, :events)),
         {:ok, declared_count} <-
           bounded_integer(value(job, :count), 0, @max_legacy_events_per_job),
         true <- declared_count == length(raw_events),
         {:ok, raw_max_counter} <- bounded_integer(value(job, :max_counter), 0, @max_id),
         {:ok, safe_events, safe_max_counter} <-
           legacy_event_window(raw_events, raw_max_counter) do
      {:ok,
       %{
         "job_id" => job_id,
         "ok" => true,
         "events" => safe_events,
         "max_counter" => safe_max_counter,
         "count" => length(safe_events)
       }}
    else
      _ -> :error
    end
  end

  defp legacy_failed_event_job(job) do
    with true <- exact_keys?(job, ~w(job_id ok error events max_counter count)),
         {:ok, job_id} <- positive_integer(value(job, :job_id)),
         events when events in [nil, []] <- value(job, :events),
         0 <- value(job, :max_counter),
         0 <- value(job, :count) do
      {:ok,
       %{
         "job_id" => job_id,
         "ok" => false,
         "error" => "awx_event_fetch_failed",
         "events" => [],
         "max_counter" => 0,
         "count" => 0
       }}
    else
      _ -> :error
    end
  end

  defp legacy_raw_events(nil), do: {:ok, []}

  defp legacy_raw_events(events)
       when is_list(events) and length(events) <= @max_legacy_events_per_job, do: {:ok, events}

  defp legacy_raw_events(_events), do: :error

  defp legacy_event_window([], raw_max_counter), do: {:ok, [], raw_max_counter}

  defp legacy_event_window(raw_events, raw_max_counter) do
    raw_events
    |> Enum.reduce_while({:ok, [], 0}, fn raw_event, {:ok, safe_events, previous_counter} ->
      case legacy_event_projection(raw_event) do
        {:ok, safe_event, counter} when counter > previous_counter ->
          next = [safe_event | safe_events]

          if length(next) == @max_events_per_job,
            do: {:halt, {:window, Enum.reverse(next), counter}},
            else: {:cont, {:ok, next, counter}}

        {:skip, counter} when counter > previous_counter ->
          {:cont, {:ok, safe_events, counter}}

        _other ->
          {:halt, :error}
      end
    end)
    |> case do
      {:ok, safe_events, last_counter} when last_counter == raw_max_counter ->
        {:ok, Enum.reverse(safe_events), raw_max_counter}

      {:ok, _safe_events, _last_counter} ->
        :error

      {:window, safe_events, safe_max_counter} ->
        {:ok, safe_events, safe_max_counter}

      :error ->
        :error
    end
  end

  defp legacy_event_projection(raw_event) when is_map(raw_event) do
    with {:ok, counter} <- positive_integer(value(raw_event, :counter)),
         {:ok, event_name} <-
           bounded_token(value(raw_event, :event), 256, allow_empty?: false) do
      if event_name in @handled_events do
        case event(raw_event) do
          {:ok, safe_event} -> {:ok, safe_event, counter}
          :error -> :error
        end
      else
        {:skip, counter}
      end
    else
      _ -> :error
    end
  end

  defp legacy_event_projection(_raw_event), do: :error

  defp successful_event_job(job) do
    with true <- exact_keys?(job, ~w(job_id ok events max_counter count)),
         {:ok, job_id} <- positive_integer(value(job, :job_id)),
         events when is_list(events) <- value(job, :events),
         true <- length(events) <= @max_events_per_job,
         {:ok, safe_events} <- reduce_list(events, &event/1),
         {:ok, count} <- bounded_integer(value(job, :count), 0, @max_events_per_job),
         true <- count == length(safe_events),
         {:ok, max_counter} <- bounded_integer(value(job, :max_counter), 0, @max_id),
         true <- valid_event_counters?(safe_events, max_counter) do
      {:ok,
       %{
         "job_id" => job_id,
         "ok" => true,
         "events" => safe_events,
         "max_counter" => max_counter,
         "count" => count
       }}
    else
      _ -> :error
    end
  end

  defp failed_event_job(job) do
    with true <- exact_keys?(job, ~w(job_id ok error events max_counter count)),
         {:ok, job_id} <- positive_integer(value(job, :job_id)),
         {:ok, error} <- fixed_event_error(value(job, :error)),
         [] <- value(job, :events),
         0 <- value(job, :max_counter),
         0 <- value(job, :count) do
      {:ok,
       %{
         "job_id" => job_id,
         "ok" => false,
         "error" => error,
         "events" => [],
         "max_counter" => 0,
         "count" => 0
       }}
    else
      _ -> :error
    end
  end

  # These are structural error codes emitted by the AWX plugin, never
  # controller or module error text.
  defp fixed_event_error(error) when error == "awx_event_fetch_failed", do: {:ok, error}

  defp fixed_event_error(_error), do: :error

  defp valid_event_counters?([], max_counter), do: is_integer(max_counter)

  defp valid_event_counters?(events, max_counter) do
    counters = Enum.map(events, & &1["counter"])

    counters == Enum.sort(counters) and length(counters) == length(Enum.uniq(counters)) and
      List.last(counters) <= max_counter
  end

  defp event(raw) when is_map(raw) do
    with event_name when event_name in @handled_events <- value(raw, :event),
         {:ok, counter} <- positive_integer(value(raw, :counter)),
         {:ok, event_data} <- event_data(event_name, value(raw, :event_data)),
         {:ok, safe} <- event_top_level(event_name, raw, counter, event_data) do
      {:ok, safe}
    else
      _ -> :error
    end
  end

  defp event(_raw), do: :error

  defp event_top_level("playbook_on_stats" = event_name, _raw, counter, event_data) do
    {:ok, %{"event" => event_name, "counter" => counter, "event_data" => event_data}}
  end

  defp event_top_level(event_name, raw, counter, event_data) when event_name in @runner_events do
    with {:ok, created} <- optional_timestamp(value(raw, :created)),
         {:ok, failed?} <- optional_boolean(value(raw, :failed), nil),
         {:ok, changed?} <- optional_boolean(value(raw, :changed), nil) do
      {:ok,
       %{"event" => event_name, "counter" => counter, "event_data" => event_data}
       |> maybe_put("created", created)
       |> maybe_put("failed", failed?)
       |> maybe_put("changed", changed?)}
    else
      _ -> :error
    end
  end

  defp event_top_level(event_name, raw, counter, event_data) do
    case optional_timestamp(value(raw, :created)) do
      {:ok, created} ->
        {:ok,
         maybe_put(
           %{"event" => event_name, "counter" => counter, "event_data" => event_data},
           "created",
           created
         )}

      :error ->
        :error
    end
  end

  defp event_data("playbook_on_play_start", data) when is_map(data) do
    with {:ok, play_uuid} <- uuid(value(data, :play_uuid)),
         {:ok, play} <- optional_text(value(data, :play), 1_024),
         {:ok, name} <- optional_text(value(data, :name), 1_024) do
      {:ok,
       %{"play_uuid" => play_uuid}
       |> maybe_put("play", play)
       |> maybe_put("name", name)}
    else
      _ -> :error
    end
  end

  defp event_data(event_name, data) when event_name in @task_events and is_map(data) do
    with {:ok, play_uuid} <- uuid(value(data, :play_uuid)),
         {:ok, task_uuid} <- uuid(value(data, :task_uuid)),
         {:ok, play} <- optional_text(value(data, :play), 1_024),
         {:ok, task} <- optional_text(value(data, :task), 1_024),
         {:ok, name} <- optional_text(value(data, :name), 1_024),
         {:ok, task_action} <- optional_token(value(data, :task_action), 512),
         {:ok, task_path} <- optional_text(value(data, :task_path), 4_096),
         {:ok, task_line} <- optional_nonnegative_integer(value(data, :task_line_number)) do
      {:ok,
       %{"play_uuid" => play_uuid, "task_uuid" => task_uuid}
       |> maybe_put("play", play)
       |> maybe_put("task", task)
       |> maybe_put("name", name)
       |> maybe_put("task_action", task_action)
       |> maybe_put("task_path", task_path)
       |> maybe_put("task_line_number", task_line)}
    else
      _ -> :error
    end
  end

  defp event_data(event_name, data) when event_name in @runner_events and is_map(data) do
    with {:ok, play_uuid} <- uuid(value(data, :play_uuid)),
         {:ok, task_uuid} <- uuid(value(data, :task_uuid)),
         {:ok, host} <- host_token(value(data, :host)),
         {:ok, play} <- optional_text(value(data, :play), 1_024),
         {:ok, task} <- optional_text(value(data, :task), 1_024),
         {:ok, name} <- optional_text(value(data, :name), 1_024),
         {:ok, task_action} <- optional_token(value(data, :task_action), 512),
         {:ok, ignore_errors?} <- optional_boolean(value(data, :ignore_errors), nil),
         {:ok, delegated} <- optional_host_token(value(data, :delegated)),
         {:ok, res} <- result_code(value(data, :res)) do
      {:ok,
       %{"play_uuid" => play_uuid, "task_uuid" => task_uuid, "host" => host}
       |> maybe_put("play", play)
       |> maybe_put("task", task)
       |> maybe_put("name", name)
       |> maybe_put("task_action", task_action)
       |> maybe_put("ignore_errors", ignore_errors?)
       |> maybe_put("delegated", delegated)
       |> maybe_put("res", res)}
    else
      _ -> :error
    end
  end

  defp event_data("playbook_on_stats", data) when is_map(data) do
    Enum.reduce_while(@stats_keys, {:ok, %{}}, fn key, {:ok, acc} ->
      case stats_map(value(data, key)) do
        {:ok, counters} -> {:cont, {:ok, Map.put(acc, key, counters)}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp event_data(_event_name, _data), do: :error

  defp result_code(nil), do: {:ok, nil}

  defp result_code(result) when is_map(result) do
    case value(result, :rc) do
      rc when is_integer(rc) and rc >= -@max_id and rc <= @max_id -> {:ok, %{"rc" => rc}}
      nil -> {:ok, nil}
      _ -> :error
    end
  end

  defp result_code(_result), do: :error

  defp stats_map(stats) when is_map(stats) and map_size(stats) <= @max_stats_hosts do
    Enum.reduce_while(stats, {:ok, %{}}, fn {host, count}, {:ok, acc} ->
      with true <- is_binary(host),
           {:ok, host} <- host_token(host),
           {:ok, count} <- bounded_integer(count, 0, @max_id) do
        {:cont, {:ok, Map.put(acc, host, count)}}
      else
        _ -> {:halt, :error}
      end
    end)
  end

  defp stats_map(_stats), do: :error

  defp optional_playbook_path(nil), do: {:ok, nil}

  defp optional_playbook_path(path) when is_binary(path) do
    segments = String.split(path, "/", trim: false)

    with {:ok, path} <- bounded_text(path, 1_024, allow_empty?: false),
         false <- String.starts_with?(path, ["/", "\\"]),
         true <- Enum.all?(segments, &(&1 not in ["", ".", ".."])),
         false <- String.contains?(path, "\\") do
      {:ok, path}
    else
      _ -> :error
    end
  end

  defp optional_playbook_path(_path), do: :error

  defp host_token(value) do
    if Targeting.literal_host_token?(value), do: {:ok, value}, else: :error
  end

  defp optional_host_token(nil), do: {:ok, nil}
  defp optional_host_token(value), do: host_token(value)

  defp uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, normalized} when normalized == value -> {:ok, normalized}
      _ -> :error
    end
  end

  defp uuid(_value), do: :error

  defp optional_timestamp(nil), do: {:ok, nil}

  defp optional_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, _offset} -> {:ok, value}
      _ -> :error
    end
  end

  defp optional_timestamp(_value), do: :error

  defp bounded_text(value, max_bytes, opts \\ [])

  defp bounded_text(value, max_bytes, opts) when is_binary(value) do
    allow_empty? = Keyword.get(opts, :allow_empty?, true)

    if byte_size(value) <= max_bytes and (allow_empty? or value != "") and
         String.valid?(value) and not control_text?(value) do
      {:ok, value}
    else
      :error
    end
  end

  defp bounded_text(_value, _max_bytes, _opts), do: :error

  defp bounded_choices_text(value) do
    if byte_size(value) <= 16_384 and String.valid?(value) and
         not control_text?(String.replace(value, "\n", "")) do
      {:ok, value}
    else
      :error
    end
  end

  defp control_text?(value), do: Regex.match?(~r/[\p{Cc}\p{Cf}]/u, value)

  defp bounded_token(value, max_bytes, opts \\ [])

  defp bounded_token(value, max_bytes, opts) when is_binary(value) do
    with {:ok, value} <- bounded_text(value, max_bytes, opts),
         true <- Regex.match?(~r/\A[A-Za-z0-9._+\/-]*\z/, value) do
      {:ok, value}
    else
      _ -> :error
    end
  end

  defp bounded_token(_value, _max_bytes, _opts), do: :error

  defp optional_text(nil, _max_bytes), do: {:ok, nil}
  defp optional_text(value, max_bytes), do: bounded_text(value, max_bytes)

  defp optional_token(nil, _max_bytes), do: {:ok, nil}
  defp optional_token(value, max_bytes), do: bounded_token(value, max_bytes, allow_empty?: false)

  defp optional_number(nil), do: {:ok, nil}

  defp optional_number(value)
       when is_integer(value) and value >= -@max_int64 and value <= @max_int64, do: {:ok, value}

  defp optional_number(value) when is_float(value) do
    if abs(value) <= 1.0e308, do: {:ok, value}, else: :error
  end

  defp optional_number(_value), do: :error

  defp nonnegative_number(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp nonnegative_number(value) when is_float(value) and value >= 0 do
    if value <= 1.0e308, do: {:ok, value}, else: :error
  end

  defp nonnegative_number(_value), do: :error

  defp optional_boolean(nil, default), do: {:ok, default}
  defp optional_boolean(value, _default), do: boolean(value)

  defp optional_nonnegative_integer(nil), do: {:ok, nil}
  defp optional_nonnegative_integer(value), do: bounded_integer(value, 0, @max_id)

  defp optional_positive_integer(nil), do: {:ok, nil}
  defp optional_positive_integer(value), do: positive_integer(value)

  defp positive_integer(value), do: bounded_integer(value, 1, @max_id)

  defp bounded_integer(value, min, max) when is_integer(value) and value >= min and value <= max,
    do: {:ok, value}

  defp bounded_integer(_value, _min, _max), do: :error

  defp boolean(value) when is_boolean(value), do: {:ok, value}
  defp boolean(_value), do: :error

  defp enum(value, allowed) when is_binary(value),
    do: if(value in allowed, do: {:ok, value}, else: :error)

  defp enum(_value, _allowed), do: :error

  defp exact_keys?(map, expected) when is_map(map) do
    case normalized_keys(map) do
      {:ok, keys} ->
        length(keys) == MapSet.size(MapSet.new(keys)) and
          MapSet.new(keys) == MapSet.new(expected)

      :error ->
        false
    end
  end

  defp exact_keys?(_map, _expected), do: false

  defp normalized_keys(map) do
    map
    |> Map.keys()
    |> Enum.reduce_while({:ok, []}, fn
      key, {:ok, acc} when is_binary(key) -> {:cont, {:ok, [key | acc]}}
      key, {:ok, acc} when is_atom(key) -> {:cont, {:ok, [Atom.to_string(key) | acc]}}
      _key, _acc -> {:halt, :error}
    end)
  end

  defp reduce_list(values, function) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case function.(value) do
        {:ok, safe} -> {:cont, {:ok, [safe | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, safe} -> {:ok, Enum.reverse(safe)}
      :error -> :error
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp has_key?(map, key) when is_map(map),
    do: Map.has_key?(map, key) or Map.has_key?(map, to_string(key))

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key))
    end
  end

  defp value(_map, _key), do: nil
end
