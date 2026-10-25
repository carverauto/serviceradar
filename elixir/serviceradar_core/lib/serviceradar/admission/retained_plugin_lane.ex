defmodule ServiceRadar.Admission.RetainedPluginLane do
  @moduledoc "Bounded, commit-confirmed capability-retained plugin-result admission."

  alias ServiceRadar.Admission.Lane

  @default_config [
    max_items: 32,
    max_bytes: 64 * 1_024 * 1_024,
    max_items_per_agent: 8,
    queue_wait_ms: 2_000,
    worker_timeout_ms: 10_000,
    gateway_call_timeout_ms: 15_000
  ]
  @fixed_option_keys [
    :config,
    :lane,
    :concurrency,
    :ordering,
    :processor,
    :on_accepted_result,
    :on_execution_timeout,
    :lease_supervisor,
    :source_max_bytes,
    :gateway_max_ms
  ]

  def limits do
    @default_config
    |> Keyword.merge(configured_limits())
    |> Lane.with_per_agent_bytes(16 * 1_024 * 1_024)
  end

  def start_link(opts \\ []) do
    config =
      limits()
      |> Keyword.merge(opts[:config] || [])
      |> Lane.with_per_agent_bytes(16 * 1_024 * 1_024)

    lease_supervisor =
      Keyword.get_lazy(opts, :lease_supervisor, fn ->
        if Keyword.has_key?(opts, :task_supervisor) do
          opts[:task_supervisor]
        else
          ServiceRadar.Admission.RetainedPluginLeaseSupervisor
        end
      end)

    Lane.start_link(
      Keyword.merge(
        [
          name: __MODULE__,
          lane: :retained_plugin_result,
          concurrency: 2,
          # The gateway forwards a retained stream two chunks at a time, all from
          # one agent. Per-agent ordering would queue the second chunk for the
          # first one's whole run, and the queue wait is far shorter than the
          # worker budget, so it would expire whenever the first chunk runs long.
          # The plugin-result ingestor takes its own identity locks and picks the
          # current-state winner by observation time; it needs no arrival order.
          ordering: :unordered,
          task_supervisor: ServiceRadar.Admission.RetainedPluginTaskSupervisor,
          lease_supervisor: lease_supervisor,
          processor: {ServiceRadar.ResultsRouter, :process_retained_plugin, []},
          on_execution_timeout:
            {ServiceRadar.Observability.PluginResultQuarantine, :record_execution_timeout, []},
          source_max_bytes: 16 * 1_024 * 1_024,
          gateway_max_ms: 15_000,
          config: config
        ],
        Keyword.drop(opts, @fixed_option_keys)
      )
    )
  end

  def child_spec(opts),
    do: %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}

  def admit(status, reply_to), do: Lane.admit(server(), status, reply_to)
  def admit_cast(status), do: Lane.admit_cast(server(), status, :retained_plugin_result)

  def server do
    :serviceradar_core
    |> Application.get_env(ServiceRadar.StatusHandler, [])
    |> Keyword.get(:retained_plugin_lane, __MODULE__)
  end

  defp configured_limits, do: Application.get_env(:serviceradar_core, __MODULE__, [])
end
