defmodule ServiceRadar.Analytics.StarRocks.EnvTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Analytics.StarRocks.Env

  @moduletag :db_free

  @var "SERVICERADAR_STARROCKS_ROLLUP_STALE_AFTER_SECONDS"

  setup do
    previous = System.get_env(@var)

    on_exit(fn ->
      if previous, do: System.put_env(@var, previous), else: System.delete_env(@var)
    end)

    :ok
  end

  # 0 is the strictest setting this knob has -- serve only a view that is fully
  # current -- so reading it as "unset" would hand the operator the loosest
  # tolerance instead, silently inverting what they asked for.
  test "a zero rollup staleness threshold is honoured literally" do
    System.put_env(@var, "0")
    assert Env.config()[:rollup_stale_after_seconds] == 0
  end

  test "a positive rollup staleness threshold is taken as given" do
    System.put_env(@var, "3600")
    assert Env.config()[:rollup_stale_after_seconds] == 3600
  end

  test "an absent or unparseable threshold falls back to the shipped default" do
    System.delete_env(@var)
    assert Env.config()[:rollup_stale_after_seconds] == Env.default_rollup_stale_after_seconds()

    System.put_env(@var, "later")
    assert Env.config()[:rollup_stale_after_seconds] == Env.default_rollup_stale_after_seconds()

    System.put_env(@var, "-60")
    assert Env.config()[:rollup_stale_after_seconds] == Env.default_rollup_stale_after_seconds()
  end
end
