defmodule ServiceRadar.Inventory.Identity.SourceRetirementWorker do
  @moduledoc """
  Runs one source identifier retirement pass for one source instance
  (`ServiceRadar.Inventory.Identity.SourceRetirement.run/2`).

  `ServiceRadar.Inventory.DeviceSourceObservationIngestor` queues a pass after an exact
  collection of the instance activates and its absences are counted, so a pass never runs
  during ingest. An instance has at most one pass queued or running: a collection that
  activates meanwhile queues nothing, and the instance's next exact collection queues the next
  pass. A pass reads the absences as they stand when it runs, so delaying one only delays a
  retirement the rule already allows.

  The pass reads its settings from the database and fails closed: when they cannot be read,
  nothing is retired and the job is retried. A pass the mass guard refuses completes, since
  retrying it would be refused again; the next exact collection queues the next pass.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [
      period: :infinity,
      keys: [:partition, :source, :source_instance],
      states: :incomplete
    ]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.DeviceCleanupSettings
  alias ServiceRadar.Inventory.Identity.SourceRetirement
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @doc """
  Queues a retirement pass for the source instance of an activated collection. Never fails
  the activation that called it: a pass that cannot be queued is logged, and the instance's
  next exact collection queues one.
  """
  @spec enqueue(map()) :: :ok
  def enqueue(%{partition: partition, source: source, source_instance: source_instance}) do
    %{"partition" => partition, "source" => source, "source_instance" => source_instance}
    |> new()
    |> ObanSupport.safe_insert()
    |> case do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "SourceRetirementWorker: could not queue a retirement pass for #{source} instance " <>
            "#{source_instance} (#{inspect(reason)}); the next exact collection queues one"
        )

        :ok
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"partition" => partition, "source" => source, "source_instance" => instance}
      })
      when is_binary(partition) and is_binary(source) and is_binary(instance) do
    actor = SystemActor.system(:source_retirement)

    case DeviceCleanupSettings.get_settings(actor: actor) do
      {:ok, %DeviceCleanupSettings{} = settings} ->
        %{partition: partition, source: source, source_instance: instance}
        |> SourceRetirement.run(settings: settings, actor: actor)
        |> handle_result()

      other ->
        Logger.warning(
          "SourceRetirementWorker: device cleanup settings unavailable, retiring nothing for " <>
            "#{source} instance #{instance}: #{inspect(other)}"
        )

        {:error, :settings_unavailable}
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_args}

  defp handle_result({:ok, _stats}), do: :ok
  defp handle_result({:error, {:mass_retirement_refused, _counts}}), do: :ok
  defp handle_result({:error, _reason} = error), do: error
end
