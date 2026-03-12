defmodule ServiceRadar.SNMPProfiles.CredentialResolverTest do
  @moduledoc """
  Tests for SNMP credential resolution precedence.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.DeviceAliasState
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
      hostname = "device-override-test-#{System.unique_integer([:positive])}"

      {:ok, _device} =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: device_uid,
            hostname: hostname,
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
            name: "Override Profile #{System.unique_integer([:positive])}",
            target_query: ~s(in:devices hostname:"#{hostname}"),
            priority: 100,
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
      hostname = "profile-cred-test-#{System.unique_integer([:positive])}"

      {:ok, _device} =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: device_uid,
            hostname: hostname,
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
            name: "Profile Credential #{System.unique_integer([:positive])}",
            target_query: ~s(in:devices hostname:"#{hostname}"),
            priority: 100,
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

    @tag :integration
    test "resolve_for_host follows confirmed IP aliases back to the canonical device" do
      actor = SystemActor.system(:test)
      device_uid = "sr:" <> Ecto.UUID.generate()
      hostname = "alias-credential-test-#{System.unique_integer([:positive])}"
      public_ip = "198.51.100.#{rem(System.unique_integer([:positive]), 200) + 1}"
      alias_ip = "192.168.10.#{rem(System.unique_integer([:positive]), 200) + 1}"

      {:ok, _device} =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: device_uid,
            hostname: hostname,
            ip: public_ip,
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
            name: "Alias Credential Profile #{System.unique_integer([:positive])}",
            target_query: ~s(in:devices hostname:"#{hostname}"),
            priority: 100,
            version: :v2c,
            community: "public"
          },
          actor: actor
        )
        |> Ash.create(actor: actor)

      {:ok, alias_state} =
        DeviceAliasState.create_detected(
          %{
            device_id: device_uid,
            partition: "default",
            alias_type: :ip,
            alias_value: alias_ip,
            metadata: %{}
          },
          actor: actor
        )

      {:ok, _confirmed} =
        DeviceAliasState.record_sighting(
          alias_state,
          %{confirm_threshold: 1},
          actor: actor
        )

      assert {:ok, %{credential: credential, source: :profile}} =
               CredentialResolver.resolve_for_host(alias_ip, actor)

      assert credential.community == "public"
    end
  end
end
