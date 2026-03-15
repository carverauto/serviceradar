defmodule ServiceRadar.AgentConfig.Compilers.TargetedProfileResolverTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.AgentConfig.Compilers.TargetedProfileResolver

  test "returns nil for nil device uid" do
    assert TargetedProfileResolver.resolve(nil, :actor,
             resolver: fn _device_uid, _actor -> flunk("should not resolve") end
           ) == nil
  end

  test "returns the targeted profile when present" do
    profile = %{id: "profile-1"}

    assert TargetedProfileResolver.resolve("device-1", :actor,
             resolver: fn "device-1", :actor -> {:ok, profile} end
           ) == profile
  end

  test "falls back to the default resolver when targeting misses" do
    default_profile = %{id: "default"}

    assert TargetedProfileResolver.resolve("device-1", :actor,
             resolver: fn "device-1", :actor -> {:ok, nil} end,
             default_resolver: fn :actor -> default_profile end
           ) == default_profile
  end

  test "returns the default resolver result after a targeting error" do
    default_profile = %{id: "default"}

    assert TargetedProfileResolver.resolve("device-1", :actor,
             resolver: fn "device-1", :actor -> {:error, :boom} end,
             default_resolver: fn :actor -> default_profile end
           ) == default_profile
  end
end
