defmodule ServiceRadar.Inventory.Availability.Readiness do
  @moduledoc """
  Whether a deployment in `shadow` is ready for the automatic cutover (design
  Decision 10, "Automatic progression"). Every condition must hold; none is a timer:

    * `capture_backfill`: the stage-a backfill has nothing left
      (`CaptureBackfillWorker.pending?/0`).
    * `shadow_resolve`: a full shadow resolution of every live device started after the
      deployment entered `shadow` and finished (`shadow_resolved_at`, written by
      `ShadowEntryWorker`).
    * `invalidation_backlog`: at most 500 entries wait in the invalidation log, one
      resolver pass (`Resolution.batch_size/0`); the next pass clears all of them.
    * `sweep_groups`: every active sweep group has completed a run, per agent, that
      started after the deployment entered `shadow`. A group is active for an agent when
      the group is enabled and that agent started a run of it in the last 24 hours, so a
      disabled group, or one no connected agent runs, does not block.
    * `policy_violations`: the divergence report counts no policy violation
      (`DivergenceReport.policy_violations/1`).

  A deployment with no devices and no sweep groups meets every condition as soon as
  the full pass over its zero devices has run. Each condition is one bounded query;
  nothing is loaded per device.
  """

  alias ServiceRadar.Inventory.Availability.CaptureBackfillWorker
  alias ServiceRadar.Inventory.Availability.DivergenceReport
  alias ServiceRadar.Inventory.Availability.Resolution
  alias ServiceRadar.Repo

  @samples 20

  @conditions [
    "capture_backfill",
    "shadow_resolve",
    "invalidation_backlog",
    "sweep_groups",
    "policy_violations"
  ]

  @backlog """
  SELECT count(*) FROM (SELECT 1 FROM platform.availability_invalidations LIMIT $1) AS capped
  """

  # The column rounds to the nearest second, so a run counts only from two seconds
  # after the truncated entry. A value rounded up from the entry's own second does
  # not count.
  @sweeps_waiting """
  WITH active AS (
    SELECT DISTINCT g.id, g.name, COALESCE(e.agent_id, '') AS agent_id
    FROM platform.sweep_groups AS g
    JOIN platform.sweep_group_executions AS e
      ON e.sweep_group_id = g.id
     AND e.started_at >= (now() AT TIME ZONE 'utc') - interval '24 hours'
    WHERE g.enabled
  )
  SELECT a.id::text, a.name, a.agent_id, count(*) OVER ()
  FROM active AS a
  WHERE NOT EXISTS (
    SELECT 1 FROM platform.sweep_group_executions AS c
    WHERE c.sweep_group_id = a.id AND COALESCE(c.agent_id, '') = a.agent_id
      AND c.status = 'completed'
      AND c.started_at >= date_trunc('second', $1::timestamp) + interval '2 seconds'
  )
  ORDER BY a.name, a.id, a.agent_id
  LIMIT $2
  """

  @type evaluation :: %{String.t() => term()}

  @doc "The condition names, in evaluation order."
  @spec conditions() :: [String.t()]
  def conditions, do: @conditions

  @doc "The largest invalidation backlog the cutover waits for."
  @spec backlog_threshold() :: pos_integer()
  def backlog_threshold, do: Resolution.batch_size()

  @doc """
  Evaluates every condition for a deployment that entered `shadow` at `entered_at`
  and last finished a full shadow resolution at `resolved_at` (either may be `nil`).
  Returns a JSON-ready map: `"ready"`, `"unmet"` (the names that do not hold, in
  order) and `"conditions"` (each name to `%{"met" => boolean, ...detail}`).
  """
  @spec evaluate(NaiveDateTime.t() | nil, NaiveDateTime.t() | nil) :: evaluation()
  def evaluate(entered_at, resolved_at) do
    conditions = %{
      "capture_backfill" => %{"met" => not CaptureBackfillWorker.pending?()},
      "shadow_resolve" => shadow_resolve(entered_at, resolved_at),
      "invalidation_backlog" => backlog(),
      "sweep_groups" => sweep_groups(entered_at),
      "policy_violations" => policy_violations()
    }

    unmet = Enum.reject(@conditions, &get_in(conditions, [&1, "met"]))
    %{"ready" => unmet == [], "unmet" => unmet, "conditions" => conditions}
  end

  defp shadow_resolve(entered_at, resolved_at) do
    met? =
      match?(%NaiveDateTime{}, entered_at) and match?(%NaiveDateTime{}, resolved_at) and
        NaiveDateTime.compare(resolved_at, entered_at) != :lt

    %{"met" => met?, "resolved_at" => iso8601(resolved_at)}
  end

  defp backlog do
    threshold = backlog_threshold()
    %{rows: [[count]]} = Repo.query!(@backlog, [threshold + 1])

    %{
      "met" => count <= threshold,
      "backlog" => count,
      "capped" => count > threshold,
      "threshold" => threshold
    }
  end

  # Without an entry time no run can count, so every active group waits.
  defp sweep_groups(entered_at) do
    since = entered_at || ~N[9999-12-31 00:00:00]
    %{rows: rows} = Repo.query!(@sweeps_waiting, [since, @samples])

    waiting =
      Enum.map(rows, fn [id, name, agent_id, _total] ->
        %{"id" => id, "name" => name, "agent_id" => agent_id}
      end)

    total =
      case rows do
        [[_id, _name, _agent_id, total] | _rest] -> total
        [] -> 0
      end

    %{"met" => total == 0, "waiting" => total, "samples" => waiting}
  end

  defp policy_violations do
    %{count: count, samples: samples} = DivergenceReport.policy_violations(@samples)
    %{"met" => count == 0, "count" => count, "samples" => samples}
  end

  defp iso8601(%NaiveDateTime{} = at),
    do: at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  defp iso8601(_at), do: nil
end
