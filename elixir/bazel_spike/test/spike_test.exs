# ex_unit_test runs `elixir -r <srcs>` with no test_helper.exs, so the suite has to start
# ExUnit itself. Mix normally does this in test/test_helper.exs.
ExUnit.start(autorun: false)

defmodule SpikeTest do
  use ExUnit.Case, async: true

  test "the app compiled by elixir_app is callable from a Bazel-native ExUnit target" do
    assert SpikePlain.hello() == :world
  end
end

ExUnit.run()
