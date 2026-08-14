defmodule ServiceRadar.CompositeChecks.Coverage do
  @moduledoc """
  Counts, per vantage point, how many devices in a check's scope have a
  non-stale availability row for that agent.

  This is the mitigation for the one structural weakness of a derivation-only
  design: a check whose vantage point has no sweep wired reports `inconclusive`
  forever and looks like it is working. Coverage turns that silence into a
  number the operator sees before enabling.
  """

  import Ecto.Query

  alias ServiceRadar.CompositeChecks.Scope
  alias ServiceRadar.Inventory.DeviceAgentAvailability
  alias ServiceRadar.Repo

  @type coverage_row :: %{
          input_key: String.t(),
          agent_id: String.t() | nil,
          covered: non_neg_integer(),
          total: non_neg_integer()
        }

  @spec for_check(struct(), [struct()], keyword()) :: {:ok, [coverage_row()]} | {:error, term()}
  def for_check(check, inputs, opts \\ []) do
    vantage_points = Enum.filter(inputs, &(&1.kind == :vantage_point))

    with {:ok, normalized} <- Scope.normalize(check.scope_query) do
      now = Keyword.get(opts, :now, DateTime.utc_now())

      {total, counts} =
        normalized
        |> Scope.stream_uids(opts)
        |> Enum.reduce({0, %{}}, fn uids, {total_acc, counts_acc} ->
          {total_acc + length(uids), tally_page(vantage_points, uids, now, counts_acc)}
        end)

      rows =
        Enum.map(vantage_points, fn input ->
          %{
            input_key: input.key,
            agent_id: Map.get(input.config, "agent_id"),
            covered: Map.get(counts, input.key, 0),
            total: total
          }
        end)

      {:ok, rows}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp tally_page(_vantage_points, [], _now, counts), do: counts

  defp tally_page(vantage_points, uids, now, counts) do
    Enum.reduce(vantage_points, counts, fn input, acc ->
      agent_id = Map.get(input.config, "agent_id")
      max_age = Map.get(input.config, "max_age_seconds")

      count =
        DeviceAgentAvailability
        |> where([r], r.device_uid in ^uids and r.agent_id == ^agent_id)
        |> apply_freshness(max_age, now)
        |> select([r], count(r.id))
        |> Repo.one()
        |> Kernel.||(0)

      Map.update(acc, input.key, count, &(&1 + count))
    end)
  end

  defp apply_freshness(query, nil, _now), do: query

  defp apply_freshness(query, max_age, now) when is_integer(max_age) do
    cutoff = DateTime.add(now, -max_age, :second)
    where(query, [r], r.checked_at >= ^cutoff)
  end
end
