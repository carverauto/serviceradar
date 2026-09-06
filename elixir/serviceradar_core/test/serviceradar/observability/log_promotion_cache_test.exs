defmodule ServiceRadar.Observability.LogPromotionCacheTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Observability.LogPromotion

  setup do
    original_ttl =
      Application.fetch_env(:serviceradar_core, :log_promotion_rule_cache_ttl_ms)

    LogPromotion.invalidate_rules_cache()

    on_exit(fn ->
      LogPromotion.invalidate_rules_cache()

      case original_ttl do
        {:ok, value} ->
          Application.put_env(:serviceradar_core, :log_promotion_rule_cache_ttl_ms, value)

        :error ->
          Application.delete_env(:serviceradar_core, :log_promotion_rule_cache_ttl_ms)
      end
    end)

    :ok
  end

  test "active_log_rules reuses cached rules until invalidated" do
    calls = :atomics.new(1, [])

    load_fun = fn ->
      call_count = :atomics.add_get(calls, 1, 1)
      {:ok, ["rule-#{call_count}"]}
    end

    assert {:ok, ["rule-1"]} = LogPromotion.active_log_rules(load_fun)
    assert {:ok, ["rule-1"]} = LogPromotion.active_log_rules(load_fun)
    assert 1 = :atomics.get(calls, 1)

    assert :ok = LogPromotion.invalidate_rules_cache()
    assert {:ok, ["rule-2"]} = LogPromotion.active_log_rules(load_fun)
    assert 2 = :atomics.get(calls, 1)
  end

  test "expired active_log_rules cache reloads rules" do
    Application.put_env(:serviceradar_core, :log_promotion_rule_cache_ttl_ms, 0)
    calls = :atomics.new(1, [])

    load_fun = fn ->
      call_count = :atomics.add_get(calls, 1, 1)
      {:ok, ["rule-#{call_count}"]}
    end

    assert {:ok, ["rule-1"]} = LogPromotion.active_log_rules(load_fun)
    assert {:ok, ["rule-2"]} = LogPromotion.active_log_rules(load_fun)
    assert 2 = :atomics.get(calls, 1)
  end

  test "failed rule loads are returned and retried instead of cached" do
    calls = :atomics.new(1, [])

    reader = fn ->
      case :atomics.add_get(calls, 1, 1) do
        1 -> {:error, :query_unavailable}
        _ -> {:ok, []}
      end
    end

    assert {:error, :query_unavailable} = LogPromotion.active_log_rules(reader)
    assert {:ok, []} = LogPromotion.active_log_rules(reader)
    assert {:ok, []} = LogPromotion.active_log_rules(reader)
    assert 2 == :atomics.get(calls, 1)
  end

  test "an expired successful cache does not conceal refresh errors" do
    Application.put_env(:serviceradar_core, :log_promotion_rule_cache_ttl_ms, 0)
    assert {:ok, ["rule"]} = LogPromotion.active_log_rules(fn -> {:ok, ["rule"]} end)

    assert {:error, :query_unavailable} =
             LogPromotion.active_log_rules(fn -> {:error, :query_unavailable} end)

    assert {:ok, ["recovered-rule"]} =
             LogPromotion.active_log_rules(fn -> {:ok, ["recovered-rule"]} end)
  end
end
