defmodule ServiceRadar.Jobs.SelfScheduling do
  @moduledoc """
  The successor-insert path shared by every self-rescheduling Oban worker.

  ## The invariant

  A self-scheduling worker inserts its own next run from inside `perform/1`. At that moment
  the current job is in the `executing` state, so the successor MUST be made unique only
  against `scheduled` jobs:

      unique: [states: :scheduled]

  Oban's default uniqueness spans every incomplete state, `executing` included. Under that
  default the successor is deduplicated against the job currently inserting it, the insert
  is silently dropped, and the worker simply stops rescheduling itself -- no crash, no error
  log, just a background job that quietly never runs again.

  The seed insert wants the opposite: `unique_states(:incomplete)`, so that scheduling a
  worker that is already pending is a no-op rather than a duplicate.

  ## Why this module exists

  That option literal used to be written out at all 26 call sites, and the only thing keeping
  them consistent was a test that read the workers' own source and grepped for the string.
  That test could not see the three workers missing from its hardcoded list, and it broke
  entirely under Bazel, where a compiled module's `:source` points at a build tree that no
  longer exists.

  With the option in one place, the workers have nothing to get wrong, and
  `successor_changeset/3` gives the test an actual changeset to assert on instead of a
  substring.
  """

  alias ServiceRadar.SweepJobs.ObanSupport

  @successor_unique [states: :scheduled]

  @doc """
  Uniqueness options for a successor insert. See the module docs for why it is not the
  default.
  """
  @spec successor_unique() :: keyword()
  def successor_unique, do: @successor_unique

  @doc """
  The changeset `worker` would insert as its own successor.

  Public so the contract is observable: `ServiceRadar.Jobs.SelfSchedulingWorkerUniquenessTest`
  builds one per worker and asserts on the resulting `:unique` change, rather than inspecting
  source or compiled artefacts.
  """
  @spec successor_changeset(module(), map(), pos_integer()) :: Ecto.Changeset.t()
  def successor_changeset(worker, args, schedule_in)
      when is_atom(worker) and is_map(args) and is_integer(schedule_in) and schedule_in > 0 do
    worker.new(args, schedule_in: schedule_in, unique: @successor_unique)
  end

  @doc """
  Build and insert `worker`'s successor.

  Goes through `ObanSupport.safe_insert/2`, so a caller running where Oban is not started
  (web-ng, some tests) gets `{:error, :oban_unavailable}` rather than a crash.
  """
  @spec insert_successor(module(), map(), pos_integer(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def insert_successor(worker, args, schedule_in, opts \\ []) do
    worker
    |> successor_changeset(args, schedule_in)
    |> ObanSupport.safe_insert(opts)
  end
end
