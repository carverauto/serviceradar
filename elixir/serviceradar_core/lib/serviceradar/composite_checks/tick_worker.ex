defmodule ServiceRadar.CompositeChecks.TickWorker do
  @moduledoc """
  Once a minute, inserts one `ServiceRadar.CompositeChecks.EvaluationWorker` job
  per enabled composite check.

  This is the only scheduler composite checks have. The minute is the
  incremental interval; each job decides for itself whether the full pass is
  due. Evaluation jobs are unique per check over available, scheduled and
  executing, so a tick that lands while a check's pass is still running
  inserts nothing for that check, and the next tick after it completes inserts
  exactly one.

  Scheduled from the Oban Cron crontab in both runtime configs (the
  `serviceradar_core_elx` one is what the release loads).
  """

  use Oban.Worker, queue: :monitoring, max_attempts: 1

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.CompositeChecks.EvaluationWorker

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    actor = SystemActor.system(:composite_check_tick)

    with {:ok, checks} <- CompositeCheck.list_enabled(actor: actor) do
      Enum.each(checks, &EvaluationWorker.ensure_scheduled/1)
      {:ok, length(checks)}
    end
  end
end
