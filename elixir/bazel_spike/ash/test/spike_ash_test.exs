ExUnit.start(autorun: false)

defmodule SpikeAshTest do
  use ExUnit.Case, async: true

  test "Ash's compile-time DSL expanded under elixir_bytecode" do
    # Ash.Resource.Info is populated by Spark at COMPILE time. If the DSL did not expand,
    # these calls raise or return nothing.
    names = SpikeAsh.Thing |> Ash.Resource.Info.attributes() |> Enum.map(& &1.name)
    assert :id in names
    assert :name in names
  end
end

ExUnit.run()
