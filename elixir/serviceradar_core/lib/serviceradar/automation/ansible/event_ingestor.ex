defmodule ServiceRadar.Automation.Ansible.EventIngestor do
  @moduledoc """
  Receive-side counterpart to `AwxClient`.

  Called from the existing `agent_command_status_handler` when an
  `AgentCommand` for an `awx.*` verb completes. Routes by `command_type`
  to per-verb handlers; the bulk of the work lives in the
  `awx.fetch_events_for_jobs` path, which parses AWX `job_events` into
  the `PlaybookPlay` / `PlaybookTask` / `PlaybookTaskResult` /
  `PlaybookRunTarget` hierarchy and advances the run state machine.

  Side effects flow through the `IngestorActions` behaviour so this
  module can be unit-tested without a database. Production passes
  `IngestorAshActions`; tests inject a fake.

  See openspec change `add-ansible-integration` design.md decisions 3,
  3c, 4, 6.
  """

  alias ServiceRadar.Automation.Ansible.IngestorAshActions
  alias ServiceRadar.Automation.Ansible.OcsfMapper
  alias ServiceRadar.Automation.Ansible.PubSub, as: AnsiblePubSub
  alias ServiceRadar.Automation.Ansible.SafeFailureEvidence

  require Logger

  @type result_data :: %{
          required(:command_type) => String.t(),
          required(:command_id) => String.t() | nil,
          optional(:result_payload) => map() | nil,
          optional(any()) => any()
        }

  @doc """
  Handle a completed AgentCommand for an `awx.*` verb. Returns `:ok`
  for unknown / non-AWX verbs (so the existing status handler can call
  this unconditionally without a pre-filter).
  """
  @spec handle_command_result(result_data(), keyword()) :: :ok
  def handle_command_result(data, opts \\ []) do
    actions = Keyword.get(opts, :actions, IngestorAshActions)

    case Map.get(data, :command_type) || Map.get(data, "command_type") do
      "awx.fetch_events_for_jobs" -> handle_events(data, actions)
      "awx.launch_job" -> handle_launch(data, actions)
      "awx.fetch_job" -> handle_fetch_job(data, actions)
      "awx.cancel_job" -> handle_cancel(data, actions)
      "awx.ping" -> handle_ping(data, actions)
      "awx.list_templates" -> handle_list_templates(data, actions)
      "awx." <> _ -> :ok
      _ -> :ok
    end
  rescue
    err ->
      Logger.error(
        "AWX EventIngestor handler failed",
        [command_type: Map.get(data, :command_type)] ++ SafeFailureEvidence.log_metadata(err)
      )

      :ok
  end

  ## awx.fetch_events_for_jobs --------------------------------------------------

  defp handle_events(data, actions) do
    payload = result_payload(data)
    jobs = Map.get(payload, "jobs", [])

    Enum.each(jobs, fn job_entry -> handle_job_entry(job_entry, actions) end)
  end

  defp handle_job_entry(%{"job_id" => awx_job_id, "ok" => true} = job, actions)
       when is_integer(awx_job_id) do
    # The awx plugin returns `"events": null` (not []) for a job with no new
    # events since the watermark; a nil here crashed the whole handler on the
    # FIRST idle job, so events for the jobs after it were never ingested and
    # runs never advanced past :launching.
    events = Map.get(job, "events") || []
    max_counter = Map.get(job, "max_counter", 0)

    case actions.get_run_by_awx_job_id(awx_job_id) do
      {:ok, run} ->
        run = maybe_transition_to_running(run, events, actions)
        run = apply_events(run, events, actions)
        _ = advance_watermark_if_needed(run, max_counter, actions)
        _ = AnsiblePubSub.broadcast_run_updated(run)
        :ok

      {:error, reason} ->
        Logger.info(
          "AWX EventIngestor skipping events for unknown run",
          [awx_job_id: awx_job_id] ++ SafeFailureEvidence.log_metadata(reason)
        )

        :ok
    end
  end

  defp handle_job_entry(%{"job_id" => awx_job_id, "ok" => false} = job, _actions) do
    Logger.warning("AWX EventIngestor: per-job fetch error",
      awx_job_id: awx_job_id,
      error: Map.get(job, "error")
    )

    :ok
  end

  defp handle_job_entry(_other, _actions), do: :ok

  defp maybe_transition_to_running(%{state: :launching} = run, events, actions)
       when is_list(events) and events != [] do
    case actions.transition_run(run, :record_running, %{}) do
      {:ok, updated} ->
        _ = actions.emit_ocsf_event(OcsfMapper.run_state_event(updated, :running))
        updated

      {:error, _} ->
        run
    end
  end

  defp maybe_transition_to_running(run, _events, _actions), do: run

  defp apply_events(run, events, actions) do
    Enum.reduce(events, run, fn event, acc ->
      apply_event(acc, normalize_event(event), actions)
    end)
  end

  # A real AWX job_event carries the API object type in "type" (always
  # "job_event") and the actual ansible event name in "event"
  # ("playbook_on_play_start", "runner_on_ok", "playbook_on_stats", ...).
  # The apply_event/3 clauses match on "type", which never matches live AWX
  # data — every event fell through the catch-all, so plays/tasks were never
  # persisted and runs never reached a terminal state. Remap the event name
  # into "type" before dispatch.
  defp normalize_event(%{"event" => name} = event) when is_binary(name) and name != "",
    do: Map.put(event, "type", name)

  defp normalize_event(event), do: event

  # `playbook_on_play_start` — upsert a play row.
  defp apply_event(run, %{"type" => "playbook_on_play_start"} = event, actions) do
    play_uuid = play_uuid(event)

    case play_uuid do
      "" ->
        run

      _ ->
        _ =
          actions.upsert_play(%{
            run_id: run.id,
            awx_play_uuid: play_uuid,
            name: event_name(event),
            started_at: event_created(event),
            metadata: %{}
          })

        run
    end
  end

  # `playbook_on_task_start` / `…_handler_task_start` — upsert a task row.
  # We need the play_id, which the upsert_play action returns; but tasks
  # may arrive before / after their play depending on ordering, so we
  # always re-upsert the play first to make sure we have its id.
  defp apply_event(run, %{"type" => type} = event, actions)
       when type in ["playbook_on_task_start", "playbook_on_handler_task_start"] do
    task_uuid = task_uuid(event)
    play_uuid = play_uuid(event)

    if task_uuid == "" or play_uuid == "" do
      run
    else
      with {:ok, play} <-
             actions.upsert_play(%{
               run_id: run.id,
               awx_play_uuid: play_uuid,
               name: event_play_name(event),
               started_at: nil,
               metadata: %{}
             }),
           {:ok, _task} <-
             actions.upsert_task(%{
               play_id: play.id,
               awx_task_uuid: task_uuid,
               name: event_task_name(event),
               action: event_task_action(event),
               is_handler: type == "playbook_on_handler_task_start",
               path: get_in(event, ["event_data", "task_path"]),
               line_number: get_in(event, ["event_data", "task_line_number"]),
               tags: List.wrap(event_task_tags(event)),
               started_at: event_created(event),
               metadata: %{}
             }) do
        run
      else
        _ -> run
      end
    end
  end

  # Per-host runner outcome.
  defp apply_event(run, %{"type" => type} = event, actions)
       when type in [
              "runner_on_ok",
              "runner_on_failed",
              "runner_on_skipped",
              "runner_on_unreachable",
              "runner_item_on_ok",
              "runner_item_on_failed",
              "runner_item_on_skipped"
            ] do
    task_uuid = task_uuid(event)
    play_uuid = play_uuid(event)
    host_name = event_host_name(event)
    counter = event_counter(event)

    if task_uuid == "" or play_uuid == "" or host_name == "" or counter == 0 do
      run
    else
      with {:ok, play} <-
             actions.upsert_play(%{
               run_id: run.id,
               awx_play_uuid: play_uuid,
               name: event_play_name(event),
               started_at: nil,
               metadata: %{}
             }),
           {:ok, task} <-
             actions.upsert_task(%{
               play_id: play.id,
               awx_task_uuid: task_uuid,
               name: event_task_name(event),
               action: event_task_action(event),
               is_handler: false,
               path: nil,
               line_number: nil,
               tags: [],
               started_at: nil,
               metadata: %{}
             }),
           {:ok, target} <- actions.get_run_target(run.id, host_name),
           result_args = %{
             task_id: task.id,
             run_target_id: target.id,
             awx_event_id: counter,
             status: runner_status(type, event),
             changed: !!Map.get(event, "changed", false),
             ignore_errors: get_in(event, ["event_data", "ignore_errors"]) == true,
             delegated_to: get_in(event, ["event_data", "delegated"]),
             stdout_content_id: nil,
             stderr_content_id: nil,
             result_payload: result_payload_subset(event),
             event_at: event_created(event)
           },
           {:ok, _} <- actions.upsert_task_result(result_args) do
        _ = actions.emit_ocsf_event(OcsfMapper.task_result_event(run, task, target, result_args))
        run
      else
        {:error, :run_target_not_found} ->
          Logger.info("AWX EventIngestor: result for unknown host",
            run_id: run.id,
            host_name: host_name
          )

          run

        _ ->
          run
      end
    end
  end

  # `playbook_on_stats` — final per-host summary; drives the run state
  # machine transition based on aggregated outcomes.
  defp apply_event(run, %{"type" => "playbook_on_stats"} = event, actions) do
    stats = Map.get(event, "event_data", %{})

    targets_outcomes =
      stats
      |> aggregate_stats()
      |> Enum.map(fn {host_name, counts} ->
        case actions.get_run_target(run.id, host_name) do
          {:ok, target} ->
            {:ok, _} = actions.record_target_outcome(target, target_outcome_args(counts))
            counts

          _ ->
            counts
        end
      end)

    transition = decide_run_transition(targets_outcomes)

    summary =
      "completed: " <>
        Enum.map_join(targets_outcomes, ", ", fn c ->
          "ok=#{Map.get(c, :ok_count, 0)} failed=#{Map.get(c, :failed_count, 0)}"
        end)

    case actions.transition_run(run, transition, %{summary: summary}) do
      {:ok, updated} ->
        _ =
          actions.emit_ocsf_event(
            OcsfMapper.run_state_event(updated, terminal_state_for(transition))
          )

        updated

      _ ->
        run
    end
  end

  defp apply_event(run, _other_event, _actions), do: run

  # The set of transitions that reach this helper at runtime is the
  # union of decide_run_transition/1's outputs (succeeded / partial /
  # failed) and awx_status_to_transition/1's outputs (succeeded /
  # canceled / failed). Other transitions emit OCSF directly with a
  # hardcoded atom at their call sites.
  defp terminal_state_for(:record_succeeded), do: :succeeded
  defp terminal_state_for(:record_partial), do: :partial
  defp terminal_state_for(:record_failed), do: :failed
  defp terminal_state_for(:record_canceled), do: :canceled
  defp terminal_state_for(_), do: :unknown

  defp advance_watermark_if_needed(run, max_counter, actions)
       when is_integer(max_counter) and max_counter > 0 do
    if max_counter > Map.get(run, :last_event_id, 0) do
      _ = actions.advance_watermark(run, max_counter)
      :ok
    else
      :ok
    end
  end

  defp advance_watermark_if_needed(_run, _max_counter, _actions), do: :ok

  ## awx.launch_job ------------------------------------------------------------

  defp handle_launch(data, actions) do
    payload = result_payload(data)

    if Map.get(payload, "ok", false) do
      with awx_job_id when is_integer(awx_job_id) <- get_in(payload, ["job", "id"]),
           {:ok, run_id} <- correlate_run_id(data, actions),
           {:ok, run} <- actions.get_run_by_id(run_id) do
        if run.state == :pending do
          case actions.transition_run(run, :record_launching, %{awx_job_id: awx_job_id}) do
            {:ok, updated} ->
              _ = actions.emit_ocsf_event(OcsfMapper.run_state_event(updated, :launching))
              AnsiblePubSub.broadcast_run_updated(updated)

            _ ->
              :ok
          end
        end

        :ok
      else
        _ -> :ok
      end
    else
      log_verb_failure("awx.launch_job", payload, command_id(data))
      :ok
    end
  end

  ## awx.fetch_job -------------------------------------------------------------

  # Backstop for the case where AWX terminates a job without emitting
  # `playbook_on_stats` (e.g., AWX killed mid-run, network drop). RunPulseWorker
  # dispatches awx.fetch_job when a watermark hasn't moved during a tick; if
  # AWX reports a terminal status and our run is still non-terminal, we
  # transition based on the AWX status -- per-target detail is whatever
  # `playbook_on_stats` already wrote (possibly nothing).
  defp handle_fetch_job(data, actions) do
    payload = result_payload(data)
    awx_status = get_in(payload, ["job", "status"])

    if Map.get(payload, "ok", false) and awx_status in ~w(successful failed canceled error) do
      with {:ok, run_id} <- correlate_run_id(data, actions),
           {:ok, run} <- actions.get_run_by_id(run_id),
           true <- run.state in [:pending, :launching, :running] do
        transition = awx_status_to_transition(awx_status)
        summary = "AWX reported job " <> awx_status

        case actions.transition_run(run, transition, %{
               summary: summary,
               diagnostics: %{awx_status: awx_status}
             }) do
          {:ok, updated} ->
            _ =
              actions.emit_ocsf_event(
                OcsfMapper.run_state_event(updated, terminal_state_for(transition))
              )

            AnsiblePubSub.broadcast_run_updated(updated)

          _ ->
            :ok
        end

        :ok
      else
        _ -> :ok
      end
    else
      :ok
    end
  end

  defp awx_status_to_transition("successful"), do: :record_succeeded
  defp awx_status_to_transition("canceled"), do: :record_canceled
  defp awx_status_to_transition(_), do: :record_failed

  ## awx.cancel_job ------------------------------------------------------------

  defp handle_cancel(data, actions) do
    payload = result_payload(data)

    if Map.get(payload, "ok", false) do
      with {:ok, run_id} <- correlate_run_id(data, actions),
           {:ok, run} <- actions.get_run_by_id(run_id),
           true <- run.state == :running do
        case actions.transition_run(run, :record_canceled, %{summary: "operator-canceled via UI"}) do
          {:ok, updated} ->
            _ = actions.emit_ocsf_event(OcsfMapper.run_state_event(updated, :canceled))
            AnsiblePubSub.broadcast_run_updated(updated)

          _ ->
            :ok
        end

        :ok
      else
        _ -> :ok
      end
    else
      log_verb_failure("awx.cancel_job", payload, command_id(data))
      :ok
    end
  end

  ## awx.ping ------------------------------------------------------------------

  defp handle_ping(data, actions) do
    payload = result_payload(data)

    with {:ok, controller_id} <- correlate_controller_id(data, actions),
         {:ok, controller} <- actions.get_controller_by_id(controller_id) do
      args = ping_args(payload)
      _ = actions.record_controller_health(controller, args)
      :ok
    else
      _ -> :ok
    end
  end

  defp ping_args(%{"ok" => true} = payload) do
    %{
      status: :ok,
      awx_version: Map.get(payload, "version"),
      last_health_summary: ping_summary(payload)
    }
  end

  defp ping_args(payload) do
    %{
      status: :unreachable,
      awx_version: nil,
      last_health_summary: Map.get(payload, "error", "AWX ping returned ok=false")
    }
  end

  defp ping_summary(payload) do
    "AWX " <>
      nonempty(Map.get(payload, "version"), "?") <>
      " reachable (active: " <> nonempty(Map.get(payload, "active_node"), "?") <> ")"
  end

  defp nonempty(nil, fallback), do: fallback
  defp nonempty("", fallback), do: fallback
  defp nonempty(s, _) when is_binary(s), do: s
  defp nonempty(_, fallback), do: fallback

  ## awx.list_templates --------------------------------------------------------

  # Drives `:awx`-sourced catalog ingestion. Worker dispatches list_templates,
  # we get the result here, upsert one Playbook per template via the
  # `Playbook.upsert_awx` action. Survey_spec is left at its default (empty
  # map) for now -- the launch UI fetches it lazily via `awx.fetch_template`
  # when the operator picks a playbook. See add-ansible-integration design.md
  # decision 2.
  defp handle_list_templates(data, actions) do
    payload = result_payload(data)

    if Map.get(payload, "ok", true) do
      case correlate_controller_id(data, actions) do
        {:ok, controller_id} ->
          payload
          |> Map.get("results", [])
          |> Enum.each(fn template -> upsert_template(actions, controller_id, template) end)

          :ok

        _ ->
          :ok
      end
    else
      log_verb_failure("awx.list_templates", payload, command_id(data))
      :ok
    end
  end

  defp upsert_template(actions, controller_id, %{"id" => awx_id} = template)
       when is_integer(awx_id) do
    args = %{
      awx_job_template_id: awx_id,
      name: Map.get(template, "name", ""),
      description: Map.get(template, "description"),
      tags: tags_from_template(template),
      hosts_pattern: Map.get(template, "limit"),
      survey_spec: %{},
      parse_status: :ok,
      metadata: %{
        "job_type" => Map.get(template, "job_type"),
        "playbook" => Map.get(template, "playbook"),
        "project" => Map.get(template, "project"),
        "inventory" => Map.get(template, "inventory"),
        "survey_enabled" => Map.get(template, "survey_enabled", false),
        "ask_variables_on_launch" => Map.get(template, "ask_variables_on_launch", false),
        "ask_inventory_on_launch" => Map.get(template, "ask_inventory_on_launch", false),
        "ask_limit_on_launch" => Map.get(template, "ask_limit_on_launch", false),
        "ask_credential_on_launch" => Map.get(template, "ask_credential_on_launch", false)
      }
    }

    case actions.upsert_awx_playbook(controller_id, args) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "AWX EventIngestor: failed to upsert AWX template",
          [controller_id: controller_id, awx_template_id: awx_id] ++
            SafeFailureEvidence.log_metadata(reason)
        )

        :ok
    end
  end

  defp upsert_template(_actions, _controller_id, _malformed), do: :ok

  defp tags_from_template(template) do
    # AWX stores comma-separated tags on the job template's `job_tags` field.
    case Map.get(template, "job_tags") do
      nil ->
        []

      "" ->
        []

      raw when is_binary(raw) ->
        raw |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end

  ## Correlation helpers -------------------------------------------------------

  defp correlate_run_id(data, actions) do
    with {:ok, ctx} <- fetch_context(data, actions),
         id when is_binary(id) <-
           Map.get(ctx, "playbook_run_id") || Map.get(ctx, :playbook_run_id) do
      {:ok, id}
    else
      _ -> {:error, :no_playbook_run_id}
    end
  end

  defp correlate_controller_id(data, actions) do
    with {:ok, ctx} <- fetch_context(data, actions),
         id when is_binary(id) <- Map.get(ctx, "controller_id") || Map.get(ctx, :controller_id) do
      {:ok, id}
    else
      _ -> {:error, :no_controller_id}
    end
  end

  defp fetch_context(data, actions) do
    case command_id(data) do
      nil -> {:error, :no_command_id}
      id -> actions.get_command_context(id)
    end
  end

  defp command_id(data) do
    Map.get(data, :command_id) || Map.get(data, "command_id")
  end

  defp log_verb_failure(verb, payload, command_id) do
    Logger.warning("AWX EventIngestor: #{verb} reported ok=false",
      command_id: command_id,
      error: Map.get(payload, "error")
    )
  end

  ## Event field accessors -----------------------------------------------------
  #
  # AWX places identifying fields in slightly different places across event
  # types. The accessors normalize this so the apply_event clauses don't
  # have to know.

  # The gateway's control-stream session broadcasts the decoded agent result
  # under `:payload` (see ControlStreamSession.broadcast_result/3); the
  # `result_payload` name only exists as the agent_commands DB column. Reading
  # only :result_payload meant every ansible command result ingested as %{} —
  # catalog syncs completed without upserting a single template and run pulses
  # never advanced. Accept both shapes.
  defp result_payload(%{result_payload: rp}) when is_map(rp), do: rp
  defp result_payload(%{"result_payload" => rp}) when is_map(rp), do: rp
  defp result_payload(%{payload: rp}) when is_map(rp), do: rp
  defp result_payload(%{"payload" => rp}) when is_map(rp), do: rp
  defp result_payload(_), do: %{}

  # AWX serializes `event_data.task_args` as a STRING (often ""), not a map —
  # get_in(event, [..., "task_args", "tags"]) raised FunctionClauseError in
  # Access.get/3 on every real task event, killing the whole batch handler.
  defp event_task_tags(event) do
    case get_in(event, ["event_data", "task_args"]) do
      %{} = args -> Map.get(args, "tags")
      _ -> nil
    end
  end

  defp play_uuid(event),
    do: get_in(event, ["event_data", "play_uuid"]) || Map.get(event, "play_uuid") || ""

  defp task_uuid(event),
    do: get_in(event, ["event_data", "task_uuid"]) || Map.get(event, "task_uuid") || ""

  defp event_name(event),
    do: get_in(event, ["event_data", "play"]) || get_in(event, ["event_data", "name"]) || ""

  defp event_play_name(event), do: get_in(event, ["event_data", "play"]) || ""

  defp event_task_name(event),
    do: get_in(event, ["event_data", "task"]) || get_in(event, ["event_data", "name"]) || ""

  defp event_task_action(event), do: get_in(event, ["event_data", "task_action"])

  defp event_host_name(event),
    do:
      get_in(event, ["event_data", "host"]) || Map.get(event, "host_name") ||
        Map.get(event, "host") || ""

  defp event_counter(event), do: Map.get(event, "counter", 0)

  defp event_created(event) do
    case Map.get(event, "created") do
      nil -> nil
      "" -> nil
      ts when is_binary(ts) -> ts
      _ -> nil
    end
  end

  defp runner_status(type, event) do
    cond do
      String.ends_with?(type, "_unreachable") -> :unreachable
      String.ends_with?(type, "_skipped") -> :skipped
      String.ends_with?(type, "_failed") -> :failed
      Map.get(event, "failed", false) -> :failed
      true -> :ok
    end
  end

  defp result_payload_subset(event) do
    case get_in(event, ["event_data", "res"]) do
      %{} = res ->
        case Map.get(res, "rc") do
          rc when is_integer(rc) -> %{"rc" => rc}
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp aggregate_stats(stats) do
    counts = fn host ->
      %{
        ok_count: get_in(stats, ["ok", host]) || 0,
        failed_count: get_in(stats, ["failures", host]) || 0,
        unreachable_count: get_in(stats, ["dark", host]) || 0,
        skipped_count: get_in(stats, ["skipped", host]) || 0,
        changed_count: get_in(stats, ["changed", host]) || 0
      }
    end

    hosts =
      [
        Map.get(stats, "ok", %{}),
        Map.get(stats, "failures", %{}),
        Map.get(stats, "dark", %{}),
        Map.get(stats, "skipped", %{}),
        Map.get(stats, "changed", %{})
      ]
      |> Enum.flat_map(&Map.keys/1)
      |> Enum.uniq()

    Enum.map(hosts, fn host -> {host, counts.(host)} end)
  end

  defp target_outcome_args(counts) do
    status =
      cond do
        counts.unreachable_count > 0 -> :unreachable
        counts.failed_count > 0 -> :failed
        counts.ok_count > 0 -> :ok
        counts.skipped_count > 0 -> :skipped
        true -> :ok
      end

    Map.put(counts, :status, status)
  end

  defp decide_run_transition(targets_outcomes) do
    failures =
      Enum.count(targets_outcomes, fn c ->
        c.failed_count > 0 or c.unreachable_count > 0
      end)

    successes =
      Enum.count(targets_outcomes, fn c ->
        c.ok_count > 0 and c.failed_count == 0 and c.unreachable_count == 0
      end)

    cond do
      targets_outcomes == [] -> :record_succeeded
      failures == 0 -> :record_succeeded
      successes == 0 -> :record_failed
      true -> :record_partial
    end
  end
end
