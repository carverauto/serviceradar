defmodule ServiceRadar.AsyncSandboxConfigurationTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.DataCase
  alias ServiceRadar.Repo

  @moduletag :integration

  test "DataCase applies the transaction-local rollup bypass to allowed children" do
    assert %{rows: [["on"]]} =
             Repo.query!("SELECT current_setting('platform.skip_inventory_rollup', true)")

    parent = self()

    {child, child_ref} =
      spawn_monitor(fn ->
        receive do
          :read_setting ->
            result =
              Repo.query!("SELECT current_setting('platform.skip_inventory_rollup', true)")

            send(parent, {:child_setting, result})
        end
      end)

    assert :ok = DataCase.allow_sandbox(child)
    send(child, :read_setting)
    assert_receive {:child_setting, %{rows: [["on"]]}}, 1_000
    assert_receive {:DOWN, ^child_ref, :process, ^child, :normal}, 1_000
  end
end
