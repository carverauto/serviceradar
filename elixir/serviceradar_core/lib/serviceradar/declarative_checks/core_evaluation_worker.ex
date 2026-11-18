defmodule ServiceRadar.DeclarativeChecks.CoreEvaluationWorker do
  @moduledoc """
  Oban worker (`queue: :declarative_checks`) executing scheduled and debounced
  Hybrid Edge-observation passes for enabled `DeclarativeCheck` records (`2.4`).
  """

  use Oban.Worker,
    queue: :declarative_checks,
    max_attempts: 1,
    unique: [keys: [:check_id], states: :incomplete, period: :infinity]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.DeclarativeChecks.DeclarativeCheck
  alias ServiceRadar.DeclarativeChecks.Evaluation
  alias ServiceRadar.DeclarativeChecks.SchemaValidator
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @hybrid_debounce_seconds 30

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"check_id" => check_id} = args}) do
    actor = SystemActor.system(:declarative_check_worker)
    force? = Map.get(args, "trigger") == "hybrid_edge_refresh"

    case DeclarativeCheck.get_by_id(check_id, actor: actor) do
      {:ok, %{state: :enabled} = check} ->
        now = Evaluation.db_now()

        if force? or due?(check, now) do
          handle_result(check, Evaluation.run_full(check, actor: actor, now: now))
        else
          {:ok, :not_due}
        end

      {:ok, _disabled_or_draft} ->
        {:ok, :skipped}

      {:error, _reason} ->
        {:cancel, "declarative check #{check_id} no longer exists"}
    end
  end

  @doc """
  Returns `true` when `check` is Core-only or Hybrid and its `schedule.interval_seconds`
  has elapsed since `last_evaluated_at`.
  """
  @spec due?(map(), DateTime.t()) :: boolean()
  def due?(check, %DateTime{} = now) when is_map(check) do
    nodes = Map.get(check, :nodes) || Map.get(check, "nodes") || []

    if SchemaValidator.classify_topology(nodes) == :edge_only do
      false
    else
      case Map.get(check, :last_evaluated_at) do
        nil ->
          true

        %DateTime{} = last ->
          sched = Map.get(check, :schedule) || Map.get(check, "schedule") || %{}

          interval =
            Map.get(sched, "interval_seconds") || Map.get(sched, :interval_seconds) || 300

          DateTime.diff(now, last, :second) >= interval
      end
    end
  end

  @doc """
  Enqueues an immediate evaluation job for an enabled Core or Hybrid declarative check.
  """
  @spec ensure_scheduled(map()) :: {:ok, term()} | {:error, term()}
  def ensure_scheduled(%{state: :enabled, id: id} = check) do
    nodes = Map.get(check, :nodes) || Map.get(check, "nodes") || []

    if SchemaValidator.classify_topology(nodes) == :edge_only do
      {:ok, :edge_only}
    else
      if ObanSupport.available?() do
        %{"check_id" => to_string(id)}
        |> new()
        |> ObanSupport.safe_insert()
      else
        {:error, :oban_unavailable}
      end
    end
  end

  def ensure_scheduled(_), do: {:ok, :not_enabled}

  @doc """
  Enqueues a debounced (`30s`) Hybrid refresh job when new Edge branch observations
  are ingested for `check_id`. Uniqueness coalesces bursts into a single run.
  """
  @spec schedule_debounced_hybrid_refresh(String.t()) :: {:ok, term()} | {:error, term()}
  def schedule_debounced_hybrid_refresh(check_id) when is_binary(check_id) do
    if ObanSupport.available?() do
      %{"check_id" => check_id, "trigger" => "hybrid_edge_refresh"}
      |> new(schedule_in: @hybrid_debounce_seconds)
      |> ObanSupport.safe_insert()
    else
      {:error, :oban_unavailable}
    end
  end

  @doc "Cancels any pending evaluation jobs for `check_id`."
  @spec cancel(term()) :: :ok
  def cancel(check_id) do
    import Ecto.Query

    Oban.Job
    |> where([j], j.worker == ^Oban.Worker.to_string(__MODULE__))
    |> where([j], j.state in ["available", "scheduled", "retryable"])
    |> where([j], fragment("? ->> 'check_id' = ?", j.args, ^to_string(check_id)))
    |> Oban.cancel_all_jobs()

    :ok
  rescue
    _ -> :ok
  end

  defp handle_result(check, {:ok, summary}) do
    Logger.debug("declarative check evaluated",
      check_id: check.id,
      evaluated: summary.evaluated,
      transitions: length(summary.transitions),
      removed: summary.removed
    )

    {:ok, summary}
  end

  defp handle_result(check, {:error, reason} = err) do
    Logger.warning("declarative check evaluation failed",
      check_id: check.id,
      reason: inspect(reason)
    )

    err
  end
end
