defmodule ServiceRadar.Inventory.Availability.Operator do
  @moduledoc """
  Operator entry points for the merged availability rollout, usable from a running
  release, a release `eval`, or the `mix serviceradar.availability.*` tasks. Each starts
  the repo when nothing has (`eval`) and reuses it when the application runs (`rpc`).

      bin/serviceradar_core rpc 'ServiceRadar.Inventory.Availability.Operator.report()'
      bin/serviceradar_core rpc 'ServiceRadar.Inventory.Availability.Operator.switch("shadow")'
      bin/serviceradar_core rpc 'ServiceRadar.Inventory.Availability.Operator.switch("cutover")'
      bin/serviceradar_core rpc 'ServiceRadar.Inventory.Availability.Operator.status()'
      bin/serviceradar_core eval 'ServiceRadar.Inventory.Availability.Operator.report()'

  `report/1` prints the human summary, then the JSON report, and changes nothing.
  `switch/1` is the mode switch (`Mode.enter_shadow/0`, `Mode.enter_cutover/0` or
  `Mode.enter_legacy/0`, the rollback from any mode). `status/0` prints the mode, the
  transition-event setting and the cutover jobs still waiting. `transition_events/1`
  turns the resolver's `device.*` events on or off for the deployment.
  """

  alias ServiceRadar.Inventory.Availability.DivergenceReport
  alias ServiceRadar.Inventory.Availability.Mode
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

  @doc ~s(Switches the availability mode to `"shadow"`, `"cutover"` or `"legacy"` and prints the outcome.)
  @spec switch(String.t()) :: {:ok, map()} | {:error, term()}
  def switch(mode) do
    with_repo(fn ->
      result =
        case mode do
          "shadow" -> Mode.enter_shadow()
          "cutover" -> Mode.enter_cutover()
          "legacy" -> Mode.enter_legacy()
          other -> {:error, {:unsupported_mode, other}}
        end

      IO.puts("availability mode switch: #{inspect(result)}")
      result
    end)
  end

  @status """
  SELECT s.mode, s.transition_events, s.expiry_watermark,
         (SELECT count(*) FROM platform.availability_invalidations),
         (SELECT coalesce(jsonb_object_agg(j.args ->> 'phase', j.state), '{}'::jsonb)
          FROM platform.oban_jobs AS j
          WHERE j.worker = 'ServiceRadar.Inventory.Availability.CutoverWorker'
            AND j.state IN ('available', 'scheduled', 'executing', 'retryable'))
  FROM platform.availability_settings AS s
  WHERE s.singleton
  """

  @doc """
  Prints and returns the mode, the transition-event setting, the expiry watermark, the
  invalidation backlog and the cutover jobs not yet finished (by phase).
  """
  @spec status() :: map()
  def status do
    with_repo(fn ->
      [mode, events?, watermark, backlog, jobs] =
        case Repo.query!(@status) do
          %{rows: [row]} -> row
          %{rows: []} -> ["legacy", false, nil, 0, %{}]
        end

      status = %{
        mode: mode,
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
