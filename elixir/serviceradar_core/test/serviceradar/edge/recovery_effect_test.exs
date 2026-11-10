defmodule ServiceRadar.Edge.RecoveryEffectTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.RecoveryEffect

  test "only resolved active attribution asserts a produced range and requests work" do
    for lookup <- [
          {:found, %{"kind" => "positive"}},
          {:not_scheduled, %{"kind" => "explicit_negative"}}
        ] do
      assert {:ok, active} = RecoveryEffect.classify(:attributed_active, lookup)
      assert active.state == :applied
      assert active.range? and active.retry?
      refute active.fence?
      assert {:ok, passive} = RecoveryEffect.classify(:attributed_passive, lookup)
      assert passive.state == :applied
      refute passive.range? or passive.retry? or passive.fence?
    end
  end

  test "unresolved mapping outcomes cannot complete and unattributable loss requires a generation fence" do
    for kind <- [:attributed_active, :attributed_passive],
        {lookup, state, fence?} <- [
          {:temporarily_unavailable, :pending, false},
          {:missing, :blocked, true},
          {:corrupt, :blocked, false},
          {:conflicting, :blocked, false}
        ] do
      assert {:ok, effect} = RecoveryEffect.classify(kind, lookup)
      assert effect.state == state
      assert effect.fence? == fence?
      refute effect.range? or effect.retry?
    end

    assert {:ok, unknown} = RecoveryEffect.classify(:unattributable, :not_looked_up)
    assert unknown.state == :applied
    assert unknown.fence? and unknown.retry?
    refute unknown.range?

    assert {:error, :mapping_lookup_contract} =
             RecoveryEffect.classify(:attributed_active, :not_looked_up)
  end
end
