defmodule ServiceRadarAgentGateway.RuntimeMetricsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.NATS.Connection
  alias ServiceRadarAgentGateway.Config
  alias ServiceRadarAgentGateway.RuntimeMetrics
  alias ServiceRadarAgentGateway.StatusHandlerTestHelpers

  defmodule SlowAckNatsStub do
    @moduledoc false
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl true
    def init(opts) do
      {:ok,
       %{
         test_pid: Keyword.fetch!(opts, :test_pid),
         ack_delay_ms: Keyword.fetch!(opts, :ack_delay_ms),
         next_id: 1,
         request_receivers: %{}
       }}
    end

    @impl true
    def handle_call({:request, req}, _from, state) do
      inbox = "_INBOX.runtime_metrics_test.#{state.next_id}"
      Process.send_after(self(), {:deliver_ack, inbox}, state.ack_delay_ms)

      next_state = %{
        state
        | next_id: state.next_id + 1,
          request_receivers: Map.put(state.request_receivers, inbox, req.recipient)
      }

      {:reply, {:ok, inbox}, next_state}
    end

    def handle_call({:unsub, inbox, _opts}, _from, state) when is_binary(inbox) do
      {:reply, :ok, %{state | request_receivers: Map.delete(state.request_receivers, inbox)}}
    end

    @impl true
    def handle_info({:deliver_ack, inbox}, state) do
      case Map.fetch(state.request_receivers, inbox) do
        {:ok, recipient} ->
          send(
            recipient,
            {:msg, %{topic: inbox, body: ~s({"stream":"METRICS","seq":1}), gnat: self()}}
          )

          send(state.test_pid, {:ack_delivered, inbox})

        :error ->
          send(state.test_pid, {:late_reply_for_unregistered_request, inbox})
      end

      {:noreply, state}
    end
  end

  setup do
    previous_config =
      try do
        {:ok, Config.get()}
      rescue
        ArgumentError -> :missing
      end

    Config.setup(gateway_id: "gateway-test", domain: "test", capabilities: [])

    previous_publish = Application.get_env(:serviceradar_agent_gateway, :runtime_metrics_publish)
    Application.delete_env(:serviceradar_agent_gateway, :runtime_metrics_publish)

    existing_nats = Process.whereis(Connection.connection_name())

    if is_pid(existing_nats) do
      StatusHandlerTestHelpers.unregister_quietly(Connection.connection_name())
    end

    on_exit(fn ->
      restore_config(previous_config)
      restore_env(:runtime_metrics_publish, previous_publish)
      StatusHandlerTestHelpers.restore(Connection.connection_name(), existing_nats)
    end)

    :ok
  end

  test "tolerates a JetStream PubAck slower than 1s without timing out or leaving a late reply" do
    if !Process.whereis(RuntimeMetrics) do
      start_supervised!(RuntimeMetrics)
    end

    _ = :sys.get_state(RuntimeMetrics)

    {:ok, nats} = start_supervised({SlowAckNatsStub, test_pid: self(), ack_delay_ms: 1_200})
    Process.register(nats, Connection.connection_name())

    {verdict, log} =
      with_log(fn ->
        assert :ok = RuntimeMetrics.report_core_call(12, :ok, %{source: "status"})

        result =
          receive do
            {:ack_delivered, inbox} ->
              {:ack_delivered, inbox}

            {:late_reply_for_unregistered_request, inbox} ->
              {:late_reply_for_unregistered_request, inbox}
          after
            3_000 ->
              :timeout_waiting_for_ack
          end

        _ = :sys.get_state(RuntimeMetrics)
        result
      end)

    assert {:ack_delivered, _inbox} = verdict
    refute log =~ "Gateway runtime metric publish failed"
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_agent_gateway, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_agent_gateway, key, value)

  defp restore_config({:ok, config}) do
    Config.setup(
      gateway_id: config.gateway_id,
      domain: config.domain,
      capabilities: config.capabilities
    )
  end

  defp restore_config(:missing), do: :persistent_term.erase(Config)
end
