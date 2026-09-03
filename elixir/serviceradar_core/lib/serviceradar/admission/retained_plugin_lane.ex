defmodule ServiceRadar.Admission.RetainedPluginLane do
  @moduledoc "Bounded, commit-confirmed capability-retained plugin-result admission."

  alias ServiceRadar.Admission.Lane

  @default_config [
    max_items: 32,
    max_bytes: 64 * 1_024 * 1_024,
    max_items_per_agent: 8,
    queue_wait_ms: 2_000,
    worker_timeout_ms: 20_000,
    gateway_call_timeout_ms: 30_000
  ]
  @fixed_option_keys [
    :config,
    :lane,
    :concurrency,
    :processor,
    :on_accepted_result,
    :lease_supervisor,
    :source_max_bytes,
    :gateway_max_ms
  ]

  def start_link(opts \\ []) do
    config =
      @default_config |> Keyword.merge(configured_limits()) |> Keyword.merge(opts[:config] || [])

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
          task_supervisor: ServiceRadar.Admission.RetainedPluginTaskSupervisor,
          lease_supervisor: lease_supervisor,
          processor: {ServiceRadar.ResultsRouter, :process_retained_plugin, []},
          source_max_bytes: 16 * 1_024 * 1_024,
          gateway_max_ms: 30_000,
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

  defp server do
    :serviceradar_core
    |> Application.get_env(ServiceRadar.StatusHandler, [])
    |> Keyword.get(:retained_plugin_lane, __MODULE__)
  end

  defp configured_limits, do: Application.get_env(:serviceradar_core, __MODULE__, [])
end
