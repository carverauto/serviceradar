defmodule ServiceRadar.SysmonProfiles.SysmonProfileSeederTest do
  @moduledoc """
  Tests for the SysmonProfileSeeder module.

  Unit tests verify module structure.
  Integration tests (tagged :integration) verify actual profile seeding.
  In the single-deployment architecture, tests run against the single schema
  determined by PostgreSQL search_path.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.SysmonProfiles.{SysmonProfile, SysmonProfileSeeder}

  require Ash.Query

  describe "module structure" do
    test "module is loaded and defined" do
      assert Code.ensure_loaded?(SysmonProfileSeeder)
    end

    test "defines seed function" do
      functions = SysmonProfileSeeder.__info__(:functions)
      assert {:seed, 0} in functions
    end
  end

  describe "seeding" do
    @tag :integration
    setup do
      ServiceRadar.TestSupport.start_core!()
      :ok
    end

    @tag :integration
    test "creates default profile when none exists" do
      # Seed the default profile
      result = SysmonProfileSeeder.seed()

      assert result == :ok or match?({:ok, _}, result)

      # Verify the profile was created
      actor = SystemActor.system(:test)

      query =
        SysmonProfile
        |> Ash.Query.for_read(:get_default, %{}, actor: actor)

      {:ok, profile} = Ash.read_one(query, actor: actor)

      assert profile != nil
      assert profile.name == "Default"
      assert profile.is_default == true
      assert profile.enabled == true
      assert profile.sample_interval == "10s"
      assert profile.collect_cpu == true
      assert profile.collect_memory == true
      assert profile.collect_disk == true
      assert profile.collect_network == false
      assert profile.collect_processes == false
    end

    @tag :integration
    test "does not create duplicate profile when called twice" do
      # Seed once
      SysmonProfileSeeder.seed()

      # Seed again
      result = SysmonProfileSeeder.seed()
      assert result == :ok

      # Verify only one default profile exists
      actor = SystemActor.system(:test)

      query =
        SysmonProfile
        |> Ash.Query.for_read(:read, %{}, actor: actor)
        |> Ash.Query.filter(is_default == true)

      {:ok, profiles} = Ash.read(query, actor: actor)

      assert length(profiles) == 1
    end

    @tag :integration
    test "default profile has correct thresholds" do
      SysmonProfileSeeder.seed()

      actor = SystemActor.system(:test)

      query =
        SysmonProfile
        |> Ash.Query.for_read(:get_default, %{}, actor: actor)

      {:ok, profile} = Ash.read_one(query, actor: actor)

      assert profile.thresholds["cpu_warning"] == "80"
      assert profile.thresholds["cpu_critical"] == "95"
      assert profile.thresholds["memory_warning"] == "85"
      assert profile.thresholds["memory_critical"] == "95"
      assert profile.thresholds["disk_warning"] == "80"
      assert profile.thresholds["disk_critical"] == "95"
    end
  end
end
