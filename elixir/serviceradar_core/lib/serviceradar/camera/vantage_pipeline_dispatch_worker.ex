defmodule ServiceRadar.Camera.VantagePipelineDispatchWorker do
  @moduledoc """
  Oban worker draining the `ServiceRadar.Camera.VantageJob` CNPG outbox to
  NATS JetStream via `ServiceRadar.Camera.VantagePipelineDispatcher.relay/0`.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1,
    unique: [period: :infinity, states: [:available, :scheduled]]

  alias ServiceRadar.Camera.VantagePipelineDispatcher

  @doc """
  Enqueues an immediate `VantagePipelineDispatchWorker` run when enabled.
  """
  @spec enqueue(keyword()) :: {:ok, Oban.Job.t()} | {:error, term()} | :disabled
  def enqueue(opts \\ []) when is_list(opts) do
    enabled_fn = Keyword.get(opts, :enabled_fn, &VantagePipelineDispatcher.deployment_enabled?/0)

    if enabled_fn.() do
      insert_fn = Keyword.get(opts, :insert_fn, &Oban.insert/1)
      insert_fn.(new(%{}))
    else
      :disabled
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case VantagePipelineDispatcher.relay() do
      {:ok, _summary} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
