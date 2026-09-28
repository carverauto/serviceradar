defmodule ServiceRadar.AgentConfig.Compilers.TargetedProfileResolverTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.AgentConfig.Compilers.TargetedProfileResolver

  test "returns no profile for nil device uid" do
    assert TargetedProfileResolver.resolve(nil, :actor,
             resolver: fn _device_uid, _actor -> flunk("should not resolve") end
           ) == {:ok, nil}
  end

  test "returns the default profile for nil device uid" do
    default_profile = %{id: "default"}

    assert TargetedProfileResolver.resolve(nil, :actor,
             resolver: fn _device_uid, _actor -> flunk("should not resolve") end,
             default_resolver: fn :actor -> {:ok, default_profile} end
           ) == {:ok, default_profile}
  end

  test "returns the targeted profile when present" do
    profile = %{id: "profile-1"}

    assert TargetedProfileResolver.resolve("device-1", :actor,
             resolver: fn "device-1", :actor -> {:ok, profile} end,
             default_resolver: fn _actor -> flunk("targeted profile wins") end
           ) == {:ok, profile}
  end

  test "falls back to the default resolver when targeting misses" do
    default_profile = %{id: "default"}

    assert TargetedProfileResolver.resolve("device-1", :actor,
             resolver: fn "device-1", :actor -> {:ok, nil} end,
             default_resolver: fn :actor -> {:ok, default_profile} end
           ) == {:ok, default_profile}
  end

  # A failed read must stay distinguishable from "no profile": the compilers
  # feed ConfigServer, which caches any successful result as the agent's config.
  test "returns a targeting read error instead of the default profile" do
    assert TargetedProfileResolver.resolve("device-1", :actor,
             resolver: fn "device-1", :actor -> {:error, :boom} end,
             default_resolver: fn _actor -> flunk("a failed read is not a targeting miss") end
           ) == {:error, :boom}
  end

  test "returns a default-profile read error" do
    assert TargetedProfileResolver.resolve(nil, :actor,
             resolver: fn _device_uid, _actor -> flunk("should not resolve") end,
             default_resolver: fn :actor -> {:error, :boom} end
           ) == {:error, :boom}
  end
end
