defmodule ServiceRadar.SRQLProfileResolverTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.SRQLProfileResolver

  test "returns nil for invalid device uids" do
    assert {:ok, nil} =
             SRQLProfileResolver.resolve("not-a-uuid", :actor,
               load_profiles: fn _actor -> flunk("should not load profiles") end,
               match_profile: fn _profile, _device_uid, _actor -> flunk("should not match") end
             )
  end

  test "returns first matching profile" do
    profiles = [%{id: "one"}, %{id: "two"}]

    assert {:ok, %{id: "two"}} =
             SRQLProfileResolver.resolve(Ecto.UUID.generate(), :actor,
               load_profiles: fn :actor -> {:ok, profiles} end,
               match_profile: fn
                 %{id: "one"}, _device_uid, :actor -> {:ok, false}
                 %{id: "two"}, _device_uid, :actor -> {:ok, true}
               end
             )
  end

  test "continues after match errors" do
    profiles = [%{id: "bad"}, %{id: "good"}]

    assert {:ok, %{id: "good"}} =
             SRQLProfileResolver.resolve(Ecto.UUID.generate(), :actor,
               load_profiles: fn :actor -> {:ok, profiles} end,
               match_profile: fn
                 %{id: "bad"}, _device_uid, :actor -> {:error, :boom}
                 %{id: "good"}, _device_uid, :actor -> {:ok, true}
               end
             )
  end
end
