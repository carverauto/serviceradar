defmodule ServiceRadar.Inventory.Identity.AwxSourceRetirementWorker do
  @moduledoc """
  Runs one AWX source retirement pass for one controller
  (`ServiceRadar.Inventory.Identity.AwxSourceRetirement.run/2`).

  `ServiceRadar.Inventory.DeviceDiscoveryIngestor` queues a pass after a complete AWX
  observation commits, so a pass never runs inside ingest. A controller has at most one pass
  queued or running; the pass reads the controller's latest observation when it runs and
  retires nothing unless that observation is complete, so a partial observation committed in
  between holds the pass back until the next complete one.

  The pass reads its settings from the database and fails closed: when they cannot be read,
  nothing is retired and the job is retried. A pass the mass guard refuses completes, since
  retrying it would be refused again; the next complete observation queues the next pass.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, keys: [:controller_id], states: :incomplete]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.DeviceCleanupSettings
  alias ServiceRadar.Inventory.Identity.AwxSourceRetirement
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @doc """
  Queues a retirement pass for a controller whose complete observation committed. Never fails
  the ingest that called it: a pass that cannot be queued is logged, and the controller's next
  complete observation queues one.
  """
  @spec enqueue(String.t()) :: :ok
  def enqueue(controller_id) when is_binary(controller_id) do
    %{"controller_id" => controller_id}
    |> new()
    |> ObanSupport.safe_insert()
    |> case do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "AwxSourceRetirementWorker: could not queue a retirement pass for controller " <>
            "#{controller_id} (#{inspect(reason)}); the next complete observation queues one"
        )

        :ok
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"controller_id" => controller_id}})
      when is_binary(controller_id) do
    actor = SystemActor.system(:source_retirement)

    case DeviceCleanupSettings.get_settings(actor: actor) do
      {:ok, %DeviceCleanupSettings{} = settings} ->
        controller_id
        |> AwxSourceRetirement.run(settings: settings, actor: actor)
        |> handle_result()

      other ->
        Logger.warning(
          "AwxSourceRetirementWorker: device cleanup settings unavailable, retiring nothing " <>
            "for controller #{controller_id}: #{inspect(other)}"
        )

        {:error, :settings_unavailable}
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_args}

  defp handle_result({:ok, _stats}), do: :ok
  defp handle_result({:error, {:mass_retirement_refused, _counts}}), do: :ok
  defp handle_result({:error, _reason} = error), do: error
end
