defmodule ServiceRadar.NetworkDiscovery.WorldRuntimeConfigTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.NetworkDiscovery.WorldWorker

  @moduletag :db_free
  @runtime_config Path.expand("../../../../serviceradar_core_elx/config/runtime.exs", __DIR__)
  @external_resource @runtime_config

  test "the deployed core consumes the world worker queue with one native build at a time" do
    environment = %{
      "CLOAK_KEY" => Base.encode64(:binary.copy(<<7>>, 32)),
      "DATABASE_URL" => "ecto://user:pass@localhost/world_config_test",
      "SERVICERADAR_ASH_OBAN_SCHEDULER_ENABLED" => "false",
      "OBAN_QUEUE_MAINTENANCE" => "7"
    }

    previous = Map.new(environment, fn {key, _value} -> {key, System.get_env(key)} end)
    System.put_env(environment)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    config = Config.Reader.read!(@runtime_config, env: :prod)

    queues =
      Map.new(config[:serviceradar_core][Oban][:queues], fn {name, limit} ->
        {Atom.to_string(name), limit}
      end)

    job =
      Ecto.Changeset.apply_changes(
        WorldWorker.new(%{"mode" => "reconcile", "layout_version" => Ash.UUID.generate()})
      )

    assert queues[job.queue] == 1
    assert queues["maintenance"] == 7
  end
end
