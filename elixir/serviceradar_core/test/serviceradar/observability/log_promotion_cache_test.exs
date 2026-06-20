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
      ["rule-#{call_count}"]
    end

    assert ["rule-1"] = LogPromotion.active_log_rules(load_fun)
    assert ["rule-1"] = LogPromotion.active_log_rules(load_fun)
    assert 1 = :atomics.get(calls, 1)

    assert :ok = LogPromotion.invalidate_rules_cache()
    assert ["rule-2"] = LogPromotion.active_log_rules(load_fun)
    assert 2 = :atomics.get(calls, 1)
  end

  test "expired active_log_rules cache reloads rules" do
    Application.put_env(:serviceradar_core, :log_promotion_rule_cache_ttl_ms, 0)
    calls = :atomics.new(1, [])

    load_fun = fn ->
      call_count = :atomics.add_get(calls, 1, 1)
      ["rule-#{call_count}"]
    end

    assert ["rule-1"] = LogPromotion.active_log_rules(load_fun)
    assert ["rule-2"] = LogPromotion.active_log_rules(load_fun)
    assert 2 = :atomics.get(calls, 1)
  end
end
