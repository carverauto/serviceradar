defmodule ServiceRadar.Inventory.DeviceLifecycleTest do
  @moduledoc """
  Tests for device lifecycle in-service decisions, including the failed-read
  contract that lets config compilers fail instead of guessing.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceLifecycle
  alias ServiceRadar.Repo

  @moduletag :integration

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  describe "fetch_active?/2" do
    test "reports an inactive device as inactive and an active device as active" do
      actor = SystemActor.system(:test)
      unique = System.unique_integer([:positive])

      {:ok, active} = create_device("device-lifecycle-active-#{unique}", actor)
      {:ok, inactive} = create_device("device-lifecycle-inactive-#{unique}", actor)

      {:ok, _updated} =
        inactive
        |> Ash.Changeset.for_update(:mark_inactive, %{}, actor: actor)
        |> Ash.update(actor: actor)

      assert {:ok, true} = DeviceLifecycle.fetch_active?(active.uid, actor: actor)
      assert {:ok, false} = DeviceLifecycle.fetch_active?(inactive.uid, actor: actor)
    end

    test "a nil or empty device uid is a zero-row active read, not a failure" do
      actor = SystemActor.system(:test)

      assert {:ok, true} = DeviceLifecycle.fetch_active?(nil, actor: actor)
      assert {:ok, true} = DeviceLifecycle.fetch_active?("", actor: actor)
    end

    test "a failed device read is an error, not an active device" do
      actor = SystemActor.system(:test)

      Repo.query!("ALTER TABLE platform.ocsf_devices RENAME TO _ocsf_devices_hidden")

      try do
        assert {:error, _reason} =
                 DeviceLifecycle.fetch_active?("sr:device-lifecycle-read-failure",
                   actor: actor
                 )
      after
        Repo.query!("ALTER TABLE platform._ocsf_devices_hidden RENAME TO ocsf_devices")
      end
    end

    test "active?/2 keeps failing open for event suppression" do
      actor = SystemActor.system(:test)

      Repo.query!("ALTER TABLE platform.ocsf_devices RENAME TO _ocsf_devices_hidden")

      try do
        # Event suppression must not drop events because a lookup failed, so
        # active?/2 stays fail-open even though fetch_active?/2 errors.
        assert DeviceLifecycle.active?("sr:device-lifecycle-read-failure", actor: actor)
      after
        Repo.query!("ALTER TABLE platform._ocsf_devices_hidden RENAME TO ocsf_devices")
      end
    end
  end

  defp create_device(uid, actor) do
    unique = System.unique_integer([:positive])

    Device
    |> Ash.Changeset.for_create(:create, %{
      uid: uid,
      hostname: "#{uid}.example.com",
      ip: "10.40.#{rem(unique, 250) + 1}.#{rem(div(unique, 250), 250) + 1}",
      discovery_sources: ["mapper"]
    })
    |> Ash.create(actor: actor)
  end
end
