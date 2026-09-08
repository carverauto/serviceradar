defmodule ServiceRadar.Jobs.PruneStaleAgentsWorker do
  @moduledoc """
  Retires stale historical agent rows so active operator selectors stay usable.

  The worker intentionally marks stale rows unavailable instead of deleting them.
  Agent rows can be referenced by release history, plugin assignments, sweep groups,
  and audit trails, so hard deletion would be too aggressive for routine cleanup.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 3_600, states: :incomplete]

  import Ash.Expr

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.Agent

  require Ash.Query
  require Logger

  @default_retention_hours 24
  @default_batch_size 500

  @type result :: %{retired: non_neg_integer(), cutoff: DateTime.t()}

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    args
    |> atomize_args()
    |> prune()
    |> case do
      {:ok, %{retired: retired, cutoff: cutoff}} ->
        if retired > 0 do
          Logger.info("Retired stale agent rows",
            retired: retired,
            cutoff: DateTime.to_iso8601(cutoff)
          )
        end

        :ok

      {:error, reason} ->
        Logger.warning("Failed to retire stale agent rows", reason: inspect(reason))
        {:error, reason}
    end
  end

  @spec prune(keyword() | map()) :: {:ok, result()} | {:error, term()}
  def prune(opts \\ []) do
    opts = normalize_opts(opts)
    cutoff = cutoff(opts)

    batch_size =
      opts
      |> Keyword.get(:batch_size, @default_batch_size)
      |> positive_integer(@default_batch_size)

    actor = SystemActor.system(:stale_agent_pruner)

    stale_agents =
      Agent
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(
        expr(
          status in [:connecting, :connected, :degraded, :disconnected, :unavailable] and
            (is_nil(last_seen_time) or last_seen_time < ^cutoff)
        )
      )
      |> Ash.Query.limit(batch_size)
      |> Ash.read(actor: actor)

    case stale_agents do
      {:ok, %Ash.Page.Keyset{results: results}} ->
        retire_batch(results, actor, cutoff)

      {:ok, results} when is_list(results) ->
        retire_batch(results, actor, cutoff)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp retire_batch([], _actor, cutoff), do: {:ok, %{retired: 0, cutoff: cutoff}}

  defp retire_batch(agents, actor, cutoff) do
    result =
      Ash.bulk_update(agents, :retire_stale, %{},
        actor: actor,
        return_errors?: true,
        return_records?: false
      )

    case result do
      %Ash.BulkResult{status: :success, records: records} ->
        {:ok, %{retired: count_bulk_records(records, agents), cutoff: cutoff}}

      %Ash.BulkResult{status: :partial_success, records: records, errors: errors} ->
        Logger.warning("Partially retired stale agent rows", errors: inspect(errors))
        {:ok, %{retired: count_bulk_records(records, agents), cutoff: cutoff}}

      %Ash.BulkResult{status: :error, errors: errors} ->
        {:error, errors}
    end
  end

  defp cutoff(opts) do
    retention_hours =
      case Keyword.get(opts, :retention_hours) do
        nil ->
          opts
          |> Keyword.get(:retention_days, configured_retention_hours())
          |> retention_hours_from_days_or_hours(opts)

        hours ->
          positive_integer(hours, configured_retention_hours())
      end

    DateTime.add(DateTime.utc_now(), -retention_hours * 3_600, :second)
  end

  defp retention_hours_from_days_or_hours(value, opts) do
    if Keyword.has_key?(opts, :retention_days) do
      value
      |> positive_integer(configured_retention_days())
      |> Kernel.*(24)
    else
      positive_integer(value, configured_retention_hours())
    end
  end

  defp configured_retention_hours do
    :serviceradar_core
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:retention_hours, configured_retention_days() * 24)
  end

  defp configured_retention_days do
    :serviceradar_core
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:retention_days, div(@default_retention_hours, 24))
  end

  defp count_bulk_records(records, _fallback) when is_list(records), do: length(records)
  defp count_bulk_records(_records, fallback), do: length(fallback)

  defp normalize_opts(opts) when is_list(opts), do: opts
  defp normalize_opts(opts) when is_map(opts), do: Map.to_list(opts)
  defp normalize_opts(_opts), do: []

  defp atomize_args(args) when is_map(args) do
    []
    |> maybe_put_arg(:retention_days, Map.get(args, "retention_days"))
    |> maybe_put_arg(:retention_hours, Map.get(args, "retention_hours"))
    |> maybe_put_arg(:batch_size, Map.get(args, "batch_size"))
  end

  defp atomize_args(_args), do: %{}

  defp maybe_put_arg(opts, _key, nil), do: opts
  defp maybe_put_arg(opts, key, value), do: Keyword.put(opts, key, value)

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp positive_integer(_value, default), do: default
end
