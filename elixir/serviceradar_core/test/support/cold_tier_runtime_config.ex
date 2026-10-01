defmodule ServiceRadar.TestSupport.ColdTierRuntimeConfig do
  @moduledoc false

  @base_env %{
    "CLOAK_KEY" => Base.encode64(:binary.copy(<<7>>, 32)),
    "DATABASE_URL" => "ecto://fixture:synthetic@db.example.com/cold_runtime_test",
    "SERVICERADAR_ASH_OBAN_SCHEDULER_ENABLED" => "false",
    "SERVICERADAR_CORE_OBAN_ENABLED" => "true"
  }

  def read!(overrides, runtime \\ :release) do
    cold_env =
      System.get_env()
      |> Enum.filter(fn {name, _value} ->
        String.starts_with?(name, ["SERVICERADAR_COLD_", "SERVICERADAR_STARROCKS_"])
      end)
      |> Map.new(fn {name, _value} -> {name, nil} end)

    environment = cold_env |> Map.merge(@base_env) |> Map.merge(overrides)
    previous = Map.new(environment, fn {name, _value} -> {name, System.get_env(name)} end)

    try do
      Enum.each(environment, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      {path, env} =
        case runtime do
          :release -> {Path.expand("../serviceradar_core_elx/config/runtime.exs"), :prod}
          :core -> {Path.expand("config/runtime.exs"), :test}
        end

      Config.Reader.read!(path, env: env)[:serviceradar_core]
    after
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end
end
