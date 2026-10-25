defmodule ServiceRadar.Inventory.Availability.Operator do
  @moduledoc """
  Support entry points for merged availability, usable from a running release, a
  release `eval`, or the `mix serviceradar.availability.*` tasks. Each starts the repo
  when nothing has (`eval`) and reuses it when the application runs (`rpc`). None is
  needed to roll out merged availability: core progresses through the modes by itself
  (`ServiceRadar.Inventory.Availability.ProgressionWorker`).

      bin/serviceradar_core rpc 'ServiceRadar.Inventory.Availability.Operator.status()'
      bin/serviceradar_core rpc 'ServiceRadar.Inventory.Availability.Operator.report()'
      bin/serviceradar_core rpc 'ServiceRadar.Inventory.Availability.Operator.control("hold_legacy")'
      bin/serviceradar_core rpc 'ServiceRadar.Inventory.Availability.Operator.switch("cutover")'
      bin/serviceradar_core eval 'ServiceRadar.Inventory.Availability.Operator.report()'

  `report/1` prints the human summary, then the JSON report, and changes nothing.
  `control/1` sets the deployment's mode control, as the settings UI does. `switch/1`
  switches the mode now (`Mode.enter_shadow/1`, `Mode.enter_cutover/1` or
  `Mode.enter_legacy/1`, the rollback from any mode) and sets the control that keeps it
  there, so the progression does not undo it: `"legacy"` sets `hold_legacy`,
  `"shadow"` sets `hold_shadow`, and `"cutover"` sets `auto`, cutting over without
  waiting for the readiness conditions. A refused `"cutover"` or `"legacy"` leaves the
  control unchanged. Both refuse while core runs with a pinned
  control. `status/0` prints the mode, the control, the last readiness evaluation, the
  transition-event setting and the cutover jobs not yet finished. `transition_events/1`
  turns the resolver's `device.*` events on or off for the deployment.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Availability.DivergenceReport
  alias ServiceRadar.Inventory.Availability.Mode
  alias ServiceRadar.Inventory.Availability.ModeControl
  alias ServiceRadar.Repo

  @doc "Prints the divergence report (summary, then JSON) and returns it."
  @spec report(keyword()) :: map()
  def report(opts \\ []) do
    with_repo(fn ->
      report = DivergenceReport.build(opts)
      IO.puts(DivergenceReport.summary_text(report))
      IO.puts(Jason.encode!(report, pretty: true))
      report
    end)
  end

  @doc """
  Switches the availability mode to `"shadow"`, `"cutover"` or `"legacy"`, sets the
  control that keeps it, and prints the outcome. `"cutover"` (control `auto`) and
  `"legacy"` (control `hold_legacy`) set the control in the switch's own transaction,
  only when the switch succeeds, so a refused switch leaves the control as it was.
  `"shadow"` sets `hold_shadow` first: from `cutover` or `authoritative` the switch is
  refused and the progression then rolls back and re-enters `shadow` under that control.
  """
  @spec switch(String.t()) :: {:ok, map()} | {:error, term()}
  def switch(mode) do
    with_repo(fn ->
      result =
        case mode do
          "shadow" ->
            with {:ok, _setting} <- set_control(:hold_shadow),
                 do: Mode.enter_shadow(control: :hold_shadow)

          "cutover" ->
            with :ok <- unpinned(), do: Mode.enter_cutover(set_control: :auto)

          "legacy" ->
            with :ok <- unpinned(), do: Mode.enter_legacy(set_control: :hold_legacy)

          other ->
            {:error, {:unsupported_mode, other}}
        end

      IO.puts("availability mode switch: #{inspect(result)}")
      result
    end)
  end

  @doc ~s(Sets the mode control to `"auto"`, `"hold_legacy"` or `"hold_shadow"` and prints the outcome.)
  @spec control(String.t()) :: {:ok, map()} | {:error, term()}
  def control(control) do
    with_repo(fn ->
      result =
        case set_control(control) do
          {:ok, setting} -> {:ok, %{mode_control: setting.mode_control}}
          {:error, reason} -> {:error, reason}
        end

      IO.puts("availability mode control: #{inspect(result)}")
      result
    end)
  end

  defp set_control(control) do
    with :ok <- unpinned(),
         do: ModeControl.set(control, actor: SystemActor.system(:availability_operator))
  end

  # The pin is this node's configuration, which the settings row may not show yet.
  defp unpinned do
    case ModeControl.pin() do
      nil -> :ok
      pin -> {:error, {:mode_control_pinned, ModeControl.pin_value(pin)}}
    end
  end

  @status """
  SELECT s.mode, s.mode_control, s.mode_control_pin, s.shadow_entered_at, s.readiness,
         s.readiness_checked_at, s.transition_events, s.expiry_watermark,
         (SELECT count(*) FROM platform.availability_invalidations),
         (SELECT coalesce(jsonb_object_agg(j.args ->> 'phase', j.state), '{}'::jsonb)
          FROM platform.oban_jobs AS j
          WHERE j.worker = 'ServiceRadar.Inventory.Availability.CutoverWorker'
            AND j.state IN ('available', 'scheduled', 'executing', 'retryable'))
  FROM platform.availability_settings AS s
  WHERE s.singleton
  """

  @doc """
  Prints and returns the mode, the mode control (the stored value, and the pin core
  runs with), when the deployment entered `shadow`, the last readiness evaluation, the
  transition-event setting, the expiry watermark, the invalidation backlog and the
  cutover jobs not yet finished (by phase).
  """
  @spec status() :: map()
  def status do
    with_repo(fn ->
      [
        mode,
        control,
        recorded_pin,
        entered_at,
        readiness,
        checked_at,
        events?,
        watermark,
        backlog,
        jobs
      ] =
        case Repo.query!(@status) do
          %{rows: [row]} -> row
          %{rows: []} -> ["legacy", "auto", nil, nil, nil, nil, false, nil, 0, %{}]
        end

      status = %{
        mode: mode,
        mode_control: control,
        mode_control_pin: ModeControl.pin_value(ModeControl.pin()) || recorded_pin,
        shadow_entered_at: entered_at,
        readiness: readiness,
        readiness_checked_at: checked_at,
        transition_events: events?,
        expiry_watermark: watermark,
        invalidation_backlog: backlog,
        cutover_jobs: jobs
      }

      IO.puts("availability status: #{inspect(status)}")
      status
    end)
  end

  @doc "Turns the resolver's `device.available` / `device.unavailable` events on or off."
  @spec transition_events(boolean()) :: :ok
  def transition_events(enabled?) when is_boolean(enabled?) do
    with_repo(fn ->
      Repo.query!(
        "UPDATE platform.availability_settings SET transition_events = $1 WHERE singleton",
        [enabled?]
      )

      IO.puts("availability transition events: #{enabled?}")
      :ok
    end)
  end

  defp with_repo(fun) do
    {:ok, result, _started} = Ecto.Migrator.with_repo(Repo, fn _repo -> fun.() end)
    result
  end
end
