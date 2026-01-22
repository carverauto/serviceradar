defmodule ServiceRadar.SNMPProfiles.CredentialResolverTest do
  @moduledoc """
  Tests for SNMP credential resolution precedence.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceSNMPCredential
  alias ServiceRadar.SNMPProfiles.CredentialResolver
  alias ServiceRadar.SNMPProfiles.SNMPProfile

  describe "resolve_for_device/2" do
    @tag :integration
    setup do
      ServiceRadar.TestSupport.start_core!()
      :ok
    end

    @tag :integration
    test "uses device override when present" do
      actor = SystemActor.system(:test)
      device_uid = Ecto.UUID.generate()

      {:ok, _device} =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: device_uid,
            hostname: "device-override-test",
            type_id: 10,
            created_time: DateTime.utc_now(),
            modified_time: DateTime.utc_now()
          },
          actor: actor
        )
        |> Ash.create(actor: actor)

      {:ok, _profile} =
        SNMPProfile
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Default Profile",
            is_default: true,
            version: :v2c,
            community: "public"
          },
          actor: actor
        )
        |> Ash.create(actor: actor)

      {:ok, _override} =
        DeviceSNMPCredential
        |> Ash.Changeset.for_create(
          :create,
          %{
            device_id: device_uid,
            version: :v2c,
            community: "private"
          },
          actor: actor
        )
        |> Ash.create(actor: actor)

      assert {:ok, %{credential: credential, source: :device_override}} =
               CredentialResolver.resolve_for_device(device_uid, actor)

      assert credential.community == "private"
    end

    @tag :integration
    test "falls back to profile credentials when no override exists" do
      actor = SystemActor.system(:test)
      device_uid = Ecto.UUID.generate()

      {:ok, _device} =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: device_uid,
            hostname: "profile-cred-test",
            type_id: 10,
            created_time: DateTime.utc_now(),
            modified_time: DateTime.utc_now()
          },
          actor: actor
        )
        |> Ash.create(actor: actor)

      {:ok, _profile} =
        SNMPProfile
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Default Profile",
            is_default: true,
            version: :v2c,
            community: "public"
          },
          actor: actor
        )
        |> Ash.create(actor: actor)

      assert {:ok, %{credential: credential, source: :profile}} =
               CredentialResolver.resolve_for_device(device_uid, actor)

      assert credential.community == "public"
    end
  end
end
