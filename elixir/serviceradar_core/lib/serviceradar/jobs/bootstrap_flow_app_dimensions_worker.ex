defmodule ServiceRadar.Jobs.BootstrapFlowAppDimensionsWorker do
  @moduledoc """
  Initialize retained flow application history one closed UTC hour at a time.

  The migration enqueues one durable maintenance job without scanning raw data.
  Its arguments capture the earliest hour and an exclusive upper cursor. Refreshes
  walk backward from the newest closed hour so materialized coverage stays
  contiguous with the regular recent-data policy. Progress is saved only after
  success; a crash before that update repeats the same idempotent hour.
  """

  use Oban.Worker,
    queue: :maintenance,
    priority: 3,
    max_attempts: 10,
    unique: [period: :infinity, fields: [:worker], states: :incomplete]

  alias ServiceRadar.Repo

  @view "platform.ocsf_network_activity_hourly_app_dimensions"
  @history_seconds 395 * 86_400
  @query_timeout 60_000

  @impl Oban.Worker
  def perform(job), do: run(job)

  @impl Oban.Worker
  def timeout(_job), do: 90_000

  @doc false
  def run(%Oban.Job{} = job, opts \\ []) do
    query = Keyword.get(opts, :query, &Repo.query/3)
    checkpoint = Keyword.get(opts, :checkpoint, &checkpoint/2)

    with {:ok, %{rows: [[view]]}} <-
           query.("SELECT to_regclass('#{@view}')", [], timeout: @query_timeout) do
      if is_nil(view),
        do: :ok,
        else: run_present(job, query, checkpoint, opts)
    end
  end

  defp run_present(%Oban.Job{args: args} = job, query, checkpoint, opts)
       when map_size(args) == 0 do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    finish = hour(now)
    earliest = DateTime.add(finish, -@history_seconds, :second)

    sql = """
    SELECT time_bucket('1 hour', time)
    FROM platform.ocsf_network_activity
    WHERE time >= $1 AND time < $2
    ORDER BY time ASC LIMIT 1
    """

    case query.(sql, [earliest, finish], timeout: @query_timeout) do
      {:ok, %{rows: []}} ->
        :ok

      {:ok, %{rows: [[%DateTime{} = first]]}} ->
        persist(job, first, finish, checkpoint)

      {:error, _} = error ->
        error
    end
  end

  defp run_present(%Oban.Job{args: args} = job, query, checkpoint, _opts) do
    with {:ok, first, finish} <- range(args) do
      if DateTime.compare(first, finish) == :eq do
        :ok
      else
        previous = DateTime.add(finish, -3_600, :second)

        with {:ok, _} <-
               query.(
                 "CALL refresh_continuous_aggregate('#{@view}', $1::timestamptz, $2::timestamptz)",
                 [previous, finish],
                 timeout: @query_timeout
               ) do
          persist(job, first, previous, checkpoint)
        end
      end
    end
  end

  defp persist(job, first, finish, checkpoint) do
    args = %{
      "start_hour" => DateTime.to_iso8601(first),
      "next_hour" => DateTime.to_iso8601(finish)
    }

    with {:ok, _} <- checkpoint.(job, args) do
      if DateTime.compare(first, finish) == :eq, do: :ok, else: {:snooze, 1}
    end
  end

  defp checkpoint(job, args), do: Oban.update_job(job, %{args: args})

  defp range(%{"start_hour" => first, "next_hour" => finish})
       when is_binary(first) and is_binary(finish) do
    with {:ok, first, 0} <- DateTime.from_iso8601(first),
         {:ok, finish, 0} <- DateTime.from_iso8601(finish),
         true <-
           DateTime.compare(hour(first), first) == :eq and
             DateTime.compare(hour(finish), finish) == :eq,
         seconds when seconds >= 0 and seconds <= @history_seconds <- DateTime.diff(finish, first) do
      {:ok, first, finish}
    else
      _ -> {:error, :invalid_flow_bootstrap_checkpoint}
    end
  end

  defp range(_), do: {:error, :invalid_flow_bootstrap_checkpoint}

  defp hour(datetime) do
    datetime
    |> DateTime.to_unix()
    |> Integer.floor_div(3_600)
    |> Kernel.*(3_600)
    |> DateTime.from_unix!()
  end
end
