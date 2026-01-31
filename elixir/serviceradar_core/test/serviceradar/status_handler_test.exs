defmodule ServiceRadar.StatusHandlerTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.StatusHandler

  setup do
    existing = Process.whereis(ServiceRadar.ResultsRouter)

    if is_pid(existing) do
      Process.unregister(ServiceRadar.ResultsRouter)
    end

    on_exit(fn ->
      if is_pid(existing) do
        Process.register(existing, ServiceRadar.ResultsRouter)
      else
        if Process.whereis(ServiceRadar.ResultsRouter) do
          Process.unregister(ServiceRadar.ResultsRouter)
        end
      end
    end)

    :ok
  end

  test "routes sync results through ResultsRouter when available" do
    parent = self()

    router_pid =
      spawn(fn ->
        receive do
          {:"$gen_cast", {:results_update, status}} ->
            send(parent, {:forwarded, status})
        end
      end)

    Process.register(router_pid, ServiceRadar.ResultsRouter)

    status = %{
      source: "results",
      service_type: "sync",
      message: Jason.encode!([%{"device_id" => "dev-1"}])
    }

    assert {:noreply, %{}} = StatusHandler.handle_cast({:status_update, status}, %{})
    assert_receive {:forwarded, ^status}
  end
end
