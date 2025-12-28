defmodule ServiceRadar.Infrastructure.EntityHealthTracker.RecoveryWorker do
  @moduledoc """
  Oban worker for scheduled entity recovery attempts.

  Handles recovery for all entity types (pollers, agents, checkers, collectors).
  Jobs are scheduled by EntityHealthTracker when entities become degraded or offline.

  ## Job Arguments

  - `entity_type` - Type of entity ("poller", "agent", "checker", "collector")
  - `entity_id` - The ID of the entity to recover
  - `tenant_id` - The tenant that owns the entity
  - `attempt` - Current recovery attempt number (1-indexed)

  ## Configuration

  Uses the `:entity_recovery` Oban queue:

      config :serviceradar_core, Oban,
        queues: [
          default: 10,
          entity_recovery: 5
        ]
  """

  use Oban.Worker,
    queue: :entity_recovery,
    max_attempts: 3,
    unique: [period: 60, fields: [:args, :queue], keys: [:entity_type, :entity_id]]

  alias ServiceRadar.Infrastructure.EntityHealthTracker

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    entity_type = args |> Map.get("entity_type") |> String.to_existing_atom()
    entity_id = Map.get(args, "entity_id")
    tenant_id = Map.get(args, "tenant_id")
    attempt = Map.get(args, "attempt", 1)

    Logger.info("Processing recovery attempt #{attempt} for #{entity_type} #{entity_id}")

    case EntityHealthTracker.attempt_recovery(entity_type, entity_id, tenant_id, attempt: attempt) do
      {:ok, :recovered} ->
        Logger.info("#{entity_type} #{entity_id} successfully recovered")
        :ok

      {:ok, :already_healthy} ->
        Logger.debug("#{entity_type} #{entity_id} already healthy")
        :ok

      {:ok, :recovery_started} ->
        # Follow-up job already scheduled
        :ok

      {:ok, :max_attempts_reached} ->
        Logger.warning("#{entity_type} #{entity_id} recovery exhausted max attempts")
        :ok

      {:ok, {:skip, status}} ->
        Logger.debug("Skipping recovery for #{entity_type} #{entity_id} in #{status} state")
        :ok

      {:error, :entity_not_found} ->
        Logger.warning("#{entity_type} #{entity_id} not found, cancelling recovery")
        :ok

      {:error, reason} ->
        Logger.error("Recovery failed for #{entity_type} #{entity_id}: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    ArgumentError ->
      Logger.error("Invalid entity_type in recovery job: #{Map.get(args, "entity_type")}")
      :ok
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(30)
end
