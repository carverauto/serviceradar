defmodule ServiceRadar.SNMPProfiles.SrqlTargetResolverTest do
  @moduledoc """
  Tests for the SrqlTargetResolver module.

  Tests SRQL-based profile targeting for SNMP profiles including:
  - Device matching with various SRQL queries
  - Priority-based resolution
  - Interface targeting (simplified)
  - Error handling
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.SNMPProfiles.SNMPProfile
  alias ServiceRadar.SNMPProfiles.SrqlTargetResolver

  require Ash.Query

  describe "module structure" do
    test "module is loaded and defined" do
      assert Code.ensure_loaded?(SrqlTargetResolver)
    end

    test "resolve_for_device/2 is callable" do
      assert {:ok, nil} = SrqlTargetResolver.resolve_for_device(nil, nil)
    end
  end

  describe "resolve_for_device/2 validation" do
    test "returns ok nil for nil device_uid" do
      assert {:ok, nil} = SrqlTargetResolver.resolve_for_device(nil, nil)
    end

    test "returns ok nil for invalid device_uid format" do
      actor = %{role: :system}
      result = SrqlTargetResolver.resolve_for_device("not-a-uuid", actor)
      assert {:ok, nil} = result
    end

    test "returns ok nil for malformed UUID" do
      actor = %{role: :system}
      result = SrqlTargetResolver.resolve_for_device("12345", actor)
      assert {:ok, nil} = result
    end
  end

  describe "resolve_for_device/2 with profiles" do
    @tag :integration
    setup do
      ServiceRadar.TestSupport.start_core!()
      :ok
    end

    @tag :integration
    test "returns nil when no targeting profiles exist" do
      # Schema determined by DB connection
      actor = SystemActor.system(:test)

      # Create a default profile (not a targeting profile)
      {:ok, _default_profile} =
        SNMPProfile
        |> Ash.Changeset.for_create(
          :create,
          %{name: "Default Profile #{System.unique_integer([:positive])}"},
          actor: actor
        )
        |> Ash.create(actor: actor)

      device_uid = Ecto.UUID.generate()
      result = SrqlTargetResolver.resolve_for_device(device_uid, actor)

      assert {:ok, nil} = result
    end

    @tag :integration
    test "matches device with hostname query" do
      # Schema determined by DB connection
      actor = SystemActor.system(:test)

      # Create a device
      device_uid = Ecto.UUID.generate()

      {:ok, _device} =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: device_uid,
            hostname: "test-router-01",
            type_id: 3,
            created_time: DateTime.utc_now(),
            modified_time: DateTime.utc_now()
          },
          actor: actor
        )
        |> Ash.create(actor: actor)

      # Create a targeting profile
      {:ok, profile} =
        SNMPProfile
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Router Profile #{System.unique_integer([:positive])}",
            target_query: "in:devices hostname:\"test-router-01\"",
            priority: 10
          },
          actor: actor
        )
        |> Ash.create(actor: actor)

      result = SrqlTargetResolver.resolve_for_device(device_uid, actor)

      assert {:ok, matched_profile} = result
      assert matched_profile.id == profile.id
    end

    @tag :integration
    test "returns nil when device does not match query" do
      # Schema determined by DB connection
      actor = SystemActor.system(:test)

      # Create a device with different hostname
      device_uid = Ecto.UUID.generate()

      {:ok, _device} =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: device_uid,
            hostname: "switch-01",
            type_id: 3,
            created_time: DateTime.utc_now(),
            modified_time: DateTime.utc_now()
          },
          actor: actor
        )
        |> Ash.create(actor: actor)

      # Create a targeting profile that won't match
      {:ok, _profile} =
        SNMPProfile
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Router Profile #{System.unique_integer([:positive])}",
            target_query: "in:devices hostname:\"router-01\"",
            priority: 10
          },
          actor: actor
        )
        |> Ash.create(actor: actor)

      result = SrqlTargetResolver.resolve_for_device(device_uid, actor)

      assert {:ok, nil} = result
    end

    @tag :integration
    test "resolves by priority - higher priority wins" do
      # Schema determined by DB connection
      actor = SystemActor.system(:test)

      # Create a device
      device_uid = Ecto.UUID.generate()

      {:ok, _device} =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: device_uid,
            hostname: "core-router-01",
            type_id: 3,
            created_time: DateTime.utc_now(),
            modified_time: DateTime.utc_now()
          },
          actor: actor
        )
        |> Ash.create(actor: actor)

      # Create low priority profile
      {:ok, low_priority} =
        SNMPProfile
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "General Network #{System.unique_integer([:positive])}",
            target_query: "in:devices hostname:\"core-router-01\"",
            priority: 5
          },
          actor: actor
        )
        |> Ash.create(actor: actor)

      # Create high priority profile (should match first)
      {:ok, high_priority} =
        SNMPProfile
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Core Routers #{System.unique_integer([:positive])}",
            target_query: "in:devices hostname:\"core-router-01\"",
            priority: 20
          },
          actor: actor
        )
        |> Ash.create(actor: actor)

      result = SrqlTargetResolver.resolve_for_device(device_uid, actor)

      assert {:ok, matched_profile} = result
      # High priority profile should be returned
      assert matched_profile.id == high_priority.id
      assert matched_profile.id != low_priority.id
    end

    @tag :integration
    test "skips disabled profiles" do
      # Schema determined by DB connection
      actor = SystemActor.system(:test)

      # Create a device
      device_uid = Ecto.UUID.generate()

      {:ok, _device} =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: device_uid,
            hostname: "server-01",
            type_id: 3,
            created_time: DateTime.utc_now(),
            modified_time: DateTime.utc_now()
          },
          actor: actor
        )
        |> Ash.create(actor: actor)

      # Create disabled targeting profile
      {:ok, _disabled_profile} =
        SNMPProfile
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Disabled Profile #{System.unique_integer([:positive])}",
            target_query: "in:devices hostname:\"server-01\"",
            priority: 10,
            enabled: false
          },
          actor: actor
        )
        |> Ash.create(actor: actor)

      # Create enabled profile with lower priority
      {:ok, enabled_profile} =
        SNMPProfile
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Enabled Profile #{System.unique_integer([:positive])}",
            target_query: "in:devices hostname:\"server-01\"",
            priority: 5,
            enabled: true
          },
          actor: actor
        )
        |> Ash.create(actor: actor)

      result = SrqlTargetResolver.resolve_for_device(device_uid, actor)

      assert {:ok, matched_profile} = result
      # Should return the enabled profile, not the disabled one
      assert matched_profile.id == enabled_profile.id
    end

    @tag :integration
    test "skips profiles without target_query (non-targeting profiles)" do
      # Schema determined by DB connection
      actor = SystemActor.system(:test)

      # Create a device
      device_uid = Ecto.UUID.generate()

      {:ok, _device} =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: device_uid,
            hostname: "device-01",
            type_id: 3,
            created_time: DateTime.utc_now(),
            modified_time: DateTime.utc_now()
          },
          actor: actor
        )
        |> Ash.create(actor: actor)

      # Create non-targeting profile (no target_query)
      {:ok, _non_targeting} =
        SNMPProfile
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Manual Assignment Only #{System.unique_integer([:positive])}",
            priority: 100
          },
          actor: actor
        )
        |> Ash.create(actor: actor)

      # Create targeting profile with lower priority
      {:ok, targeting_profile} =
        SNMPProfile
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Auto-Target Profile #{System.unique_integer([:positive])}",
            target_query: "in:devices hostname:\"device-01\"",
            priority: 10
          },
          actor: actor
        )
        |> Ash.create(actor: actor)

      result = SrqlTargetResolver.resolve_for_device(device_uid, actor)

      assert {:ok, matched_profile} = result
      assert matched_profile.id == targeting_profile.id
    end
  end
end
