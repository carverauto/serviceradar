defmodule ServiceRadar.Monitoring.PollOrchestrator do
  @moduledoc """
  Orchestrates poll execution for scheduled service checks.

  The PollOrchestrator is called by AshOban when a PollingSchedule's execute
  action is triggered. It handles:

  1. Finding an available poller for the schedule's partition/tenant
  2. Loading the service checks associated with the schedule
  3. Dispatching the job to the poller
  4. Collecting and returning results

  ## Communication Flow

  ```
  AshOban Scheduler
       |
       v
  PollingSchedule.execute
       |
       v
  PollOrchestrator.execute_schedule
       |
       v
  PollerProcess.execute_job
       |
       v
  AgentProcess.execute_check
       |
       v
  serviceradar-sync (gRPC)
  ```

  Results flow back up the chain for processing and storage.
  """

  require Logger

  alias ServiceRadar.PollerRegistry
  alias ServiceRadar.Edge.PollerProcess

  @doc """
  Execute a polling schedule.

  Finds an available poller and dispatches all service checks for execution.
  Returns aggregated results.
  """
  @spec execute_schedule(map()) :: {:ok, map()} | {:error, term()}
  def execute_schedule(schedule) do
    # Find available poller based on assignment mode
    with {:ok, poller} <- find_poller(schedule),
         {:ok, checks} <- load_checks(schedule),
         {:ok, result} <- dispatch_to_poller(poller, checks, schedule) do
      Logger.info(
        "Schedule #{schedule.name} completed: #{result[:success]}/#{result[:total]} checks passed"
      )

      {:ok, result}
    else
      {:error, :no_available_poller} ->
        Logger.warning("No available poller for schedule #{schedule.name}")
        {:error, :no_available_poller}

      {:error, :no_checks} ->
        Logger.debug("No checks configured for schedule #{schedule.name}")
        {:ok, %{total: 0, success: 0, failed: 0, results: []}}

      {:error, reason} = error ->
        Logger.error("Failed to execute schedule #{schedule.name}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Execute a schedule asynchronously.

  Returns immediately with a job_id. Subscribe to PubSub for results.
  """
  @spec execute_schedule_async(map()) :: {:ok, String.t()} | {:error, term()}
  def execute_schedule_async(schedule) do
    with {:ok, poller} <- find_poller(schedule),
         {:ok, checks} <- load_checks(schedule) do
      # Dispatch async
      job = build_job(checks, schedule)

      case PollerProcess.execute_job_async(poller[:poller_id], job) do
        {:ok, job_id} ->
          Logger.info("Schedule #{schedule.name} dispatched async as job #{job_id}")
          {:ok, job_id}

        error ->
          error
      end
    end
  end

  # Find an available poller based on schedule assignment mode
  defp find_poller(schedule) do
    tenant_id = schedule.tenant_id

    case schedule.assignment_mode do
      :any ->
        # Find any available poller for this tenant
        case PollerRegistry.find_available_pollers(tenant_id) do
          [] -> {:error, :no_available_poller}
          pollers -> {:ok, Enum.random(pollers)}
        end

      :partition ->
        # Find poller in specific partition
        partition_id = schedule.assigned_partition_id

        if is_nil(partition_id) do
          {:error, :no_partition_assigned}
        else
          PollerRegistry.find_available_poller_for_partition(tenant_id, partition_id)
        end

      :specific ->
        # Use specifically assigned poller
        poller_id = schedule.assigned_poller_id

        if is_nil(poller_id) do
          {:error, :no_poller_assigned}
        else
          case PollerRegistry.lookup(poller_id) do
            [{_pid, metadata}] ->
              if metadata[:status] == :available do
                {:ok, metadata}
              else
                {:error, :poller_not_available}
              end

            [] ->
              {:error, :poller_not_found}
          end
        end
    end
  end

  # Load service checks for the schedule
  defp load_checks(schedule) do
    # Query checks associated with this schedule
    # For now, return empty if no checks loaded
    case load_schedule_checks(schedule) do
      {:ok, []} -> {:error, :no_checks}
      {:ok, checks} -> {:ok, checks}
      error -> error
    end
  end

  # Load checks from database
  defp load_schedule_checks(schedule) do
    # Use Ash to query checks for this schedule
    require Ash.Query

    try do
      checks =
        ServiceRadar.Monitoring.ServiceCheck
        |> Ash.Query.filter(schedule_id == ^schedule.id)
        |> Ash.Query.filter(enabled == true)
        |> Ash.read!(tenant: schedule.tenant_id)
        |> Enum.map(&check_to_map/1)

      {:ok, checks}
    rescue
      e ->
        Logger.error("Failed to load checks for schedule #{schedule.id}: #{inspect(e)}")
        {:error, :failed_to_load_checks}
    end
  end

  # Convert ServiceCheck to a map for the job
  defp check_to_map(check) do
    %{
      id: check.id,
      service_name: check.name,
      service_type: Atom.to_string(check.check_type),
      target_host: check.target_host,
      target_port: check.target_port,
      details: Jason.encode!(check.check_config || %{}),
      port: check.target_port || 0
    }
  end

  # Dispatch job to poller
  defp dispatch_to_poller(poller, checks, schedule) do
    job = build_job(checks, schedule)
    poller_id = poller[:poller_id]

    Logger.debug("Dispatching #{length(checks)} checks to poller #{poller_id}")

    case PollerProcess.execute_job(poller_id, job) do
      {:ok, result} ->
        # Process and possibly store results
        process_results(result, schedule)
        {:ok, result}

      {:error, :poller_not_found} ->
        # Poller might have gone away, try another
        Logger.warning("Poller #{poller_id} not found, will retry on next schedule")
        {:error, :poller_not_found}

      {:error, :busy} ->
        Logger.warning("Poller #{poller_id} is busy")
        {:error, :poller_busy}

      error ->
        error
    end
  end

  # Build job payload for poller
  defp build_job(checks, schedule) do
    %{
      schedule_id: schedule.id,
      schedule_name: schedule.name,
      tenant_id: schedule.tenant_id,
      checks: checks,
      timeout: schedule.timeout_seconds * 1000,
      priority: schedule.priority
    }
  end

  # Process results from poller execution
  defp process_results(result, schedule) do
    # Broadcast results via PubSub for any listeners
    Phoenix.PubSub.broadcast(
      ServiceRadar.PubSub,
      "schedule:results:#{schedule.id}",
      {:schedule_completed, schedule.id, result}
    )

    # Also broadcast to tenant-level topic
    Phoenix.PubSub.broadcast(
      ServiceRadar.PubSub,
      "tenant:#{schedule.tenant_id}:schedule_results",
      {:schedule_completed, schedule.id, result}
    )

    # Individual check results can be stored via events
    Enum.each(result[:results] || [], fn check_result ->
      if check_result[:status] == :failed do
        # Could create an alert here
        Logger.debug("Check failed: #{inspect(check_result[:check])}")
      end
    end)

    :ok
  end
end
