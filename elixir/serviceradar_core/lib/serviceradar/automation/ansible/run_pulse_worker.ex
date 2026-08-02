defmodule ServiceRadar.Automation.Ansible.RunPulseWorker do
  @moduledoc """
  Per-controller pulse worker that drives event ingestion.

  Each tick:
    1. Loads non-terminal `PlaybookRun`s for the controller (those with
       `state ∈ [:pending, :launching, :running]`).
    2. Filters down to runs that have an `awx_job_id` (i.e. have at least
       reached `:launching`); skips `:pending` runs whose launch is in
       flight.
    3. If any qualify, dispatches `awx.fetch_events_for_jobs` commands via
       `AwxClient`, batching at most 10 `(awx_job_id, last_event_id)` pairs
       into each command.
    4. Self-reschedules at `controller.run_pulse_interval_ms` (clamped to
       a 1-second floor — Oban can't reliably do sub-second jobs).

  Result handling lives in `EventIngestor`; the worker is fire-and-forget
  with respect to the actual AWX response. See openspec change
  `add-ansible-integration` design.md decision 6 ("Event ingestion is
  pulse-based polling driven by an Elixir tick worker").
  """

  use Oban.Worker,
    queue: :ansible_pulse,
    max_attempts: 1,
    unique: [period: :infinity, states: :incomplete]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.AwxClient
  alias ServiceRadar.Automation.Ansible.Controller
  alias ServiceRadar.Automation.Ansible.PlaybookRun
  alias ServiceRadar.Automation.Ansible.SafeFailureEvidence
  alias ServiceRadar.Jobs.SelfScheduling
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @default_interval_ms 2_000
  @min_interval_seconds 1
  @max_event_batch_size 10

  @doc """
  Insert an initial pulse job for `controller_id` if one isn't already
  scheduled. Idempotent — call from app startup or after creating a new
  controller.
  """
  @spec ensure_scheduled(String.t()) ::
          {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:error, term()}
  def ensure_scheduled(controller_id) when is_binary(controller_id) do
    if scheduled_for?(controller_id) do
      {:ok, :already_scheduled}
    else
      %{"controller_id" => controller_id}
      |> new()
      |> ObanSupport.safe_insert()
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"controller_id" => controller_id}}) do
    actor = SystemActor.system(:awx_run_pulse_worker)

    case Controller.get_by_id(controller_id, actor: actor) do
      {:ok, %Controller{enabled: false}} ->
        # Controller paused -- end the chain (re-enabling re-seeds it).
        :ok

      {:ok, controller} ->
        case PlaybookRun.list_active_for_controller(controller.id, actor: actor) do
          {:ok, runs} ->
            _ = tick_controller(controller, runs, [])
            schedule_next(controller)
            :ok

          {:error, reason} ->
            Logger.warning("AWX RunPulseWorker: could not list active runs",
              controller_id: controller.id,
              reason: inspect(reason)
            )

            schedule_next(controller)
            {:error, reason}
        end

      {:error, _reason} ->
        # Controller deleted or not visible — let the chain die.
        :ok
    end
  end

  def perform(%Oban.Job{args: args}) do
    Logger.error("AWX RunPulseWorker: invalid args", args: inspect(args))
    {:error, :invalid_args}
  end

  @doc """
  Pure-ish tick: given a controller and its active runs, dispatches bounded
  `awx.fetch_events_for_jobs` batches if there is anything worth fetching.
  Exposed for unit tests; production calls this from `perform/1`.

  Options:
    * `:awx_client` (defaults to `AwxClient`) — overridable for tests.
  """
  @spec tick_controller(Controller.t(), [PlaybookRun.t() | map()], keyword()) ::
          :ok | {:error, term()}
  def tick_controller(%Controller{} = controller, runs, opts \\ []) when is_list(runs) do
    awx_client = Keyword.get(opts, :awx_client, AwxClient)
    pairs = build_pairs(runs)

    dispatch_batches(controller, pairs, awx_client)
  end

  ## Internals -----------------------------------------------------------------

  defp build_pairs(runs) do
    runs
    |> Enum.filter(fn run -> Map.get(run, :awx_job_id) end)
    |> Enum.map(fn run ->
      %{
        job_id: Map.fetch!(run, :awx_job_id),
        since_id: Map.get(run, :last_event_id, 0) || 0
      }
    end)
  end

  defp dispatch_batches(_controller, [], _awx_client), do: :ok

  defp dispatch_batches(controller, pairs, awx_client) do
    batches = Enum.chunk_every(pairs, @max_event_batch_size)
    batch_count = length(batches)
    active_run_count = length(pairs)

    batches
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {batch, batch_index}, :ok ->
      context = %{
        "controller_id" => controller.id,
        "verb" => "awx.fetch_events_for_jobs",
        "active_run_count" => active_run_count,
        "batch_count" => batch_count,
        "batch_index" => batch_index,
        "batch_run_count" => length(batch)
      }

      case awx_client.fetch_events_for_jobs(controller, batch,
             source: :automation,
             context: context
           ) do
        {:ok, _command} ->
          {:cont, :ok}

        {:error, reason} = error ->
          Logger.warning(
            "AWX RunPulseWorker: dispatch failed",
            [
              controller_id: controller.id,
              active_run_count: active_run_count,
              batch_count: batch_count,
              batch_index: batch_index,
              batch_run_count: length(batch)
            ] ++ SafeFailureEvidence.log_metadata(reason)
          )

          {:halt, error}
      end
    end)
  end

  defp schedule_next(%Controller{} = controller) do
    seconds = interval_seconds(controller)

    _ =
      __MODULE__
      |> SelfScheduling.successor_changeset(%{"controller_id" => controller.id}, seconds)
      |> ObanSupport.safe_insert()

    :ok
  end

  defp interval_seconds(%Controller{run_pulse_interval_ms: ms}) when is_integer(ms) and ms > 0 do
    max(@min_interval_seconds, div(ms, 1_000))
  end

  defp interval_seconds(_), do: max(@min_interval_seconds, div(@default_interval_ms, 1_000))

  defp scheduled_for?(controller_id) do
    import Ecto.Query

    query =
      from job in Oban.Job,
        where:
          job.worker == ^to_string(__MODULE__) and
            fragment("? -> ?", job.args, "controller_id") == ^controller_id and
            job.state in ["available", "scheduled", "executing", "retryable"],
        limit: 1

    ServiceRadar.Repo.exists?(query, prefix: ObanSupport.prefix())
  end
end
