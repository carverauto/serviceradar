defmodule ServiceRadar.Credentials.BrokerRetentionWorker do
  @moduledoc """
  Daily sweep that prunes expired credential broker grants and secret resolution
  audits, along with their `ash_paper_trail` version rows.

  ## Why this exists

  A broker grant is ephemeral -- `ttl_seconds` defaults to 300 -- but nothing
  ever deleted one. `CredentialBrokerGrant` has no destroy action at all, and
  while it declares an `:expire` transition, nothing calls it. Expiry is enforced
  where it matters, at resolution time in `SecretBroker`, so a stale row is not a
  security problem; it is purely storage that never comes back.

  On demo that reached 462,419 grants, every one still `:issued` and 462,406 of
  them already past `expires_at`, accumulating since 2026-05-21 at ~3,900/day
  from polling callers (AWX token refresh, proxmox inventory, unifi camera
  discovery). With version rows the four tables totalled ~1.9 GB:

  | table | rows | size |
  |---|---|---|
  | `credential_broker_grant_versions` | 457,457 | 779 MB |
  | `credential_secret_resolution_audit_versions` | 493,093 | 646 MB |
  | `credential_broker_grants` | 457,389 | 284 MB |
  | `credential_secret_resolution_audits` | 466,029 | 174 MB |

  The version tables dominate because both resources set
  `store_action_inputs? true`, so each row carries the full action input map.

  ## Thresholds

  | App env | Default | Effect |
  |---|---|---|
  | `:credential_broker_grant_retention_days` | 14 | Past this age (measured from `expires_at`), delete the grant and its versions. |
  | `:credential_secret_resolution_audit_retention_days` | 30 | Past this age (measured from `occurred_at`), delete the audit and its versions. |

  `0` or a negative value disables that half, so an operator can opt out without
  removing the job. Audits keep longer than grants deliberately: a grant records
  that authority was handed out, an audit records what was actually resolved, and
  the latter is the one you want during an incident review.

  ## Why raw SQL rather than `Ash.bulk_destroy`

  Both resources set `create_version_on_destroy? false`, so an Ash destroy would
  not write new versions -- but it also would not remove the *existing* ones, and
  those are three quarters of the bytes. Version rows are paper_trail-internal
  and have no destroy action of their own. Deleting by age on each table directly
  is both the only way to reach the versions and far cheaper than reading 460k
  records into memory to destroy them one by one.

  Deletion is batched (`@batch_size` per statement, `@max_batches` per table per
  run) so a single run holds short locks and cannot monopolise a connection while
  working through a large backlog. A run that hits `@max_batches` simply makes
  progress and continues tomorrow.

  ## Scheduling

  Driven by the Oban crontab alongside `DataRetentionWorker` and
  `AlertsRetentionWorker`, rather than self-scheduling. `SERVICERADAR_CREDENTIAL_BROKER_RETENTION_CRON`
  overrides the default. It deliberately does not also self-schedule: cron and a
  successor insert would both enqueue, and `unique: [states: :incomplete]` only
  collapses those while one is still pending.

  ### Ordering

  `credential_secret_resolution_audit_versions.version_source_id` has a real
  foreign key to `credential_secret_resolution_audits` with `ON DELETE NO ACTION`,
  so versions must be deleted before their parents or the parent delete raises.
  The grant/version pair has no such constraint, but is deleted in the same order
  for consistency.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1,
    unique: [period: :infinity, states: :incomplete]

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Repo

  require Logger

  @default_grant_retention_days 14
  @default_audit_retention_days 30

  # Bounded so one run cannot hold a connection indefinitely against a large
  # backlog. 462k rows clears in a few runs rather than one very long one.
  @batch_size 5_000
  @max_batches 40

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    plan = pruning_plan(read_config(), DateTime.utc_now())

    case do_prune(plan) do
      {:ok, summary} ->
        Logger.info("Credential broker retention completed", summary: inspect(summary))
        :ok

      {:error, reason} ->
        Logger.warning("Credential broker retention failed", reason: inspect(reason))
        {:error, reason}
    end
  end

  ## Pure helpers --------------------------------------------------------------

  @typedoc "Effective retention configuration."
  @type config :: %{
          required(:grant_days) => pos_integer() | :disabled,
          required(:audit_days) => pos_integer() | :disabled
        }

  @typedoc "Plan describing which cutoffs to apply."
  @type plan :: %{
          required(:grant_cutoff) => DateTime.t() | nil,
          required(:audit_cutoff) => DateTime.t() | nil
        }

  @doc "Loads retention values from application env, falling back to defaults."
  @spec read_config() :: config()
  def read_config do
    %{
      grant_days:
        normalize_days(
          Application.get_env(
            :serviceradar_core,
            :credential_broker_grant_retention_days,
            @default_grant_retention_days
          )
        ),
      audit_days:
        normalize_days(
          Application.get_env(
            :serviceradar_core,
            :credential_secret_resolution_audit_retention_days,
            @default_audit_retention_days
          )
        )
    }
  end

  @doc "Compute the pruning plan from a config and a reference time."
  @spec pruning_plan(config(), DateTime.t()) :: plan()
  def pruning_plan(config, %DateTime{} = now) do
    %{
      grant_cutoff: cutoff_for(config.grant_days, now),
      audit_cutoff: cutoff_for(config.audit_days, now)
    }
  end

  @doc """
  Compute a cutoff from a day count. `nil`, `:disabled`, a non-integer, or a
  count of zero or less all yield `nil`, meaning "prune nothing".
  """
  @spec cutoff_for(pos_integer() | nil | :disabled, DateTime.t()) :: DateTime.t() | nil
  def cutoff_for(nil, _now), do: nil
  def cutoff_for(:disabled, _now), do: nil
  def cutoff_for(days, _now) when not is_integer(days), do: nil
  def cutoff_for(days, _now) when days <= 0, do: nil

  def cutoff_for(days, %DateTime{} = now) when is_integer(days) and days > 0 do
    DateTime.add(now, -days * 86_400, :second)
  end

  ## Internals -----------------------------------------------------------------

  defp do_prune(%{grant_cutoff: nil, audit_cutoff: nil}) do
    Logger.info("Credential broker retention: both windows disabled, no-op")
    {:ok, %{grants: 0, grant_versions: 0, audits: 0, audit_versions: 0}}
  end

  defp do_prune(plan) do
    # Versions first: audit versions carry a real FK to their parent with
    # ON DELETE NO ACTION, so the parent delete raises while any remain.
    with {:ok, grant_versions} <-
           delete_by_age(
             "credential_broker_grant_versions",
             "version_inserted_at",
             plan.grant_cutoff
           ),
         {:ok, grants} <-
           delete_by_age("credential_broker_grants", "expires_at", plan.grant_cutoff),
         {:ok, audit_versions} <-
           delete_by_age(
             "credential_secret_resolution_audit_versions",
             "version_inserted_at",
             plan.audit_cutoff
           ),
         {:ok, audits} <-
           delete_by_age("credential_secret_resolution_audits", "occurred_at", plan.audit_cutoff) do
      {:ok,
       %{
         grants: grants,
         grant_versions: grant_versions,
         audits: audits,
         audit_versions: audit_versions
       }}
    end
  end

  defp delete_by_age(_table, _column, nil), do: {:ok, 0}

  defp delete_by_age(table, column, %DateTime{} = cutoff) do
    # ctid is the cheapest way to cap a DELETE: the subquery walks the index on
    # `column`, takes a bounded slice, and the outer delete addresses those exact
    # physical rows. Ordering is deliberately omitted -- any @batch_size matching
    # rows are equally valid to remove, and sorting 460k rows per batch is pure
    # cost. Same shape as the batched prune in the flow-attribution fix (#4329).
    sql = """
    DELETE FROM platform.#{table}
    WHERE ctid IN (
      SELECT ctid FROM platform.#{table}
      WHERE #{column} < $1
      LIMIT #{@batch_size}
    )
    """

    delete_batches(sql, cutoff, table, 0, 0)
  end

  defp delete_batches(_sql, _cutoff, table, total, batches) when batches >= @max_batches do
    Logger.info(
      "Credential broker retention: hit batch cap, remaining rows deferred to next run",
      table: table,
      deleted: total
    )

    {:ok, total}
  end

  defp delete_batches(sql, cutoff, table, total, batches) do
    case SQL.query(Repo, sql, [cutoff]) do
      {:ok, %{num_rows: 0}} ->
        {:ok, total}

      {:ok, %{num_rows: n}} when n < @batch_size ->
        {:ok, total + n}

      {:ok, %{num_rows: n}} ->
        delete_batches(sql, cutoff, table, total + n, batches + 1)

      {:error, reason} ->
        Logger.warning("Credential broker retention: delete failed",
          table: table,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp normalize_days(value) when is_integer(value) and value > 0, do: value
  defp normalize_days(value) when is_integer(value), do: :disabled

  defp normalize_days(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} -> normalize_days(parsed)
      :error -> :disabled
    end
  end

  defp normalize_days(_), do: :disabled
end
