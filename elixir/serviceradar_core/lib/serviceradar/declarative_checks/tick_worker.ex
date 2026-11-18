defmodule ServiceRadar.DeclarativeChecks.TickWorker do
  @moduledoc """
  Once a minute, inspects enabled `DeclarativeCheck` records and enqueues
  `CoreEvaluationWorker` jobs for checks whose `schedule.interval_seconds` is due (`2.4`).
  """

  use Oban.Worker,
    queue: :monitoring,
    max_attempts: 1,
    unique: [period: :infinity, states: [:available, :scheduled]]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.DeclarativeChecks.CoreEvaluationWorker
  alias ServiceRadar.DeclarativeChecks.DeclarativeCheck
  alias ServiceRadar.DeclarativeChecks.Evaluation

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    actor = SystemActor.system(:declarative_check_tick)
    now = Evaluation.db_now()

    with {:ok, checks} <- DeclarativeCheck.list_enabled(actor: actor) do
      due_checks = Enum.filter(checks, &CoreEvaluationWorker.due?(&1, now))
      Enum.each(due_checks, &CoreEvaluationWorker.ensure_scheduled/1)
      {:ok, length(due_checks)}
    end
  end
end
