defmodule ServiceRadar.Inventory.Availability.ResolverWorker do
  @moduledoc """
  Drains the availability invalidation log (`availability_invalidations`, design
  Decision 1, "The worker"). Scheduled every minute; each run makes passes until the log
  is empty or its time budget is spent.

  One pass is one transaction:

  1. Claims the oldest visible log rows:
     `DELETE ... WHERE id IN (SELECT id ... ORDER BY id LIMIT n FOR UPDATE SKIP LOCKED)
     RETURNING`. A row from a writer that has not committed is invisible and stays for
     a later pass; `SKIP LOCKED` only lets concurrent passes share the log. Writers
     append with a plain INSERT and never lock log rows, so no writer waits on a pass.
  2. Deduplicates the claimed devices in claim order and takes at most 500; any other
     claimed device is appended again before commit.
  3. Resolves them (`Resolution.resolve_locked/2`, device rows locked in uid order).
  4. Commits. A failure rolls the claim back with everything else.

  A write that commits after the claim left its own row, so the next pass resolves the
  device again from the newer inputs.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 55, states: [:available, :scheduled]]

  alias ServiceRadar.Inventory.Availability.Resolution
  alias ServiceRadar.Repo

  require Logger

  @claim_limit 2_000
  @budget_ms 30_000

  @claim """
  DELETE FROM platform.availability_invalidations
  WHERE id IN (
    SELECT id FROM platform.availability_invalidations
    ORDER BY id
    LIMIT $1
    FOR UPDATE SKIP LOCKED
  )
  RETURNING id, device_uid
  """

  @reappend """
  INSERT INTO platform.availability_invalidations (device_uid) SELECT unnest($1::text[])
  """

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    deadline = System.monotonic_time(:millisecond) + @budget_ms
    totals = drain(deadline, %{passes: 0, claimed: 0, resolved: 0, written: 0})

    if totals.claimed > 0 do
      Logger.debug("availability resolver drained the invalidation log", Map.to_list(totals))
    end

    :ok
  end

  @doc """
  One pass: claims, deduplicates, resolves at most 500 devices and
  re-appends the rest, in one transaction. Returns what it did.
  """
  @spec pass() :: %{
          claimed: non_neg_integer(),
          resolved: non_neg_integer(),
          written: non_neg_integer()
        }
  def pass do
    {:ok, result} =
      Repo.transaction(fn ->
        %{rows: claimed} = Repo.query!(@claim, [@claim_limit])

        uids =
          claimed
          |> Enum.sort_by(&hd/1)
          |> Enum.map(&List.last/1)
          |> Enum.uniq()

        if uids == [] do
          %{claimed: length(claimed), resolved: 0, written: 0}
        else
          {batch, overflow} = Enum.split(uids, Resolution.batch_size())
          if overflow != [], do: Repo.query!(@reappend, [overflow])
          Map.put(Resolution.resolve_locked(batch), :claimed, length(claimed))
        end
      end)

    result
  end

  defp drain(deadline, totals) do
    result = pass()

    totals = %{
      passes: totals.passes + 1,
      claimed: totals.claimed + result.claimed,
      resolved: totals.resolved + result.resolved,
      written: totals.written + result.written
    }

    if result.claimed > 0 and System.monotonic_time(:millisecond) < deadline,
      do: drain(deadline, totals),
      else: totals
  end
end
