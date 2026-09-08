defmodule ServiceRadarWebNGWeb.Settings.RbacLive.PolicyDataTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Settings.RbacLive.PolicyData

  @moduletag :db_free

  @group_id "11111111-1111-4111-8111-111111111111"
  @profile_id "22222222-2222-4222-8222-222222222222"

  test "build_group_profiles issues fresh opaque tokens for every server record" do
    groups = [%{id: @group_id, name: "Synthetic operators", role_profile_id: @profile_id}]
    profiles = [%{id: @profile_id, name: "Synthetic operator policy"}]

    first = PolicyData.build_group_profiles(groups, profiles)
    second = PolicyData.build_group_profiles(groups, profiles)

    assert first.groups == groups
    assert first.profiles == profiles
    assert Map.values(first.group_tokens) == [@group_id]
    assert Map.values(first.profile_tokens) == [@profile_id]

    tokens = Map.keys(first.group_tokens) ++ Map.keys(first.profile_tokens)
    refute @group_id in tokens
    refute @profile_id in tokens
    assert Enum.all?(tokens, &Regex.match?(~r/^[A-Za-z0-9_-]+$/, &1))
    assert Map.keys(first.group_tokens) != Map.keys(second.group_tokens)
    assert Map.keys(first.profile_tokens) != Map.keys(second.profile_tokens)
  end

  test "accept_generation accepts only the current async generation" do
    current = %{generation: 4, groups: [], profiles: [], group_tokens: %{}, profile_tokens: %{}}
    late = %{current | generation: 3}

    assert {:ok, ^current} = PolicyData.accept_generation(4, current)
    assert :ignore = PolicyData.accept_generation(4, late)
    assert :ignore = PolicyData.accept_generation(4, %{groups: []})
  end

  test "resolve_assignment binds browser intent to current opaque maps" do
    data = %{
      generation: 7,
      groups: [],
      profiles: [],
      group_tokens: %{"opaque-group" => @group_id},
      profile_tokens: %{"opaque-profile" => @profile_id}
    }

    assert {:ok, {@group_id, @profile_id}} =
             PolicyData.resolve_assignment(data, 7, %{
               "group-token" => "opaque-group",
               "profile-token" => "opaque-profile",
               "group-id" => "browser-forged-group",
               "profile-id" => "browser-forged-profile"
             })

    assert {:ok, {@group_id, nil}} =
             PolicyData.resolve_clear(data, 7, %{
               "group-token" => "opaque-group",
               "profile-token" => "browser-forged-profile"
             })

    assert {:error, :stale} =
             PolicyData.resolve_assignment(data, 6, %{
               "group-token" => "opaque-group",
               "profile-token" => "opaque-profile"
             })

    assert {:error, :stale} =
             PolicyData.resolve_assignment(data, 7, %{
               "group-token" => "opaque-group",
               "profile-token" => "unknown-profile"
             })

    assert {:error, :stale} =
             PolicyData.resolve_clear(data, 7, %{"group-token" => "unknown-group"})
  end
end
