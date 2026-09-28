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

  describe "stream load sizing" do
    @stream_vars Enum.map(
                   ~w(MAX_ROWS MAX_BYTES MAX_AGE_MS MAX_IN_FLIGHT),
                   &("SERVICERADAR_STARROCKS_STREAM_LOAD_" <> &1)
                 )

    setup do
      previous = Map.new(@stream_vars, &{&1, System.get_env(&1)})

      on_exit(fn ->
        Enum.each(previous, fn
          {name, nil} -> System.delete_env(name)
          {name, value} -> System.put_env(name, value)
        end)
      end)

      Enum.each(@stream_vars, &System.delete_env/1)
      :ok
    end

    test "defaults match the shipped Helm streamLoad values" do
      assert Env.config()[:stream_load] == [
               max_rows: 50_000,
               max_bytes: 33_554_432,
               max_age_ms: 2_000,
               max_in_flight: 4
             ]
    end

    # Helm's `quote` renders a large integer in scientific notation; the value
    # an operator set must still apply rather than silently reverting.
    test "operator values apply, including a scientific-notation byte limit" do
      System.put_env("SERVICERADAR_STARROCKS_STREAM_LOAD_MAX_ROWS", "200000")
      System.put_env("SERVICERADAR_STARROCKS_STREAM_LOAD_MAX_BYTES", "6.7108864e+07")
      System.put_env("SERVICERADAR_STARROCKS_STREAM_LOAD_MAX_AGE_MS", "5000")
      System.put_env("SERVICERADAR_STARROCKS_STREAM_LOAD_MAX_IN_FLIGHT", "0")

      assert Env.config()[:stream_load] == [
               max_rows: 200_000,
               max_bytes: 67_108_864,
               max_age_ms: 5_000,
               max_in_flight: 4
             ]
    end
  end
end
