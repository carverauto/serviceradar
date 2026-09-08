defmodule ServiceRadar.Jobs.ScheduleHealthCheck do
  @moduledoc """
  Pure staleness detection for `ng_job_schedules` rows.

  An enabled schedule is considered stale when its `last_enqueued_at` (or
  `inserted_at`, when it has never been enqueued) is older than twice the
  schedule's cron interval, with a 10-minute floor so high-frequency crons
  do not flap on ordinary scheduler jitter.

  This is how the 5-minute `device_identity_reconciliation` cron silently
  died for four months: the AshOban scheduler kept completing while
  enqueueing nothing, and `last_enqueued_at` froze with no alert. See
  `ServiceRadar.Jobs.ScheduleHealthWorker` for the periodic runner.
  """

  alias Oban.Cron.Expression

  @stale_factor 2
  @min_staleness_seconds 600

  @type schedule :: %{
          optional(atom()) => any()
        }

  @type stale_entry :: %{
          job_key: String.t() | nil,
          cron: String.t() | nil,
          interval_seconds: pos_integer(),
          threshold_seconds: pos_integer(),
          seconds_since_enqueue: non_neg_integer(),
          last_enqueued_at: DateTime.t() | nil
        }

  @doc """
  Return stale entries for the given enabled schedules.

  Accepts any enumerable of structs/maps with `:job_key`, `:cron`,
  `:timezone`, `:enabled`, `:last_enqueued_at`, and `:inserted_at` fields
  (i.e. `ServiceRadar.Jobs.JobSchedule` records).
  """
  @spec stale_schedules(Enumerable.t(), DateTime.t()) :: [stale_entry()]
  def stale_schedules(schedules, now \\ DateTime.utc_now()) do
    schedules
    |> Enum.filter(&Map.get(&1, :enabled, false))
    |> Enum.flat_map(fn schedule ->
      case check_schedule(schedule, now) do
        {:stale, entry} -> [entry]
        _ -> []
      end
    end)
  end

  @doc """
  Check a single schedule. Returns `{:stale, entry}`, `:ok`, or
  `{:skip, reason}` when the schedule cannot be evaluated (unparseable
  cron, no reference timestamp).
  """
  @spec check_schedule(schedule(), DateTime.t()) ::
          {:stale, stale_entry()} | :ok | {:skip, term()}
  def check_schedule(schedule, now \\ DateTime.utc_now()) do
    with {:ok, interval} <-
           interval_seconds(Map.get(schedule, :cron), Map.get(schedule, :timezone) || "Etc/UTC"),
         {:ok, reference} <- reference_timestamp(schedule) do
      threshold = max(interval * @stale_factor, @min_staleness_seconds)
      elapsed = DateTime.diff(now, reference, :second)

      if elapsed > threshold do
        {:stale,
         %{
           job_key: Map.get(schedule, :job_key),
           cron: Map.get(schedule, :cron),
           interval_seconds: interval,
           threshold_seconds: threshold,
           seconds_since_enqueue: elapsed,
           last_enqueued_at: Map.get(schedule, :last_enqueued_at)
         }}
      else
        :ok
      end
    else
      {:error, reason} -> {:skip, reason}
    end
  end

  @doc """
  Infer the nominal interval (in seconds) of a cron expression by measuring
  the gap between its next two fire times.
  """
  @spec interval_seconds(String.t() | nil, String.t()) ::
          {:ok, pos_integer()} | {:error, term()}
  def interval_seconds(cron, timezone \\ "Etc/UTC")

  def interval_seconds(nil, _timezone), do: {:error, :no_cron}

  def interval_seconds(cron, timezone) when is_binary(cron) do
    with {:ok, expr} <- Expression.parse(cron),
         %DateTime{} = now <- safe_now(timezone),
         %DateTime{} = first <- Expression.next_at(expr, now),
         %DateTime{} = second <- Expression.next_at(expr, first) do
      {:ok, max(DateTime.diff(second, first, :second), 60)}
    else
      :unknown -> {:error, :unschedulable_cron}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_cron, other}}
    end
  end

  defp reference_timestamp(schedule) do
    case Map.get(schedule, :last_enqueued_at) || Map.get(schedule, :inserted_at) do
      %DateTime{} = reference -> {:ok, reference}
      _ -> {:error, :no_reference_timestamp}
    end
  end

  defp safe_now(timezone) do
    case DateTime.now(timezone) do
      {:ok, now} -> now
      _ -> DateTime.utc_now()
    end
  end
end
