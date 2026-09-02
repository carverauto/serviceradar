defmodule ServiceRadar.Integrations.ArmisNorthboundRetention do
  @moduledoc """
  Bounded retention for successful Armis northbound target detail.

  Accepted rows are high-volume operational detail whose aggregate counts are
  retained on the parent run. Withheld, failed, and unattempted rows are never
  pruned here because they are unresolved diagnostic or repair evidence.
  """

  import Ecto.Query

  alias ServiceRadar.Repo

  @default_retention_days 30
  @minimum_retention_days 7
  @default_batch_size 50_000
  @maximum_batch_size 50_000

  @spec prune(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def prune(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    retention_days = retention_days(opts)
    batch_size = batch_size(opts)
    cutoff = DateTime.add(now, -retention_days * 86_400, :second)

    candidates =
      from(target in "integration_update_run_targets",
        prefix: "platform",
        where: target.outcome == "accepted" and target.updated_at < ^cutoff,
        order_by: [asc: target.updated_at, asc: target.id],
        limit: ^batch_size,
        select: target.id
      )

    query =
      from(target in "integration_update_run_targets",
        prefix: "platform",
        where: target.id in subquery(candidates)
      )

    case Repo.delete_all(query) do
      {count, _rows} -> {:ok, count}
      other -> {:error, {:unexpected_retention_result, other}}
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  end

  @doc false
  def retention_days(opts) do
    configured =
      Keyword.get_lazy(opts, :retention_days, fn ->
        Application.get_env(
          :serviceradar_core,
          :armis_northbound_target_retention_days,
          @default_retention_days
        )
      end)

    if is_integer(configured) and configured >= @minimum_retention_days,
      do: configured,
      else: @default_retention_days
  end

  defp batch_size(opts) do
    configured = Keyword.get(opts, :batch_size, @default_batch_size)

    if is_integer(configured) and configured > 0,
      do: min(configured, @maximum_batch_size),
      else: @default_batch_size
  end
end
