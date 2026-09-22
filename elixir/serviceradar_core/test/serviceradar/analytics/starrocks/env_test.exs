defmodule ServiceRadar.Analytics.StarRocks.EnvTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Analytics.StarRocks.Env

  @moduletag :db_free

  @var "SERVICERADAR_STARROCKS_ROLLUP_STALE_AFTER_SECONDS"
  @ttl_var "SERVICERADAR_STARROCKS_ROLLUP_CACHE_TTL_SECONDS"

  setup do
    previous = Map.new([@var, @ttl_var], &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
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

  # 0 disables mark reuse so every query probes the warehouse. Reading it as
  # "unset" would hand the operator the default 60s window instead, which is
  # the opposite of what they asked for.
  test "a zero rollup cache ttl is honoured literally" do
    System.put_env(@ttl_var, "0")
    assert Env.config()[:rollup_cache_ttl_seconds] == 0
  end

  test "a positive rollup cache ttl is taken as given" do
    System.put_env(@ttl_var, "15")
    assert Env.config()[:rollup_cache_ttl_seconds] == 15
  end

  test "an absent or unparseable rollup cache ttl falls back to the shipped default" do
    System.delete_env(@ttl_var)
    assert Env.config()[:rollup_cache_ttl_seconds] == Env.default_rollup_cache_ttl_seconds()

    System.put_env(@ttl_var, "soon")
    assert Env.config()[:rollup_cache_ttl_seconds] == Env.default_rollup_cache_ttl_seconds()

    System.put_env(@ttl_var, "-5")
    assert Env.config()[:rollup_cache_ttl_seconds] == Env.default_rollup_cache_ttl_seconds()
  end
end
