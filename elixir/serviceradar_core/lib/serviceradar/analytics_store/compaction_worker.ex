defmodule ServiceRadar.AnalyticsStore.CompactionWorker do
  @moduledoc "Bounded file compaction below archive publication priority on the shared head queue."

  use Oban.Worker,
    queue: :analytics_archive,
    priority: 3,
    max_attempts: 5,
    unique: [period: :infinity, fields: [:worker, :args], keys: [:table], states: :incomplete]

  alias ServiceRadar.AnalyticsStore.Compactor

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"table" => table}}), do: compact(table)

  @doc false
  def compact(table, opts \\ []) do
    run = Keyword.get(opts, :run, &Compactor.run/2)

    case run.(table, opts) do
      {:ok, _} -> :ok
      {:error, :analytics_head_busy} -> {:snooze, 60}
      {:error, _} = error -> error
    end
  end

  @impl Oban.Worker
  def timeout(_job), do: to_timeout(minute: 10)
end
