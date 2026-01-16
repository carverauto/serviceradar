defmodule ServiceRadar.SweepJobs.SweepMonitorWorker do
  @moduledoc """
  Tenant-scoped Oban worker that monitors sweep groups for missed executions.

  Runs periodically for a specific tenant to check if any enabled sweep groups
  haven't received results within their expected interval plus a grace period.
  When a missed sweep is detected, it publishes an internal log to `logs.internal.sweep`
  which can be promoted to an event and potentially trigger alerts via
  the StatefulAlertRule system.

  ## Scheduling

  This worker is automatically scheduled when:
  - A sweep group is created with `enabled: true`
  - A sweep group is enabled via the `:enable` action

  The worker reschedules itself after each run if there are still enabled
  sweep groups for the tenant.

  ## Detection Logic

  For each enabled sweep group:
  1. Parse the configured interval (e.g., "15m", "1h", "1d")
  2. Calculate when the last sweep should have completed (last_run_at + interval + grace_period)
  3. If the current time exceeds this expected time, emit a missed sweep log

  ## Grace Period

  A configurable grace period (default 5 minutes) is added to the expected time
  to account for network latency, processing time, and clock drift.
  """

  use ServiceRadar.Oban.TenantWorker,
    queue_type: :monitoring,
    max_attempts: 3,
    unique: [period: 60, keys: [:tenant_id], states: [:available, :scheduled, :executing, :retryable]]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Events.InternalLogPublisher
  alias ServiceRadar.SweepJobs.SweepGroup

  require Logger
  require Ash.Query

  # Grace period added to expected sweep time before considering it missed
  @default_grace_period_seconds 300

  # How often to run the monitor (5 minutes)
  @monitor_interval_seconds 300

  @doc """
  Schedules sweep monitoring for a tenant if not already scheduled.

  Called automatically when sweep groups are created or enabled.
  """
  @spec ensure_scheduled(String.t()) :: {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:error, term()}
  def ensure_scheduled(tenant_id) when is_binary(tenant_id) do
    # Check if there's already a scheduled or executing job for this tenant
    case check_existing_job(tenant_id) do
      true ->
        {:ok, :already_scheduled}

      false ->
        enqueue(tenant_id, %{})
    end
  end

  defp check_existing_job(tenant_id) do
    import Ecto.Query

    query =
      from(j in Oban.Job,
        where: j.worker == ^to_string(__MODULE__),
        where: j.state in ["available", "scheduled", "executing", "retryable"],
        where: fragment("? ->> 'tenant_id' = ?", j.meta, ^tenant_id),
        limit: 1
      )

    ServiceRadar.Repo.exists?(query)
  end

  @impl ServiceRadar.Oban.TenantWorker
  @spec perform_for_tenant(map(), String.t(), Oban.Job.t()) ::
          :ok | {:ok, term()} | {:error, term()} | {:cancel, term()} | {:snooze, pos_integer()}
  def perform_for_tenant(args, tenant_id, _job) do
    grace_period_seconds = Map.get(args, "grace_period_seconds", @default_grace_period_seconds)

    Logger.info("Running sweep monitor check for tenant",
      tenant_id: tenant_id,
      grace_period_seconds: grace_period_seconds
    )

    case get_enabled_sweep_groups(tenant_id) do
      {:ok, groups} when groups != [] ->
        now = DateTime.utc_now()

        Enum.each(groups, fn group ->
          check_sweep_group(group, tenant_id, now, grace_period_seconds)
        end)

        # Reschedule for next check since there are still enabled groups
        schedule_next_check(tenant_id, args)
        :ok

      {:ok, []} ->
        Logger.info("No enabled sweep groups for tenant, not rescheduling monitor",
          tenant_id: tenant_id
        )

        :ok

      {:error, reason} ->
        Logger.error("Failed to get sweep groups for tenant",
          tenant_id: tenant_id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp schedule_next_check(tenant_id, args) do
    enqueue_in(tenant_id, args, @monitor_interval_seconds)
  end

  defp get_enabled_sweep_groups(tenant_id) do
    # DB connection's search_path determines the schema
    actor = SystemActor.system(:sweep_monitor)

    SweepGroup
    |> Ash.Query.for_read(:enabled_groups)
    |> Ash.read(tenant: tenant_id, actor: actor)
  end

  defp check_sweep_group(group, tenant_id, now, grace_period_seconds) do
    # Skip if never run - first run hasn't happened yet
    if is_nil(group.last_run_at) do
      Logger.debug("Skipping sweep group with no previous runs",
        group_id: group.id,
        group_name: group.name
      )
    else
      check_group_schedule(group, tenant_id, now, grace_period_seconds)
    end
  end

  defp check_group_schedule(%{schedule_type: :cron} = group, _tenant_id, _now, _grace_period_seconds) do
    Logger.debug("Skipping missed sweep check for cron schedule",
      group_id: group.id,
      group_name: group.name
    )
  end

  defp check_group_schedule(group, tenant_id, now, grace_period_seconds) do
    interval_seconds = parse_interval_to_seconds(group.interval)
    expected_by = calculate_expected_time(group.last_run_at, interval_seconds, grace_period_seconds)

    if DateTime.compare(now, expected_by) == :gt do
      emit_missed_sweep_log(group, tenant_id, now, expected_by)
    else
      Logger.debug("Sweep group is on schedule",
        group_id: group.id,
        group_name: group.name,
        expected_by: expected_by
      )
    end
  end

  defp calculate_expected_time(last_run_at, interval_seconds, grace_period_seconds) do
    DateTime.add(last_run_at, interval_seconds + grace_period_seconds, :second)
  end

  defp emit_missed_sweep_log(group, tenant_id, now, expected_by) do
    overdue_seconds = DateTime.diff(now, expected_by, :second)

    payload = %{
      "event_type" => "sweep.missed",
      "severity" => "warning",
      "sweep_group_id" => group.id,
      "sweep_group_name" => group.name,
      "partition" => group.partition,
      "agent_id" => group.agent_id,
      "interval" => group.interval,
      "last_run_at" => DateTime.to_iso8601(group.last_run_at),
      "expected_by" => DateTime.to_iso8601(expected_by),
      "overdue_seconds" => overdue_seconds,
      "message" => "Sweep group '#{group.name}' missed expected execution",
      "details" => %{
        "tenant_id" => tenant_id,
        "schedule_type" => to_string(group.schedule_type),
        "cron_expression" => group.cron_expression
      }
    }

    Logger.warning("Detected missed sweep",
      sweep_group_id: group.id,
      sweep_group_name: group.name,
      overdue_seconds: overdue_seconds
    )

    case InternalLogPublisher.publish("sweep", payload, tenant_id: tenant_id) do
      :ok ->
        Logger.info("Published missed sweep log",
          sweep_group_id: group.id,
          sweep_group_name: group.name
        )

      {:error, reason} ->
        Logger.error("Failed to publish missed sweep log",
          sweep_group_id: group.id,
          reason: inspect(reason)
        )
    end
  end

  @doc """
  Parses an interval string like "15m", "1h", "2d" into seconds.

  Supported units:
  - s: seconds
  - m: minutes
  - h: hours
  - d: days

  ## Examples

      iex> parse_interval_to_seconds("15m")
      900

      iex> parse_interval_to_seconds("1h")
      3600

      iex> parse_interval_to_seconds("1d")
      86_400

      iex> parse_interval_to_seconds("30s")
      30
  """
  @spec parse_interval_to_seconds(term()) :: integer()
  def parse_interval_to_seconds(interval) when is_binary(interval) do
    interval
    |> parse_interval_string()
    |> case do
      {:ok, seconds} ->
        seconds

      :error ->
        parse_interval_fallback(interval)

      {:error, :non_positive} ->
        Logger.warning("Interval must be positive, defaulting to 1 hour", interval: interval)
        3600
    end
  end

  def parse_interval_to_seconds(interval) do
    Logger.warning("Interval is not a string, defaulting to 1 hour",
      interval: inspect(interval)
    )

    3600
  end

  defp parse_interval_string(interval) do
    case Regex.run(~r/^(\d+)([smhd])$/i, interval) do
      [_, value, unit] ->
        seconds = String.to_integer(value) * unit_seconds(String.downcase(unit))

        if seconds > 0 do
          {:ok, seconds}
        else
          {:error, :non_positive}
        end

      nil ->
        :error
    end
  end

  defp unit_seconds("s"), do: 1
  defp unit_seconds("m"), do: 60
  defp unit_seconds("h"), do: 3_600
  defp unit_seconds("d"), do: 86_400

  defp parse_interval_fallback(interval) do
    case Integer.parse(interval) do
      {value, ""} when value > 0 ->
        value

      _ ->
        Logger.warning("Unable to parse interval string, defaulting to 1 hour",
          interval: interval
        )

        3_600
    end
  end
end
