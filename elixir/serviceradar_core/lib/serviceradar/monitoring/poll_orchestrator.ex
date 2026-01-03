defmodule ServiceRadar.Monitoring.PollOrchestrator do
  @moduledoc """
  Orchestrates poll execution for scheduled service checks.

  The PollOrchestrator is called by AshOban when a PollingSchedule's execute
  action is triggered. It handles:

  1. Creating a PollJob record to track execution
  2. Finding an available poller for the schedule's partition/tenant
  3. Loading the service checks associated with the schedule
  4. Dispatching the job to the poller
  5. Transitioning the PollJob through states and recording results

  ## ERTS Dispatch Protocol

  Jobs are dispatched to pollers across the ERTS cluster using Horde registries:

  1. **Discovery**: PollerRegistry (backed by Horde via TenantRegistry) provides
     cluster-wide poller discovery. Each registered poller has a PID that is
     location-transparent across nodes.

  2. **Selection**: Pollers are selected by tenant/partition using:
     - `:any` - Random available poller for tenant
     - `:partition` - Available poller in specific partition
     - `:specific` - Directly assigned poller by UUID

  3. **Dispatch**: The poller's PID from Horde is used directly for GenServer.call,
     which works transparently across ERTS nodes. No explicit RPC is needed.

  4. **Execution**: The poller receives the job, finds an agent, and dispatches
     checks via gRPC to the Go agent process.

  ## Communication Flow

  ```
  AshOban Scheduler (core-elx)
       |
       v
  PollingSchedule.execute
       |
       v
  PollOrchestrator.execute_schedule (core-elx)
       |
       ├── Create PollJob (pending)
       ├── Find poller via Horde (cluster-wide)
       ├── Get PID from Horde registry
       v
  GenServer.call(poller_pid, ...) (cross-node via ERTS)
       |
       v
  PollerProcess.execute_job (poller-elx node)
       |
       ├── Find agent via AgentRegistry
       v
  AgentProcess.execute_check
       |
       v
  gRPC to Go agent
  ```

  Results flow back up the chain for processing and storage.
  The PollJob resource uses AshStateMachine to enforce valid transitions.
  """

  require Logger

  alias ServiceRadar.Monitoring.PollJob
  alias ServiceRadar.GatewayRegistry
  alias ServiceRadar.Edge.GatewayProcess

  @doc """
  Execute a polling schedule.

  Creates a PollJob record and transitions it through execution states.
  Finds an available poller and dispatches all service checks for execution.
  Returns aggregated results.
  """
  @spec execute_schedule(map()) :: {:ok, map()} | {:error, term()}
  def execute_schedule(schedule) do
    # Load checks first to include count in job
    case load_checks(schedule) do
      {:error, :no_checks} ->
        Logger.debug("No checks configured for schedule #{schedule.name}")
        {:ok, %{total: 0, success: 0, failed: 0, results: []}}

      {:ok, checks} ->
        # Create PollJob record to track this execution
        case create_poll_job(schedule, checks) do
          {:ok, job} ->
            execute_with_job(job, schedule, checks)

          {:error, reason} ->
            Logger.error("Failed to create poll job: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} = error ->
        Logger.error("Failed to load checks for schedule #{schedule.name}: #{inspect(reason)}")
        error
    end
  end

  # Execute schedule with a PollJob tracking state
  defp execute_with_job(job, schedule, checks) do
    # Transition to dispatching while finding gateway
    with {:ok, job} <- transition_to_dispatching(job),
         {:ok, gateway} <- find_gateway(schedule),
         {:ok, job} <- update_job_gateway(job, gateway),
         {:ok, job} <- transition_to_running(job),
         {:ok, result} <- dispatch_to_gateway(gateway, checks, schedule, job) do
      # Complete the job with results
      complete_job(job, result)

      Logger.info(
        "Schedule #{schedule.name} completed: #{result[:success]}/#{result[:total]} checks passed"
      )

      {:ok, result}
    else
      {:error, :no_available_gateway} ->
        fail_job(job, "No available gateway", "NO_GATEWAY")
        Logger.warning("No available gateway for schedule #{schedule.name}")
        {:error, :no_available_gateway}

      {:error, reason} = error ->
        fail_job(job, "Execution failed: #{inspect(reason)}", "EXECUTION_ERROR")
        Logger.error("Failed to execute schedule #{schedule.name}: #{inspect(reason)}")
        error
    end
  end

  # Create a new PollJob record
  defp create_poll_job(schedule, checks) do
    check_ids = Enum.map(checks, & &1[:id])

    PollJob
    |> Ash.Changeset.for_create(:create, %{
      schedule_id: schedule.id,
      schedule_name: schedule.name,
      check_count: length(checks),
      check_ids: check_ids,
      priority: schedule.priority || 0,
      timeout_seconds: schedule.timeout_seconds || 60,
      tenant_id: schedule.tenant_id
    })
    |> Ash.create()
  end

  # State transitions
  defp transition_to_dispatching(job) do
    job
    |> Ash.Changeset.for_update(:dispatch, %{})
    |> Ash.update()
  end

  defp update_job_gateway(job, gateway) do
    gateway_id = gateway[:gateway_id]

    job
    |> Ash.Changeset.for_update(:update, %{gateway_id: gateway_id})
    |> Ash.update()
  rescue
    # If update action doesn't exist, just return the job
    _ -> {:ok, job}
  end

  defp transition_to_running(job) do
    job
    |> Ash.Changeset.for_update(:start, %{})
    |> Ash.update()
  end

  defp complete_job(job, result) do
    job
    |> Ash.Changeset.for_update(:complete, %{
      success_count: result[:success] || 0,
      failure_count: result[:failed] || 0,
      results: result[:results] || []
    })
    |> Ash.update()
  rescue
    e ->
      Logger.warning("Failed to complete job #{job.id}: #{inspect(e)}")
      {:error, e}
  end

  defp fail_job(job, message, code) do
    job
    |> Ash.Changeset.for_update(:fail, %{
      error_message: message,
      error_code: code
    })
    |> Ash.update()
  rescue
    e ->
      Logger.warning("Failed to mark job #{job.id} as failed: #{inspect(e)}")
      {:error, e}
  end

  @doc """
  Execute a schedule asynchronously.

  Returns immediately with a job_id. Subscribe to PubSub for results.
  """
  @spec execute_schedule_async(map()) :: {:ok, String.t()} | {:error, term()}
  def execute_schedule_async(schedule) do
    with {:ok, checks} <- load_checks(schedule),
         {:ok, poll_job} <- create_poll_job(schedule, checks),
         {:ok, poll_job} <- transition_to_dispatching(poll_job),
         {:ok, gateway} <- find_gateway(schedule),
         {:ok, poll_job} <- update_job_gateway(poll_job, gateway),
         {:ok, _poll_job} <- transition_to_running(poll_job) do
      # Dispatch async using PID from Horde for cross-node dispatch
      job_payload = build_job(checks, schedule, poll_job)
      gateway_pid = gateway[:pid]

      if is_nil(gateway_pid) do
        fail_job(poll_job, "Gateway has no PID in registry", "DISPATCH_ERROR")
        {:error, :gateway_not_found}
      else
        case GatewayProcess.execute_job_async(gateway_pid, job_payload) do
          {:ok, _async_id} ->
            Logger.info("Schedule #{schedule.name} dispatched async as job #{poll_job.id}")
            {:ok, poll_job.id}

          error ->
            fail_job(poll_job, "Async dispatch failed", "DISPATCH_ERROR")
            error
        end
      end
    else
      {:error, :no_checks} ->
        Logger.debug("No checks configured for schedule #{schedule.name}")
        {:ok, nil}

      {:error, reason} = error ->
        Logger.error("Failed to execute schedule async #{schedule.name}: #{inspect(reason)}")
        error
    end
  end

  # Find an available gateway based on schedule assignment mode
  defp find_gateway(schedule) do
    tenant_id = schedule.tenant_id

    case schedule.assignment_mode do
      :any ->
        # Find any available gateway for this tenant
        case GatewayRegistry.find_available_gateways(tenant_id) do
          [] -> {:error, :no_available_gateway}
          gateways -> {:ok, Enum.random(gateways)}
        end

      :partition ->
        # Find gateway in specific partition
        partition_id = schedule.assigned_partition_id

        if is_nil(partition_id) do
          {:error, :no_partition_assigned}
        else
          GatewayRegistry.find_available_gateway_for_partition(tenant_id, partition_id)
        end

      :domain ->
        # Find gateway in specific domain (e.g., site-a, datacenter-east)
        domain = schedule.assigned_domain

        if is_nil(domain) do
          {:error, :no_domain_assigned}
        else
          GatewayRegistry.find_available_gateway_for_domain(tenant_id, domain)
        end

      :specific ->
        # Use specifically assigned gateway
        gateway_id = schedule.assigned_gateway_id

        if is_nil(gateway_id) do
          {:error, :no_gateway_assigned}
        else
          case GatewayRegistry.lookup(tenant_id, gateway_id) do
            [{pid, metadata}] ->
              if metadata[:status] == :available do
                # Include the PID in the returned metadata for cross-node dispatch
                {:ok, Map.put(metadata, :pid, pid)}
              else
                {:error, :gateway_not_available}
              end

            [] ->
              {:error, :gateway_not_found}
          end
        end
    end
  end

  # Dispatch job to gateway (legacy name preserved for now)
  defp dispatch_to_gateway(gateway, checks, schedule, poll_job) do
    job_payload = build_job(checks, schedule, poll_job)
    gateway_id = gateway[:gateway_id]

    # Use the PID from Horde registry directly - this enables cross-node dispatch
    # The PID is location-transparent across the ERTS cluster
    gateway_pid = gateway[:pid]

    if is_nil(gateway_pid) do
      Logger.warning("Gateway #{gateway_id} has no PID in registry metadata")
      {:error, :gateway_not_found}
    else
      Logger.debug(
        "Dispatching #{length(checks)} checks to gateway #{gateway_id} " <>
          "on node #{node(gateway_pid)} (job: #{poll_job.id})"
      )

      case GatewayProcess.execute_job(gateway_pid, job_payload) do
        {:ok, result} ->
          # Process and possibly store results
          process_results(result, schedule, poll_job)
          {:ok, result}

        {:error, :gateway_not_found} ->
          # Gateway might have gone away, try another
          Logger.warning("Gateway #{gateway_id} not found, will retry on next schedule")
          {:error, :gateway_not_found}

        {:error, :busy} ->
          Logger.warning("Gateway #{gateway_id} is busy")
          {:error, :gateway_busy}

        error ->
          error
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


  # Build job payload for gateway
  defp build_job(checks, schedule, poll_job) do
    %{
      job_id: poll_job.id,
      schedule_id: schedule.id,
      schedule_name: schedule.name,
      tenant_id: schedule.tenant_id,
      checks: checks,
      timeout: schedule.timeout_seconds * 1000,
      priority: schedule.priority
    }
  end

  # Process results from poller execution
  defp process_results(result, schedule, poll_job) do
    # Broadcast results via PubSub for any listeners
    Phoenix.PubSub.broadcast(
      ServiceRadar.PubSub,
      "schedule:results:#{schedule.id}",
      {:schedule_completed, schedule.id, poll_job.id, result}
    )

    # Also broadcast to tenant-level topic
    Phoenix.PubSub.broadcast(
      ServiceRadar.PubSub,
      "tenant:#{schedule.tenant_id}:schedule_results",
      {:schedule_completed, schedule.id, poll_job.id, result}
    )

    # Broadcast job-specific topic
    Phoenix.PubSub.broadcast(
      ServiceRadar.PubSub,
      "poll_job:#{poll_job.id}",
      {:job_completed, poll_job.id, result}
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
