defmodule ServiceRadar.SweepJobs.SweepMonitorWorker do
  @moduledoc """
  Oban worker that monitors sweep groups for missed executions.

  Runs periodically to check if any enabled sweep groups haven't received
  results within their expected interval plus a grace period. When a missed
  sweep is detected, it publishes an internal log to `logs.internal.sweep`
  which can be promoted to an event and potentially trigger alerts via
  the StatefulAlertRule system.

  ## Detection Logic

  For each enabled sweep group:
  1. Parse the configured interval (e.g., "15m", "1h", "1d")
  2. Calculate when the last sweep should have completed (last_run_at + interval + grace_period)
  3. If the current time exceeds this expected time, emit a missed sweep log

  ## Grace Period

  A configurable grace period (default 5 minutes) is added to the expected time
  to account for network latency, processing time, and clock drift.
  """

  use Oban.Worker,
    queue: :monitoring,
    max_attempts: 3,
    unique: [period: 60, states: [:available, :scheduled, :executing, :retryable]]

  alias ServiceRadar.Events.InternalLogPublisher
  alias ServiceRadar.SweepJobs.SweepGroup

  require Logger
  require Ash.Query

  # Grace period added to expected sweep time before considering it missed
  @default_grace_period_seconds 300

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    grace_period_seconds = Map.get(args, "grace_period_seconds", @default_grace_period_seconds)

    Logger.info("Running sweep monitor check", grace_period_seconds: grace_period_seconds)

    # Get all tenants
    case get_all_tenants() do
      {:ok, tenants} ->
        Enum.each(tenants, fn tenant ->
          check_tenant_sweep_groups(tenant, grace_period_seconds)
        end)

        :ok

      {:error, reason} ->
        Logger.error("Failed to get tenants for sweep monitoring", reason: inspect(reason))
        {:error, reason}
    end
  end

  defp get_all_tenants do
    ServiceRadar.Identity.Tenant
    |> Ash.read(authorize?: false)
  end

  defp check_tenant_sweep_groups(tenant, grace_period_seconds) do
    case get_enabled_sweep_groups(tenant.id) do
      {:ok, groups} ->
        now = DateTime.utc_now()

        Enum.each(groups, fn group ->
          check_sweep_group(group, tenant, now, grace_period_seconds)
        end)

      {:error, reason} ->
        Logger.warning("Failed to get sweep groups for tenant",
          tenant_id: tenant.id,
          reason: inspect(reason)
        )
    end
  end

  defp get_enabled_sweep_groups(tenant_id) do
    SweepGroup
    |> Ash.Query.for_read(:enabled_groups)
    |> Ash.read(tenant: tenant_id, authorize?: false)
  end

  defp check_sweep_group(group, tenant, now, grace_period_seconds) do
    # Skip if never run - first run hasn't happened yet
    if is_nil(group.last_run_at) do
      Logger.debug("Skipping sweep group with no previous runs",
        group_id: group.id,
        group_name: group.name
      )
    else
      case group.schedule_type do
        :cron ->
          Logger.debug("Skipping missed sweep check for cron schedule",
            group_id: group.id,
            group_name: group.name
          )

        _ ->
          interval_seconds = parse_interval_to_seconds(group.interval)
          expected_by = calculate_expected_time(group.last_run_at, interval_seconds, grace_period_seconds)

          if DateTime.compare(now, expected_by) == :gt do
            # Sweep is overdue
            emit_missed_sweep_log(group, tenant, now, expected_by)
          else
            Logger.debug("Sweep group is on schedule",
              group_id: group.id,
              group_name: group.name,
              expected_by: expected_by
            )
          end
      end
    end
  end

  defp calculate_expected_time(last_run_at, interval_seconds, grace_period_seconds) do
    DateTime.add(last_run_at, interval_seconds + grace_period_seconds, :second)
  end

  defp emit_missed_sweep_log(group, tenant, now, expected_by) do
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
        "tenant_id" => tenant.id,
        "tenant_slug" => tenant.slug,
        "schedule_type" => to_string(group.schedule_type),
        "cron_expression" => group.cron_expression
      }
    }

    Logger.warning("Detected missed sweep",
      sweep_group_id: group.id,
      sweep_group_name: group.name,
      overdue_seconds: overdue_seconds
    )

    case InternalLogPublisher.publish("sweep", payload,
           tenant_id: tenant.id,
           tenant_slug: to_string(tenant.slug)
         ) do
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
      86400

      iex> parse_interval_to_seconds("30s")
      30
  """
  @spec parse_interval_to_seconds(term()) :: integer()
  def parse_interval_to_seconds(interval) when is_binary(interval) do
    case Regex.run(~r/^(\d+)([smhd])$/i, interval) do
      [_, value, unit] ->
        value = String.to_integer(value)

        seconds =
          case String.downcase(unit) do
            "s" -> value
            "m" -> value * 60
            "h" -> value * 3600
            "d" -> value * 86400
          end

        if seconds > 0 do
          seconds
        else
          Logger.warning("Interval must be positive, defaulting to 1 hour", interval: interval)
          3600
        end

      nil ->
        # Try parsing as just a number (assume seconds)
        case Integer.parse(interval) do
          {value, ""} when value > 0 ->
            value

          _ ->
            Logger.warning("Unable to parse interval string, defaulting to 1 hour",
              interval: interval
            )

            3600
        end
    end
  end

  def parse_interval_to_seconds(interval) do
    Logger.warning("Interval is not a string, defaulting to 1 hour",
      interval: inspect(interval)
    )

    3600
  end
end
