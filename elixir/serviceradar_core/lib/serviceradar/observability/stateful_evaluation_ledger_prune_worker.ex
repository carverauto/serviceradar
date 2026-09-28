defmodule ServiceRadar.Observability.StatefulEvaluationLedgerPruneWorker do
  @moduledoc """
  Daily prune of `ServiceRadar.Observability.StatefulEvaluationLedger` rows
  older than its retention window.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  alias ServiceRadar.Observability.StatefulEvaluationLedger

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: StatefulEvaluationLedger.prune()
end
