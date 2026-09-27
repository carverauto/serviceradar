defmodule ServiceRadar.Jobs.OrphanRescue do
  @moduledoc """
  A worker that can prove its own `executing` rows are dead, and so rescue them
  without waiting for a job-age threshold.

  A node that stops mid-run (rolling deploy, eviction, drain, OOMKill) leaves its
  Oban row `executing`. For a worker whose `unique` covers incomplete states that
  row blocks every new insert of the worker until something rescues it, and the
  generic rescuers (`Oban.Plugins.Lifeline` and the age-based sweep in
  `ServiceRadar.Jobs.ReapStalePeriodicJobsWorker`) can only go by age: they wait
  240 minutes because they cannot tell a dead run from a slow live one.

  A worker implementing this behaviour can tell. `rescue_orphaned/1` finds this
  worker's executing rows, rescues the ones it can prove no live process is
  running, and leaves every other row alone. The reaper calls it on each pass
  (see `ReapStalePeriodicJobsWorker.orphan_rescue_workers/0`) and the age-based
  sweep still runs afterwards as the fallback for anything the proof could not
  cover.

  The proof is the implementation's to make and must never produce a false
  positive for a live run; "cannot tell" has to mean "not an orphan".
  """

  alias ServiceRadar.Jobs.ReapStalePeriodicJobsWorker

  @doc """
  Rescue this worker's orphaned `executing` jobs.

  Returns the rows rescued, in the shape the reaper reports, or an error. It must
  not raise: the reaper runs it before the age-based sweep, and one worker's
  failure must not stop the others.
  """
  @callback rescue_orphaned(opts :: keyword()) ::
              {:ok, [ReapStalePeriodicJobsWorker.job_ref()]} | {:error, term()}
end
