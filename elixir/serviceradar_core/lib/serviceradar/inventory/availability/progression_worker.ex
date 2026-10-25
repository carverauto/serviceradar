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
  outstanding (`{:error, :restore_pending}`).

  In `shadow` the run also stores the readiness evaluation on the settings row. When the
  control is `auto` and the conditions are still unmet 24 hours after entering `shadow`,
  it records the core health check `availability_cutover_readiness` unhealthy, naming
  the unmet conditions; the cutover clears it.

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
          :none | :enter_shadow | :enter_cutover | :resume_cutover | :enter_legacy | :resolve

  @doc "Enqueues a run now, through the repo; needs no running Oban instance."
  @spec enqueue() :: :ok
  def enqueue do
    Repo.insert!(new(%{}), prefix: "platform")
    :ok
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
    facts = facts(mode, entered_at, resolved_at)
    report_stall(mode, control, facts, entered_at, now)
    apply_step(step(mode, control, facts), guard, facts, entered_at, now)
  end

  @doc """
  The step the progression takes from `mode` under `control`, given `facts`:

    * `:restore_pending` - a restore from an earlier rollback has not finished;
    * `:ready` - every readiness condition holds;
    * `:resolve_outstanding` - a full shadow resolution is waiting or running;
    * `:resolved` - one finished since entering `shadow`;
    * `:reconcile_outstanding` - the cutover reconciliation is waiting or running.
  """
  @spec step(Mode.t(), ModeControl.t() | :invalid, map()) :: step()
  def step(_mode, :invalid, _facts), do: :none
  def step(:legacy, :hold_legacy, _facts), do: :none

  def step(:legacy, _control, facts),
    do: if(facts[:restore_pending], do: :none, else: :enter_shadow)

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

  defp facts(:legacy, _entered_at, _resolved_at),
    do: %{restore_pending: CutoverWorker.outstanding?("restore")}

  defp facts(:shadow, entered_at, resolved_at) do
    readiness = Readiness.evaluate(entered_at, resolved_at)
    Repo.query!(@record_readiness, [readiness])

    %{
      readiness: readiness,
      ready: readiness["ready"],
      resolved: get_in(readiness, ["conditions", "shadow_resolve", "met"]),
      resolve_outstanding: ShadowEntryWorker.outstanding?("resolve")
    }
  end

  defp facts(:cutover, _entered_at, _resolved_at),
    do: %{reconcile_outstanding: CutoverWorker.outstanding?("reconcile")}

  defp facts(:authoritative, _entered_at, _resolved_at), do: %{}

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

  defp apply_step(:none, _guard, _facts, _entered_at, _now), do: {:ok, :none}

  defp apply_step(:resolve, _guard, _facts, _entered_at, _now) do
    :ok = ShadowEntryWorker.enqueue()
    {:ok, :resolve}
  end

  defp apply_step(:enter_cutover, guard, facts, entered_at, now) do
    with {:ok, switched} <- switch(:enter_cutover, Mode.enter_cutover(guard)) do
      if stalled?(entered_at, now) do
        TripwireHealth.record(@health_check, true, %{"unmet" => []}, refresh_metadata: true)
      end

      Logger.info("availability progression: readiness conditions hold, cutting over",
        readiness: Jason.encode!(facts.readiness)
      )

      {:ok, :enter_cutover, switched}
    end
  end

  defp apply_step(:resume_cutover, guard, _facts, _entered_at, _now),
    do: switch(:resume_cutover, Mode.enter_cutover(guard))

  defp apply_step(:enter_shadow, guard, _facts, _entered_at, _now),
    do: switch(:enter_shadow, Mode.enter_shadow(guard))

  defp apply_step(:enter_legacy, guard, _facts, _entered_at, _now),
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

  defp report_stall(:shadow, :auto, %{readiness: readiness}, entered_at, now) do
    if not readiness["ready"] and stalled?(entered_at, now) do
      TripwireHealth.record(
        @health_check,
        false,
        # Only what changes with the verdict, so a steady stall records no new row.
        %{
          "unmet" => readiness["unmet"],
          "shadow_entered_at" => NaiveDateTime.to_iso8601(entered_at)
        },
        refresh_metadata: true
      )
    end

    :ok
  end

  defp report_stall(_mode, _control, _facts, _entered_at, _now), do: :ok

  defp stalled?(%NaiveDateTime{} = entered_at, %NaiveDateTime{} = now),
    do: NaiveDateTime.diff(now, entered_at) >= @stall_seconds

  defp stalled?(_entered_at, _now), do: false
end
