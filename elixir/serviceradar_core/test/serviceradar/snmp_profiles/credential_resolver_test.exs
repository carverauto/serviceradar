defmodule ServiceRadar.SNMPProfiles.CredentialResolverTest do
  @moduledoc """
  Tests for SNMP credential resolution precedence.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Credentials.NetworkCredentialSecret
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
    test "credential rule wins over a profile-bound secret" do
      actor = SystemActor.system(:test)
      unique = System.unique_integer([:positive])
      device_uid = Ecto.UUID.generate()
      hostname = "snmp-rule-#{unique}"
      agent_id = "agent-snmp-#{unique}"

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

      {:ok, profile_secret} =
        NetworkCredentialSecret
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "profile-snmp-#{unique}",
            provider: "snmp",
            credential_kind: :snmp,
            secret_payload: Jason.encode!(%{"community" => "profile-community"})
          },
          actor: actor
        )
        |> Ash.create(actor: actor)

      {:ok, _profile} =
        SNMPProfile
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Rule vs profile #{unique}",
            target_query: ~s(in:devices hostname:"#{hostname}"),
            priority: 100,
            version: :v2c,
            credential_secret_id: profile_secret.id
          },
          actor: actor
        )
        |> Ash.create(actor: actor)

      {:ok, rule_secret} =
        NetworkCredentialSecret
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "rule-snmp-#{unique}",
            provider: "snmp",
            credential_kind: :snmp,
            username: "serviceradar",
            secret_payload:
              Jason.encode!(%{
                "username" => "serviceradar",
                "security_level" => "authPriv",
                "auth_protocol" => "sha",
                "auth_password" => "unifi-pass",
                "priv_protocol" => "aes"
              })
          },
          actor: actor
        )
        |> Ash.create(actor: actor)

      {:ok, _rule} =
        NetworkCredentialRule
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "snmp-rule-#{unique}",
            provider: "snmp",
            auth_method: "v3",
            purpose: "snmp_monitoring",
            target_query: "in:devices",
            scope_type: :agent,
            scope_value: agent_id,
            secret_id: rule_secret.id
          },
          actor: actor
        )
        |> Ash.create(actor: actor)

      assert {:ok, %{credential: credential, source: :credential_rule}} =
               CredentialResolver.resolve_for_device(device_uid, actor, agent_id: agent_id)

      assert credential.version == :v3
      assert credential.username == "serviceradar"
      assert credential.security_level == :auth_priv
      assert credential.auth_protocol == :sha
      assert credential.priv_protocol == :aes
      assert credential.auth_password == "unifi-pass"
      assert credential.priv_password == "unifi-pass"
    end

    @tag :integration
    test "resolve_for_host follows confirmed IP aliases back to the canonical device" do
      actor = SystemActor.system(:test)
      device_uid = "sr:" <> Ecto.UUID.generate()
      hostname = "alias-credential-test-#{System.unique_integer([:positive])}"
      ip_seed = System.unique_integer([:positive])
      public_ip = "198.51.100.#{rem(ip_seed, 200) + 1}"
      alias_ip = "100.64.#{rem(div(ip_seed, 200), 200) + 1}.#{rem(ip_seed, 200) + 1}"

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

      {:ok, _conflicting_device} =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: Ecto.UUID.generate(),
            hostname: "alias-collision-test-#{System.unique_integer([:positive])}",
            ip: alias_ip,
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
