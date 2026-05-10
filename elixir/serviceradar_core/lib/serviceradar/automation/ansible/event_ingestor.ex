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

  require Logger

  alias ServiceRadar.Automation.Ansible.IngestorAshActions

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
      "awx." <> _ -> :ok
      _ -> :ok
    end
  rescue
    err ->
      Logger.error("AWX EventIngestor handler crashed",
        command_type: Map.get(data, :command_type),
        error: inspect(err),
        stacktrace: Exception.format_stacktrace(__STACKTRACE__)
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
    events = Map.get(job, "events", [])
    max_counter = Map.get(job, "max_counter", 0)

    case actions.get_run_by_awx_job_id(awx_job_id) do
      {:ok, run} ->
        run = maybe_transition_to_running(run, events, actions)
        run = apply_events(run, events, actions)
        _ = advance_watermark_if_needed(run, max_counter, actions)
        :ok

      {:error, reason} ->
        Logger.info("AWX EventIngestor skipping events for unknown run",
          awx_job_id: awx_job_id,
          reason: inspect(reason)
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
      {:ok, updated} -> updated
      {:error, _} -> run
    end
  end

  defp maybe_transition_to_running(run, _events, _actions), do: run

  defp apply_events(run, events, actions) do
    Enum.reduce(events, run, fn event, acc -> apply_event(acc, event, actions) end)
  end

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
               tags: List.wrap(get_in(event, ["event_data", "task_args", "tags"])),
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

    cond do
      task_uuid == "" or play_uuid == "" or host_name == "" or counter == 0 ->
        run

      true ->
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
             {:ok, _} <-
               actions.upsert_task_result(%{
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
               }) do
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
      {:ok, updated} -> updated
      _ -> run
    end
  end

  defp apply_event(run, _other_event, _actions), do: run

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

  ## Other verbs (stubs; full impl in subsequent commits) ----------------------

  defp handle_launch(_data, _actions), do: :ok
  defp handle_fetch_job(_data, _actions), do: :ok
  defp handle_cancel(_data, _actions), do: :ok
  defp handle_ping(_data, _actions), do: :ok

  ## Event field accessors -----------------------------------------------------
  #
  # AWX places identifying fields in slightly different places across event
  # types. The accessors normalize this so the apply_event clauses don't
  # have to know.

  defp result_payload(%{result_payload: rp}) when is_map(rp), do: rp
  defp result_payload(%{"result_payload" => rp}) when is_map(rp), do: rp
  defp result_payload(_), do: %{}

  defp play_uuid(event),
    do:
      get_in(event, ["event_data", "play_uuid"]) || Map.get(event, "play_uuid") ||
        ""

  defp task_uuid(event),
    do:
      get_in(event, ["event_data", "task_uuid"]) || Map.get(event, "task_uuid") ||
        ""

  defp event_name(event),
    do:
      get_in(event, ["event_data", "play"]) || get_in(event, ["event_data", "name"]) ||
        ""

  defp event_play_name(event), do: get_in(event, ["event_data", "play"]) || ""

  defp event_task_name(event),
    do:
      get_in(event, ["event_data", "task"]) || get_in(event, ["event_data", "name"]) ||
        ""

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
        # Preserve `msg`, `rc`, `cmd`, `stdout_lines`, `stderr_lines` —
        # the operator-useful summary fields. Avoid the full module
        # output (those go to PlaybookContent in a subsequent commit).
        Map.take(res, ["msg", "rc", "cmd", "stdout_lines", "stderr_lines", "warnings"])

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
