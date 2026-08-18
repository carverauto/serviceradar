defmodule ServiceRadar.CompositeChecks.Rollup do
  @moduledoc """
  Verdict counts per composite check, for index pages and northbound summaries.

  A grouped count is not a natural Ash read — Ash aggregates attach to a parent
  resource and do not express "group by two columns" — so this is one Ecto
  query, kept in core rather than in a LiveView. `Coverage` does the same for
  the same reason.

  One query covers every check asked for. The alternative, an aggregate per
  check, is an N+1 that grows with the number of authored checks, which is
  exactly what an index page must not do.
  """

  import Ecto.Query

  alias ServiceRadar.CompositeChecks.DeviceCompositeCheckResult
  alias ServiceRadar.Repo

  @type verdict_count :: %{verdict: String.t(), status: atom(), count: non_neg_integer()}

  @doc """
  Returns `%{check_id => [verdict_count]}`, ordered most common first.

  Checks with no results are absent from the map rather than present with an
  empty list, so a caller can tell "no results yet" from "zero of everything".
  """
  @spec for_checks([Ash.UUID.t()]) :: %{optional(Ash.UUID.t()) => [verdict_count()]}
  def for_checks([]), do: %{}

  def for_checks(check_ids) when is_list(check_ids) do
    DeviceCompositeCheckResult
    |> where([r], r.check_id in ^check_ids)
    |> group_by([r], [r.check_id, r.verdict, r.status])
    |> select([r], {r.check_id, r.verdict, r.status, count(r.id)})
    |> Repo.all()
    |> Enum.group_by(
      fn {check_id, _verdict, _status, _count} -> check_id end,
      fn {_check_id, verdict, status, count} ->
        %{verdict: verdict, status: status, count: count}
      end
    )
    |> Map.new(fn {check_id, counts} ->
      {check_id, Enum.sort_by(counts, & &1.count, :desc)}
    end)
  end

  @doc "Total devices holding any verdict for a check."
  @spec total([verdict_count()] | nil) :: non_neg_integer()
  def total(nil), do: 0
  def total(counts) when is_list(counts), do: Enum.sum_by(counts, & &1.count)
end
