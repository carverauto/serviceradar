defmodule ServiceRadar.Notifications.SilenceExpiryWorker do
  @moduledoc """
  Moves `ServiceRadar.Notifications.NotificationSilence` rows across the clock
  boundaries of their own windows: `:scheduled -> :active` when a window opens,
  and `:scheduled | :active -> :expired` when it closes.

  A silence is the object whose entire purpose is to stop a page, so the state
  it is left in is a correctness property rather than bookkeeping. Suppression
  reads `:active_at`, which requires `state == :active` **and** the instant to
  fall inside the window - both halves, deliberately (see that resource's
  moduledoc). This worker is what keeps the state half true.

  ## Expiry runs before activation

  Not arbitrary. A silence that should have expired but is still `:active`
  suppresses pages an operator is owed; a silence that should have activated but
  is still `:scheduled` produces one page too many. Missing a page is the worse
  failure, so releasing suppression is the half that runs first and the half that
  survives a tick that dies partway through.

  ## Idempotency comes from the selection, not from a guard here

  `read :due_to_activate` filters `state == :scheduled` and
  `read :due_to_expire` filters `state in [:scheduled, :active]` - in both cases
  the *target* state is excluded from the source set. A row this worker already
  transitioned is therefore no longer returned, so a repeated tick, an Oban
  retry, and two nodes ticking at once all resolve to "nothing to do" rather than
  to an `AshStateMachine` invalid-transition error.

  That is why this worker drives **only** rows those two reads return. Widening
  the selection, or transitioning a row obtained some other way, moves
  idempotency from the database to a guard someone has to remember to write.
  A row that changes state between the read and the write is still possible - a
  concurrent `:cancel`, say - and is logged and skipped, not raised: one
  cancelled silence must not stop the tick from expiring the rest.

  `max_attempts: 1` for the same reason as the continuation sweeper: a failed
  tick is superseded a minute later by a fresh scan, and re-running a stale scan
  is strictly worse than re-scanning.

  ## Queue

  `:notifications`, concurrency 5. Two indexed reads and a bounded number of
  single-row updates per minute.
  """

  use Oban.Worker,
    queue: :notifications,
    max_attempts: 1,
    unique: [period: :infinity, states: :incomplete]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Notifications.NotificationSilence
  alias ServiceRadar.SweepJobs.ObanSupport

  require Ash.Query
  require Logger

  # Expiry first: see the moduledoc. Each pair is {read action, update action}.
  @passes [{:due_to_expire, :expire}, {:due_to_activate, :activate}]

  @default_limit 500

  @doc """
  The per-tick bound, from `config :serviceradar_core, #{inspect(__MODULE__)},
  limit: _`.
  """
  @spec config() :: %{limit: pos_integer()}
  def config do
    app_config = Application.get_env(:serviceradar_core, __MODULE__, [])

    %{limit: Keyword.get(app_config, :limit, @default_limit)}
  end

  @doc """
  The read/update pairs this worker drives, in the order it drives them.
  """
  @spec passes() :: [{atom(), atom()}]
  def passes, do: @passes

  @doc """
  Enqueues one silence sweep, outside the cron schedule.
  """
  @spec enqueue(keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(opts \\ []) do
    {support_opts, job_opts} = Keyword.split(opts, [:insert_fun, :available_fun])

    %{}
    |> new(job_opts)
    |> ObanSupport.safe_insert(support_opts)
  end

  @impl Oban.Worker
  def perform(%Oban.Job{} = job), do: sweep(job, [])

  @doc """
  `perform/1` with its collaborators injected.

  Options:

    * `:now` - the sweep instant, captured once and used for both passes so the
      two halves cannot disagree about what time it is.
    * `:actor` - defaults to a system actor.
    * `:limit` - rows per pass.
    * `:reader` - `fun.(read_action, now, opts)` returning `{:ok, [record]}` or
      `{:error, reason}`.
    * `:writer` - `fun.(record, update_action, opts)` returning `{:ok, record}`
      or `{:error, reason}`.

  The reader/writer seams exist so the ordering and the failure isolation can be
  asserted without a database; the defaults are ordinary Ash calls.
  """
  @spec sweep(Oban.Job.t(), keyword()) :: :ok
  def sweep(%Oban.Job{}, opts) when is_list(opts) do
    now = fetch_now(opts)
    actor = fetch_actor(opts)
    limit = Keyword.get(opts, :limit, config().limit)
    reader = Keyword.get(opts, :reader, &read_due/3)
    writer = Keyword.get(opts, :writer, &transition/3)
    call_opts = [actor: actor, limit: limit]

    Enum.each(@passes, fn {read_action, update_action} ->
      run_pass(reader, writer, read_action, update_action, now, call_opts)
    end)

    :ok
  end

  defp run_pass(reader, writer, read_action, update_action, now, opts) do
    case reader.(read_action, now, opts) do
      {:ok, []} ->
        :ok

      {:ok, silences} ->
        transitioned =
          Enum.count(
            silences,
            &transitioned?(writer.(&1, update_action, opts), &1, update_action)
          )

        Logger.info("notification silence sweep transitioned silences",
          action: update_action,
          due: length(silences),
          transitioned: transitioned
        )

      {:error, reason} ->
        Logger.error("notification silence sweep could not read due silences",
          action: read_action,
          reason: inspect(reason)
        )
    end
  end

  defp transitioned?({:ok, _updated}, _silence, _action), do: true

  defp transitioned?({:error, reason}, silence, action) do
    Logger.warning("notification silence could not be transitioned",
      silence_id: Map.get(silence, :id),
      action: action,
      reason: inspect(reason)
    )

    false
  end

  defp read_due(read_action, now, opts) do
    NotificationSilence
    |> Ash.Query.for_read(read_action, %{at: now})
    |> Ash.Query.limit(Keyword.fetch!(opts, :limit))
    |> Ash.read(actor: Keyword.fetch!(opts, :actor))
  end

  defp transition(silence, update_action, opts) do
    actor = Keyword.fetch!(opts, :actor)

    silence
    |> Ash.Changeset.for_update(update_action, %{}, actor: actor)
    |> Ash.update(actor: actor)
  end

  defp fetch_now(opts) do
    case Keyword.get(opts, :now) do
      %DateTime{} = now -> now
      _none -> DateTime.utc_now()
    end
  end

  defp fetch_actor(opts) do
    Keyword.get(opts, :actor) || SystemActor.system(:notification_silence_sweeper)
  end
end
