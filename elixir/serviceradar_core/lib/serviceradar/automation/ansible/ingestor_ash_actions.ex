defmodule ServiceRadar.Automation.Ansible.IngestorAshActions do
  @moduledoc """
  Production implementation of `IngestorActions`. Each callback is a thin
  wrapper around the corresponding Ash code-interface function so the
  behaviour stays simple and the resources own their own validation.
  """

  @behaviour ServiceRadar.Automation.Ansible.IngestorActions

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.Controller
  alias ServiceRadar.Automation.Ansible.Playbook
  alias ServiceRadar.Automation.Ansible.PlaybookPlay
  alias ServiceRadar.Automation.Ansible.PlaybookRun
  alias ServiceRadar.Automation.Ansible.PlaybookRunTarget
  alias ServiceRadar.Automation.Ansible.PlaybookTask
  alias ServiceRadar.Automation.Ansible.PlaybookTaskResult
  alias ServiceRadar.Edge.AgentCommand
  alias ServiceRadar.Infrastructure.EventBatcher

  defp actor, do: [actor: SystemActor.system(:awx_event_ingestor)]

  @impl true
  def get_run_by_awx_job_id(awx_job_id) do
    case PlaybookRun.get_by_awx_job_id(awx_job_id, actor()) do
      {:ok, run} -> {:ok, run}
      {:error, _} = err -> err
      nil -> {:error, :run_not_found}
    end
  end

  @impl true
  def upsert_play(args) do
    PlaybookPlay.upsert_play(args, actor())
  end

  @impl true
  def upsert_task(args) do
    PlaybookTask.upsert_task(args, actor())
  end

  @impl true
  def upsert_task_result(args) do
    PlaybookTaskResult.upsert_result(args, actor())
  end

  @impl true
  def get_run_target(run_id, awx_host_name) do
    case PlaybookRunTarget.get_by_run_host(run_id, awx_host_name, actor()) do
      {:ok, target} -> {:ok, target}
      {:error, _} = err -> err
      nil -> {:error, :run_target_not_found}
    end
  end

  @impl true
  def record_target_outcome(target, args) do
    PlaybookRunTarget.record_outcome(target, args, actor())
  end

  @impl true
  def advance_watermark(run, last_event_id) do
    PlaybookRun.advance_watermark(run, %{last_event_id: last_event_id}, actor())
  end

  @impl true
  def transition_run(run, :record_running, _args), do: PlaybookRun.record_running(run, actor())

  def transition_run(run, :record_succeeded, args),
    do: PlaybookRun.record_succeeded(run, args, actor())

  def transition_run(run, :record_partial, args),
    do: PlaybookRun.record_partial(run, args, actor())

  def transition_run(run, :record_failed, args), do: PlaybookRun.record_failed(run, args, actor())

  def transition_run(run, :record_unreachable, args),
    do: PlaybookRun.record_unreachable(run, args, actor())

  def transition_run(run, :record_canceled, args),
    do: PlaybookRun.record_canceled(run, args, actor())

  def transition_run(run, :record_launching, args),
    do: PlaybookRun.record_launching(run, args, actor())

  @impl true
  def get_command_context(command_id) when is_binary(command_id) do
    case AgentCommand.get_by_id(command_id, actor()) do
      {:ok, %{context: context}} when is_map(context) -> {:ok, context}
      {:ok, _} -> {:ok, %{}}
      {:error, _} = err -> err
      nil -> {:error, :command_not_found}
    end
  end

  def get_command_context(_), do: {:error, :invalid_command_id}

  @impl true
  def get_run_by_id(run_id) do
    case PlaybookRun.get_by_id(run_id, actor()) do
      {:ok, run} -> {:ok, run}
      {:error, _} = err -> err
      nil -> {:error, :run_not_found}
    end
  end

  @impl true
  def get_controller_by_id(controller_id) do
    case Controller.get_by_id(controller_id, actor()) do
      {:ok, controller} -> {:ok, controller}
      {:error, _} = err -> err
      nil -> {:error, :controller_not_found}
    end
  end

  @impl true
  def record_controller_health(controller, args) do
    Controller.record_health(controller, args, actor())
  end

  @impl true
  def upsert_awx_playbook(controller_id, args) do
    Playbook.upsert_awx(Map.put(args, :controller_id, controller_id), actor())
  end

  @impl true
  def emit_ocsf_event(event) when is_map(event) do
    _ = EventBatcher.queue_event(:ansible_ocsf, event)
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  def emit_ocsf_event(_), do: :ok
end
