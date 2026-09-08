defmodule ServiceRadar.Notifications.DispatchSchedule do
  @moduledoc """
  Shared builder for the notification platform's Oban cron entries and scheduled
  worker configuration.

  Same contract, and same reason, as
  `ServiceRadar.Observability.ProductionSchedule`: both
  `serviceradar_core/config/runtime.exs` and the deployed release's
  `serviceradar_core_elx/config/runtime.exs` build their crontab from this one
  module, so the two config trees cannot drift apart. Drift there is how the
  seasonal and episode workers silently vanished from production, and the same
  drift here would silently stop every retry and every escalation - the platform
  would look healthy and simply never page twice. Functions take a
  `System.get_env/2`-shaped fetcher so the env gating stays testable without
  mutating the process environment.

  To add an entry: add a `defp <name>_entries/1` clause returning `[]` or
  `[{cron_expression, WorkerModule, opts}]` and list it in `cron_entries/1`.

  ## What is scheduled, and what is not

  | Worker | Cron | Queue |
  | --- | --- | --- |
  | `ContinuationWorker` | every minute | `:notifications` |
  | `ReceiptWorker` | every minute | `:notifications` |
  | `SilenceExpiryWorker` | every minute | `:notifications` |
  | `DeliveryRetentionWorker` | daily 04:11 | `:maintenance` |

  `RoutingWorker` and `DispatchWorker` are **not** here and must not be added.
  They are event-driven: routing is enqueued by the alert lifecycle (design D8
  reserves originating a first notification for it alone) and by
  `ContinuationWorker` for a due escalation rung; dispatch is enqueued by
  routing. A cron entry for either would be a third origination path racing the
  other two.

  The retention pass is on `:maintenance` rather than `:notifications` because it
  is a daily bulk delete that can run for minutes; see that worker's moduledoc.

  ## Is `:notifications` concurrency 5 still sane?

  Yes, and the queue is not the binding constraint - but the reasoning is worth
  writing down, because "we added four workers to a queue of five" is exactly the
  shape of change that quietly caps throughput.

  Of the four workers on `:notifications`, three are short and database-only:
  `RoutingWorker` runs a handful of indexed reads and inserts, and the two
  sweepers run once a minute each and occupy a slot for well under a second. Only
  `DispatchWorker` makes a network call, so in steady state roughly five
  concurrent transport attempts is the ceiling. At a pessimistic two-second
  round trip that is about 150 sends per minute, well above what any single
  destination accepts: a Slack incoming webhook is about one message per second.

  Two properties keep that ceiling from being eaten by waiting rather than
  sending. A delivery that is over its channel's `rate_limit_per_minute` gets
  `{:retry, at}` from `Dispatcher.deliver/2` **before** any request is made, and
  the worker answers `{:snooze, seconds}`, which releases the slot immediately -
  a busy channel therefore cannot occupy the queue on behalf of an idle one. And
  a delivery waiting out its backoff is a scheduled Oban row, not a running job.

  Raise it with `OBAN_QUEUE_NOTIFICATIONS` if a deployment fans out to enough
  distinct destinations to saturate five, which is a fan-out problem rather than
  a per-destination one.
  """

  alias ServiceRadar.Notifications.ContinuationWorker
  alias ServiceRadar.Notifications.DeliveryRetentionWorker
  alias ServiceRadar.Notifications.ReceiptWorker
  alias ServiceRadar.Notifications.SilenceExpiryWorker

  @type env_fetch :: (String.t(), String.t() | nil -> String.t() | nil)
  @type cron_entry :: {String.t(), module()} | {String.t(), module(), keyword()}

  @truthy ["1", "true", "yes", "on"]

  # Offset from the retention passes already parked in the small hours (03:17
  # observability, 03:23 security events, 03:31 remote access, 03:43 credential
  # broker, 04:23 cold tier) so two large deletes do not contend.
  @default_retention_cron "11 4 * * *"

  @doc """
  The notification cron entries production must run, honoring the operator env
  gates and cron overrides.
  """
  @spec cron_entries(env_fetch()) :: [cron_entry()]
  def cron_entries(fetch \\ &System.get_env/2) do
    Enum.concat([
      continuation_entries(fetch),
      receipt_entries(fetch),
      silence_expiry_entries(fetch),
      delivery_retention_entries(fetch)
    ])
  end

  @doc """
  Runtime options for `ServiceRadar.Notifications.ContinuationWorker`
  (`config :serviceradar_core, ContinuationWorker, ...`). Only keys the operator
  explicitly set are returned, so the worker's own defaults stay authoritative
  when unset.
  """
  @spec continuation_worker_config(env_fetch()) :: keyword()
  def continuation_worker_config(fetch \\ &System.get_env/2) do
    present(
      limit: positive_int(fetch, "SERVICERADAR_NOTIFICATION_CONTINUATION_LIMIT"),
      stall_seconds: positive_int(fetch, "SERVICERADAR_NOTIFICATION_DISPATCH_STALL_SECONDS")
    )
  end

  @doc """
  Runtime options for `ServiceRadar.Notifications.ReceiptWorker`
  (tasks 3.4.4, 3.4.6).
  """
  @spec receipt_worker_config(env_fetch()) :: keyword()
  def receipt_worker_config(fetch \\ &System.get_env/2) do
    present(limit: positive_int(fetch, "SERVICERADAR_NOTIFICATION_RECEIPT_LIMIT"))
  end

  @doc """
  Runtime options for `ServiceRadar.Notifications.SilenceExpiryWorker`.
  """
  @spec silence_expiry_worker_config(env_fetch()) :: keyword()
  def silence_expiry_worker_config(fetch \\ &System.get_env/2) do
    present(limit: positive_int(fetch, "SERVICERADAR_NOTIFICATION_SILENCE_SWEEP_LIMIT"))
  end

  @doc """
  Runtime options for `ServiceRadar.Notifications.DeliveryRetentionWorker`.

  The retention window is deliberately independent of
  `ALERT_RETENTION_CRON`/`AlertsRetentionWorker`'s three days: a delivery
  outlives the alert it points at.
  """
  @spec delivery_retention_worker_config(env_fetch()) :: keyword()
  def delivery_retention_worker_config(fetch \\ &System.get_env/2) do
    present(
      retention_days: positive_int(fetch, "SERVICERADAR_NOTIFICATION_DELIVERY_RETENTION_DAYS"),
      batch_size: positive_int(fetch, "SERVICERADAR_NOTIFICATION_DELIVERY_RETENTION_BATCH_SIZE"),
      max_batches: positive_int(fetch, "SERVICERADAR_NOTIFICATION_DELIVERY_RETENTION_MAX_BATCHES")
    )
  end

  # Retry and escalation both flow through this tick. Turning it off is a
  # supported operation - a deployment bringing the platform up in stages wants
  # it - but it means a failed delivery is never retried and an unacknowledged
  # alert never climbs its ladder, so it is off only when an operator says so.
  defp continuation_entries(fetch) do
    if truthy?(fetch, "SERVICERADAR_NOTIFICATION_CONTINUATION_ENABLED", "true") do
      [
        {fetch.("SERVICERADAR_NOTIFICATION_CONTINUATION_CRON", "* * * * *"), ContinuationWorker,
         queue: :notifications}
      ]
    else
      []
    end
  end

  # The receipt sweep is what makes an agent-routed delivery reach a terminal
  # state without depending on `:status_handler_enabled` (tasks 3.4.4). Turning
  # it off is supported for the same reason the continuation tick can be turned
  # off - a staged bring-up - but it means an accepted agent command remains
  # `:dispatching`; `due/2` intentionally refuses to re-send it blind.
  defp receipt_entries(fetch) do
    if truthy?(fetch, "SERVICERADAR_NOTIFICATION_RECEIPT_SWEEP_ENABLED", "true") do
      [
        {fetch.("SERVICERADAR_NOTIFICATION_RECEIPT_SWEEP_CRON", "* * * * *"), ReceiptWorker,
         queue: :notifications}
      ]
    else
      []
    end
  end

  defp silence_expiry_entries(fetch) do
    if truthy?(fetch, "SERVICERADAR_NOTIFICATION_SILENCE_SWEEP_ENABLED", "true") do
      [
        {fetch.("SERVICERADAR_NOTIFICATION_SILENCE_SWEEP_CRON", "* * * * *"), SilenceExpiryWorker,
         queue: :notifications}
      ]
    else
      []
    end
  end

  defp delivery_retention_entries(fetch) do
    if truthy?(fetch, "SERVICERADAR_NOTIFICATION_DELIVERY_RETENTION_ENABLED", "true") do
      [
        {fetch.("SERVICERADAR_NOTIFICATION_DELIVERY_RETENTION_CRON", @default_retention_cron),
         DeliveryRetentionWorker, queue: :maintenance}
      ]
    else
      []
    end
  end

  defp truthy?(fetch, name, default) do
    String.downcase(fetch.(name, default) || default) in @truthy
  end

  defp present(config), do: Enum.reject(config, fn {_key, value} -> is_nil(value) end)

  # Fails fast with the variable named rather than booting with a silently
  # wrong window: `String.to_integer/1` would raise an unattributable error at
  # release boot, and a permissive parse would turn "30d" into 30 without
  # anyone noticing it had been read as days-not-days.
  defp positive_int(fetch, name) do
    case fetch.(name, nil) do
      nil ->
        nil

      "" ->
        nil

      value ->
        case Integer.parse(value) do
          {int, ""} when int > 0 ->
            int

          _invalid ->
            raise ArgumentError, "invalid positive integer for #{name}: #{inspect(value)}"
        end
    end
  end
end
