defmodule ServiceRadar.Automation.Ansible.RetentionWorker do
  @moduledoc """
  Daily sweep that prunes detail rows from old `PlaybookRun`s.

  Two configurable thresholds (per openspec change `add-ansible-integration`
  task 8.1, surfaced via `helm/serviceradar/values.yaml` and
  `docker-compose.yml`):

  | App env | Default | Effect |
  |---|---|---|
  | `:ansible_retention_run_detail_days` | 90 | Past this age, drop the run's `PlaybookPlay` / `PlaybookTask` / `PlaybookTaskResult` hierarchy. Run + targets + summary fields stay. |
  | `:ansible_retention_run_summary_days` | nil | When set, past this age the entire run (including targets) is deleted. nil = keep forever. |

  Single global Oban worker, fires once a day. The `pruning_plan/2`
  helper is exposed for unit tests; the actual Ash bulk_destroy lives
  in `perform/1`.

  v1 limitation: the "skip runs accessed within the last hour" rule from
  design.md isn't implemented yet -- requires adding an `accessed_at`
  field to PlaybookRun. For now the worker prunes purely by `ended_at`
  age. Operator can avoid surprises by setting `run_detail_days`
  generously (default 90 is conservative).
  """

  use Oban.Worker,
    queue: :ansible_retention,
    max_attempts: 1,
    unique: [period: :infinity, states: :incomplete]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.PlaybookPlay
  alias ServiceRadar.Automation.Ansible.PlaybookRun
  alias ServiceRadar.Jobs.SelfScheduling
  alias ServiceRadar.SweepJobs.ObanSupport

  require Ash.Query
  require Logger

  @default_run_detail_days 90
  @default_interval_seconds 24 * 60 * 60
  @min_interval_seconds 60 * 60

  @terminal_states [:succeeded, :partial, :failed, :unreachable, :canceled]

  @spec ensure_scheduled() ::
          {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:error, term()}
  def ensure_scheduled do
    if scheduled?() do
      {:ok, :already_scheduled}
    else
      %{} |> new() |> ObanSupport.safe_insert()
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    actor = SystemActor.system(:awx_retention_worker)
    now = DateTime.utc_now()
    plan = pruning_plan(read_config(), now)

    case do_prune(plan, actor) do
      {:ok, summary} ->
        Logger.info("AWX RetentionWorker: pruning complete", summary: inspect(summary))
        schedule_next()
        :ok

      {:error, reason} ->
        Logger.warning("AWX RetentionWorker: pruning failed", reason: inspect(reason))
        schedule_next()
        {:error, reason}
    end
  end

  ## Pure helpers --------------------------------------------------------------

  @typedoc "Effective retention configuration."
  @type config :: %{
          required(:run_detail_days) => pos_integer() | :disabled,
          required(:run_summary_days) => pos_integer() | nil
        }

  @typedoc "Plan describing which deletions to perform."
  @type plan :: %{
          required(:detail_cutoff) => DateTime.t() | nil,
          required(:summary_cutoff) => DateTime.t() | nil
        }

  @doc """
  Loads retention values from the application environment, falling back
  to documented defaults. Returns `:disabled` for `run_detail_days = 0`
  so operators can opt out.
  """
  @spec read_config() :: config()
  def read_config do
    %{
      run_detail_days:
        normalize_days(
          Application.get_env(
            :serviceradar_core,
            :ansible_retention_run_detail_days,
            @default_run_detail_days
          )
        ),
      run_summary_days:
        normalize_optional_days(
          Application.get_env(:serviceradar_core, :ansible_retention_run_summary_days, nil)
        )
    }
  end

  @doc """
  Compute the pruning plan from a config + reference time.
  """
  @spec pruning_plan(config(), DateTime.t()) :: plan()
  def pruning_plan(config, %DateTime{} = now) do
    %{
      detail_cutoff: cutoff_for(config.run_detail_days, now),
      summary_cutoff: cutoff_for(config.run_summary_days, now)
    }
  end

  @doc """
  Compute a cutoff DateTime from a day count. `nil` or `:disabled`
  yields `nil` (no cutoff). Negative or zero day counts also yield
  `nil`. Positive returns `now - days × 86400 seconds`.
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

  defp do_prune(%{detail_cutoff: nil, summary_cutoff: nil}, _actor) do
    Logger.info("AWX RetentionWorker: both retention windows disabled, no-op")
    {:ok, %{detail_runs_pruned: 0, summary_runs_pruned: 0}}
  end

  defp do_prune(plan, actor) do
    with {:ok, detail_count} <- prune_details(plan.detail_cutoff, actor),
         {:ok, summary_count} <- prune_summaries(plan.summary_cutoff, actor) do
      {:ok, %{detail_runs_pruned: detail_count, summary_runs_pruned: summary_count}}
    end
  end

  defp prune_details(nil, _actor), do: {:ok, 0}

  defp prune_details(%DateTime{} = cutoff, actor) do
    run_ids = old_terminal_run_ids(cutoff, actor)

    if run_ids == [] do
      {:ok, 0}
    else
      # PlaybookPlay also has no primary read action, and bulk_destroy reads the
      # query before deleting — so the query must name the `:read` action
      # explicitly, otherwise the read phase raises "No primary action of type
      # :read". (Passing `read_action:` alone is not enough: bulk_destroy raises
      # while validating the unvalidated query before that option is consulted.)
      _ =
        PlaybookPlay
        |> Ash.Query.for_read(:read, %{}, actor: actor)
        |> Ash.Query.filter(run_id in ^run_ids)
        |> Ash.bulk_destroy(:destroy, %{}, actor: actor, return_errors?: false)

      {:ok, length(run_ids)}
    end
  end

  defp prune_summaries(nil, _actor), do: {:ok, 0}

  defp prune_summaries(%DateTime{} = cutoff, actor) do
    run_ids = old_terminal_run_ids(cutoff, actor)

    if run_ids == [] do
      {:ok, 0}
    else
      # Postgres `references` block on PlaybookRunTarget / PlaybookPlay /
      # ... cascades on PlaybookRun delete. So destroying the run row
      # cleans up the rest.
      #
      # PlaybookRun has no primary read action, and bulk_destroy reads the query
      # before deleting — name the `:read` action explicitly so the read phase
      # doesn't raise "No primary action of type :read".
      _ =
        PlaybookRun
        |> Ash.Query.for_read(:read, %{}, actor: actor)
        |> Ash.Query.filter(id in ^run_ids)
        |> Ash.bulk_destroy(:destroy, %{}, actor: actor, return_errors?: false)

      {:ok, length(run_ids)}
    end
  end

  defp old_terminal_run_ids(cutoff, actor) do
    # PlaybookRun deliberately has no primary read action (see playbook_run.ex —
    # kept so state-transition updates don't attempt atomic upgrades), so a bare
    # read must name the `:read` action explicitly or Ash raises
    # "No primary action of type :read".
    PlaybookRun
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(
      state in ^@terminal_states and not is_nil(ended_at) and ended_at < ^cutoff
    )
    |> Ash.Query.select([:id])
    |> Ash.read!(actor: actor)
    |> Enum.map(& &1.id)
  end

  defp schedule_next do
    _ =
      ObanSupport.safe_insert(
        SelfScheduling.successor_changeset(__MODULE__, %{}, interval_seconds())
      )

    :ok
  end

  defp interval_seconds do
    seconds =
      Application.get_env(
        :serviceradar_core,
        :ansible_retention_interval_seconds,
        @default_interval_seconds
      )

    max(@min_interval_seconds, seconds)
  end

  defp scheduled? do
    import Ecto.Query

    query =
      from job in Oban.Job,
        where:
          job.worker == ^to_string(__MODULE__) and
            job.state in ["available", "scheduled", "executing", "retryable"],
        limit: 1

    ServiceRadar.Repo.exists?(query, prefix: ObanSupport.prefix())
  end

  defp normalize_days(0), do: :disabled
  defp normalize_days(n) when is_integer(n) and n > 0, do: n
  defp normalize_days(_), do: @default_run_detail_days

  defp normalize_optional_days(nil), do: nil
  defp normalize_optional_days(0), do: nil
  defp normalize_optional_days(n) when is_integer(n) and n > 0, do: n
  defp normalize_optional_days(_), do: nil
end
