defmodule ServiceRadar.Admission.FlowLane do
  @moduledoc "Bounded, commit-confirmed flow-attribution admission."

  alias ServiceRadar.Admission.Lane

  @default_config [
    max_items: 16,
    max_bytes: 64 * 1_024 * 1_024,
    max_items_per_agent: 4,
    queue_wait_ms: 2_000,
    worker_timeout_ms: 20_000,
    gateway_call_timeout_ms: 25_000
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
          ServiceRadar.Admission.FlowLeaseSupervisor
        end
      end)

    Lane.start_link(
      Keyword.merge(
        [
          name: __MODULE__,
          lane: :flow_attribution,
          concurrency: 1,
          task_supervisor: ServiceRadar.Admission.FlowTaskSupervisor,
          lease_supervisor: lease_supervisor,
          processor: {ServiceRadar.StatusHandler, :process_flow_attribution, []},
          on_accepted_result: {ServiceRadar.StatusHandler, :emit_flow_attribution_committed, []},
          source_max_bytes: 6 * 1_024 * 1_024,
          gateway_max_ms: 25_000,
          config: config
        ],
        Keyword.drop(opts, @fixed_option_keys)
      )
    )
  end

  def child_spec(opts),
    do: %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}

  def admit(status, reply_to), do: Lane.admit(server(), status, reply_to)
  def admit_cast(status), do: Lane.admit_cast(server(), status, :flow_attribution)

  defp server do
    :serviceradar_core
    |> Application.get_env(ServiceRadar.StatusHandler, [])
    |> Keyword.get(:flow_lane, __MODULE__)
  end

  defp configured_limits, do: Application.get_env(:serviceradar_core, __MODULE__, [])
end
