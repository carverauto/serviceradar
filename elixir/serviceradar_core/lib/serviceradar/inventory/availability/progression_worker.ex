defmodule ServiceRadar.Inventory.Availability.ProgressionWorker do
  @moduledoc """
  Moves the deployment through the availability modes by itself (design Decision 10,
  "Automatic progression"), so no operator has to switch them. Scheduled every minute,
  and enqueued at once when the mode control changes (`ModeControl.set/2`).

  Each run reads the mode and the control (`ModeControl`: the pin when core runs with
  one, the stored control otherwise), records the pin on the settings row for the
  settings UI, and takes at most one step (`step/3`):

    * `auto`: `legacy` enters `shadow`; `shadow` cuts over once every readiness
      condition holds (`ServiceRadar.Inventory.Availability.Readiness`); a `cutover`
      whose reconciliation job is gone has it enqueued again.
    * `hold_legacy`: any other mode rolls back to `legacy`, which restores
      `is_available` from the compatibility table when leaving `cutover` or
      `authoritative`.
    * `hold_shadow`: `legacy` enters `shadow`; `cutover` and `authoritative` roll back to
      `legacy` first, and enter `shadow` on a later run, once the restore has finished.
    * Under `auto` and `hold_shadow`, a `shadow` with no full shadow resolution since the
      entry, and none waiting, has one enqueued (an install upgraded while in `shadow`
      has none recorded).
    * An invalid pin holds every mode where it is.

  A step is the same switch an operator makes (`Mode.enter_shadow/1`,
  `Mode.enter_cutover/1`, `Mode.enter_legacy/1`), so the cutover drains the writers,
  seeds the compatibility table and leaves the reconciliation and its single summary
  event to `CutoverWorker`. Entering `shadow` is never attempted while a restore is
  outstanding, or while the compatibility snapshot still differs from `is_available`
  (`{:error, :restore_pending}`). When the snapshot differs and no restore is waiting,
  the run enqueues the restore again. `hold_legacy` in `legacy` takes no step and does
  not read the snapshot.

  In `shadow` the run also stores the readiness evaluation on the settings row. When the
  control is `auto` and the conditions are still unmet 24 hours after entering `shadow`,
  it records the core health check `availability_cutover_readiness` unhealthy, naming
  the unmet conditions. The first run that finds the deployment no longer stalled
  (ready, held, rolled back, cut over, or in a younger shadow period) records it
  healthy again, and only when that check is already unhealthy.

  Several core nodes may run this at once. Each switch takes the mode-switch lock and
  re-reads the mode and the control under it: a step decided from a stale mode is a
  repeat the switch absorbs (a second `legacy` or `cutover` entry changes nothing), and
  a step decided from a control someone has since changed is refused
  (`{:error, :control_changed}`), so the progression never overrides a hold.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 55, states: [:available, :scheduled]]

  alias ServiceRadar.Infrastructure.HealthTracker
  alias ServiceRadar.Inventory.Availability.CutoverWorker
  alias ServiceRadar.Inventory.Availability.Mode
  alias ServiceRadar.Inventory.Availability.ModeControl
  alias ServiceRadar.Inventory.Availability.Readiness
  alias ServiceRadar.Inventory.Availability.ShadowEntryWorker
  alias ServiceRadar.Observability.TripwireHealth
  alias ServiceRadar.Repo

  require Logger

  @health_check "availability_cutover_readiness"
  @stall_seconds 24 * 3_600

  @modes %{
    "legacy" => :legacy,
    "shadow" => :shadow,
    "cutover" => :cutover,
    "authoritative" => :authoritative
  }

  # A missing settings row reads as `legacy` under `auto`; the first switch creates it.
  @settings """
  SELECT COALESCE(s.mode, 'legacy'), COALESCE(s.mode_control, 'auto'), s.mode_control_pin,
         s.shadow_entered_at, s.shadow_resolved_at, now() AT TIME ZONE 'utc'
  FROM (SELECT true AS singleton) AS one
  LEFT JOIN platform.availability_settings AS s ON s.singleton = one.singleton
  """

  @record_pin """
  UPDATE platform.availability_settings SET mode_control_pin = $1
  WHERE singleton AND mode_control_pin IS DISTINCT FROM $1
  """

  @record_readiness """
  UPDATE platform.availability_settings
  SET readiness = $1, readiness_checked_at = now() AT TIME ZONE 'utc'
  WHERE singleton AND mode = 'shadow'
  """

  @type step ::
          :none
          | :enter_shadow
          | :enter_cutover
          | :resume_cutover
          | :enter_legacy
          | :resolve
          | :restore

  @doc """
  Enqueues a run now. A job already `available` or `scheduled` in the unique window
  counts as success: it has not taken its step and re-reads the control. Uses the
  running Oban instance when there is one, and the repo otherwise, so a release
  `eval` needs no Oban.
  """
  @spec enqueue() :: :ok
  def enqueue do
    changeset = new(%{})

    _job =
      if oban_running?() do
        Oban.insert!(changeset)
      else
        Repo.insert!(changeset, prefix: "platform", on_conflict: :nothing)
      end

    :ok
  end

  defp oban_running? do
    is_pid(Process.whereis(Oban.Registry)) and
      match?({_pid, _config}, Oban.Registry.lookup(Oban))
  end

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case run() do
      {:error, reason} -> {:error, reason}
      _result -> :ok
    end
  end

  @doc """
  One progression run. Returns the step taken and its result, `{:ok, :none}` when
  nothing was due, or `{:error, reason}` when a switch failed.
  """
  @spec run() :: {:ok, step()} | {:ok, step(), term()} | {:error, term()}
  def run do
    %{rows: [[mode, stored, recorded_pin, entered_at, resolved_at, now]]} =
      Repo.query!(@settings)

    pin = ModeControl.pin()
    record_pin(recorded_pin, pin)
    {control, guard} = effective(pin, stored)
    mode = Map.fetch!(@modes, mode)
    facts = facts(mode, control, entered_at, resolved_at)
    report_stall(mode, control, facts, entered_at, now)
    apply_step(step(mode, control, facts), guard, facts)
  end

  @doc """
  The step the progression takes from `mode` under `control`, given `facts`:

    * `:restore_pending` - a restore from an earlier rollback is waiting or running;
    * `:restore_incomplete` - the compatibility snapshot still differs from
      `is_available`, and no restore is waiting;
    * `:ready` - every readiness condition holds;
    * `:resolve_outstanding` - a full shadow resolution is waiting or running;
    * `:resolved` - one finished since entering `shadow`;
    * `:reconcile_outstanding` - the cutover reconciliation is waiting or running.
  """
  @spec step(Mode.t(), ModeControl.t() | :invalid, map()) :: step()
  def step(_mode, :invalid, _facts), do: :none
  def step(:legacy, :hold_legacy, _facts), do: :none

  def step(:legacy, _control, facts) do
    cond do
      facts[:restore_pending] -> :none
      facts[:restore_incomplete] -> :restore
      true -> :enter_shadow
    end
  end

  def step(:shadow, :hold_legacy, _facts), do: :enter_legacy

  def step(:shadow, control, facts) do
    cond do
      control == :auto and facts[:ready] -> :enter_cutover
      not facts[:resolved] and not facts[:resolve_outstanding] -> :resolve
      true -> :none
    end
  end

  def step(:cutover, :auto, facts),
    do: if(facts[:reconcile_outstanding], do: :none, else: :resume_cutover)

  def step(:authoritative, :auto, _facts), do: :none
  def step(mode, _hold, _facts) when mode in [:cutover, :authoritative], do: :enter_legacy

  # The pin wins and is fixed for this node, so a pinned step needs no control guard.
  defp effective(nil, stored) do
    {:ok, control} = ModeControl.parse(stored)
    {control, [control: control]}
  end

  defp effective(pin, _stored), do: {effective_control(pin), []}

  defp effective_control({:ok, control}), do: control
  defp effective_control({:invalid, _raw}), do: :invalid

  # `hold_legacy` stays put, so it does not scan the snapshot every minute.
  defp facts(:legacy, control, _entered_at, _resolved_at) when control in [:auto, :hold_shadow] do
    pending = CutoverWorker.outstanding?("restore")

    %{
      restore_pending: pending,
      restore_incomplete: not pending and CutoverWorker.restore_incomplete?()
    }
  end

  defp facts(:legacy, _control, _entered_at, _resolved_at), do: %{}

  defp facts(:shadow, _control, entered_at, resolved_at) do
    readiness = Readiness.evaluate(entered_at, resolved_at)
    Repo.query!(@record_readiness, [readiness])

    %{
      readiness: readiness,
      ready: readiness["ready"],
      resolved: get_in(readiness, ["conditions", "shadow_resolve", "met"]),
      resolve_outstanding: ShadowEntryWorker.outstanding?("resolve")
    }
  end

  defp facts(:cutover, _control, _entered_at, _resolved_at),
    do: %{reconcile_outstanding: CutoverWorker.outstanding?("reconcile")}

  defp facts(:authoritative, _control, _entered_at, _resolved_at), do: %{}

  defp record_pin(recorded, pin) do
    value = ModeControl.pin_value(pin)
    if recorded != value, do: Repo.query!(@record_pin, [value])
    log_invalid_pin(pin)
  end

  defp log_invalid_pin({:invalid, raw}) do
    Logger.error(
      "availability mode control pin is not auto, hold_legacy or hold_shadow; holding the mode",
      pin: raw
    )
  end

  defp log_invalid_pin(_pin), do: :ok

  defp apply_step(:none, _guard, _facts), do: {:ok, :none}

  defp apply_step(:resolve, _guard, _facts) do
    :ok = ShadowEntryWorker.enqueue()
    {:ok, :resolve}
  end

  defp apply_step(:restore, _guard, _facts) do
    :ok = CutoverWorker.enqueue("restore")
    {:ok, :restore}
  end

  defp apply_step(:enter_cutover, guard, facts) do
    Logger.info("availability progression: readiness conditions hold, cutting over",
      readiness: Jason.encode!(facts.readiness)
    )

    switch(:enter_cutover, Mode.enter_cutover(guard))
  end

  defp apply_step(:resume_cutover, guard, _facts),
    do: switch(:resume_cutover, Mode.enter_cutover(guard))

  defp apply_step(:enter_shadow, guard, _facts),
    do: switch(:enter_shadow, Mode.enter_shadow(guard))

  defp apply_step(:enter_legacy, guard, _facts),
    do: switch(:enter_legacy, Mode.enter_legacy(guard))

  defp switch(step, {:ok, switched}) do
    Logger.info("availability progression: #{step}", from: switched.from, to: switched.to)
    {:ok, step, switched}
  end

  defp switch(step, {:error, reason}) do
    if deferred?(reason) do
      Logger.info("availability progression: #{step} deferred", reason: inspect(reason))
      {:ok, :none}
    else
      Logger.warning("availability progression: #{step} failed", reason: inspect(reason))
      {:error, reason}
    end
  end

  # The next run decides again from what it then reads: the control or the mode changed
  # since this run read them, the lock stayed busy, or a restore is still running.
  defp deferred?({:unsupported_switch, _from, _to}), do: true
  defp deferred?(reason), do: reason in [:control_changed, :mode_switch_busy, :restore_pending]

  # The warning holds only while an `auto` shadow period at least 24 hours old is unmet.
  # Any other run (ready, held, rolled back, cut over, or a younger shadow period) clears
  # a warning an earlier run raised.
  defp report_stall(
         :shadow,
         :auto,
         %{readiness: %{"ready" => false, "unmet" => unmet}},
         entered_at,
         now
       )
       when not is_nil(entered_at) do
    if stalled?(entered_at, now) do
      # Only what changes with the verdict, so a steady stall records no new row.
      TripwireHealth.record(
        @health_check,
        false,
        %{
          "unmet" => unmet,
          "shadow_entered_at" => NaiveDateTime.to_iso8601(entered_at)
        },
        refresh_metadata: true
      )
    else
      clear_stall()
    end
  end

  defp report_stall(_mode, _control, _facts, _entered_at, _now), do: clear_stall()

  # A deployment that never stalled has no unhealthy check and gets no health row. Best
  # effort, like the recording itself: a health read failure never blocks the step.
  defp clear_stall do
    case HealthTracker.current_status(:core, @health_check) do
      {:ok, %{new_state: :unhealthy}} ->
        TripwireHealth.record(@health_check, true, %{"unmet" => []}, refresh_metadata: true)

      _other ->
        :ok
    end
  rescue
    error ->
      Logger.warning("availability progression: health check read failed",
        reason: inspect(error)
      )

      :ok
  end

  defp stalled?(%NaiveDateTime{} = entered_at, %NaiveDateTime{} = now),
    do: NaiveDateTime.diff(now, entered_at) >= @stall_seconds

  defp stalled?(_entered_at, _now), do: false
end
