defmodule ServiceRadar.SNMPProfiles.SNMPProfileTest do
  @moduledoc """
  Tests for the SNMPProfile resource.

  Tests resource creation, validation, and policy enforcement.
  In the single-deployment architecture, tests run against the single schema
  determined by PostgreSQL search_path.
  """

  use ServiceRadar.DataCase, async: false

  alias Ash.Resource.Info, as: ResourceInfo
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceSNMPCredential
  alias ServiceRadar.SNMPProfiles.SNMPProfile

  require Ash.Query

  describe "module structure" do
    test "module is loaded and defined" do
      assert Code.ensure_loaded?(SNMPProfile)
    end

    test "is an Ash resource" do
      # function_exported?/3 is false for an unloaded module even when the
      # function exists. ExUnit shuffles, so this cannot rely on the previous
      # "module is loaded" test having run first.
      Code.ensure_loaded!(SNMPProfile)
      assert function_exported?(SNMPProfile, :spark_dsl_config, 0)
    end
  end

  describe "default values" do
    test "poll_interval defaults to 60" do
      # Get attribute default from resource
      attrs = ResourceInfo.attributes(SNMPProfile)
      poll_interval = Enum.find(attrs, &(&1.name == :poll_interval))
      assert poll_interval.default == 60
    end

    test "timeout defaults to 5" do
      attrs = ResourceInfo.attributes(SNMPProfile)
      timeout = Enum.find(attrs, &(&1.name == :timeout))
      assert timeout.default == 5
    end

    test "retries defaults to 3" do
      attrs = ResourceInfo.attributes(SNMPProfile)
      retries = Enum.find(attrs, &(&1.name == :retries))
      assert retries.default == 3
    end

    test "is_default defaults to false" do
      attrs = ResourceInfo.attributes(SNMPProfile)
      is_default = Enum.find(attrs, &(&1.name == :is_default))
      assert is_default.default == false
    end

    test "enabled defaults to true" do
      attrs = ResourceInfo.attributes(SNMPProfile)
      enabled = Enum.find(attrs, &(&1.name == :enabled))
      assert enabled.default == true
    end

    test "priority defaults to 0" do
      attrs = ResourceInfo.attributes(SNMPProfile)
      priority = Enum.find(attrs, &(&1.name == :priority))
      assert priority.default == 0
    end

    test "version defaults to v2c" do
      attrs = ResourceInfo.attributes(SNMPProfile)
      version = Enum.find(attrs, &(&1.name == :version))
      assert version.default == :v2c
    end

    test "agent_ids defaults to empty list (legacy all-agents behavior)" do
      attrs = ResourceInfo.attributes(SNMPProfile)
      agent_ids = Enum.find(attrs, &(&1.name == :agent_ids))
      assert agent_ids
      assert agent_ids.default == []
      assert agent_ids.allow_nil? == false
      assert agent_ids.type == {:array, Ash.Type.String}
    end
  end

  describe "actions" do
    test "has create action" do
      actions = ResourceInfo.actions(SNMPProfile)
      assert Enum.any?(actions, &(&1.name == :create))
    end

    test "has update action" do
      actions = ResourceInfo.actions(SNMPProfile)
      assert Enum.any?(actions, &(&1.name == :update))
    end

    test "has read action" do
      actions = ResourceInfo.actions(SNMPProfile)
      assert Enum.any?(actions, &(&1.name == :read))
    end

    test "has set_as_default action" do
      actions = ResourceInfo.actions(SNMPProfile)
      assert Enum.any?(actions, &(&1.name == :set_as_default))
    end

    test "has get_default action" do
      actions = ResourceInfo.actions(SNMPProfile)
      assert Enum.any?(actions, &(&1.name == :get_default))
    end

    test "has list_targeting_profiles action" do
      actions = ResourceInfo.actions(SNMPProfile)
      assert Enum.any?(actions, &(&1.name == :list_targeting_profiles))
    end

    test "has targeting_profiles_for_agent action" do
      actions = ResourceInfo.actions(SNMPProfile)
      assert Enum.any?(actions, &(&1.name == :targeting_profiles_for_agent))
    end

    test "create action accepts agent_ids" do
      action = ResourceInfo.action(SNMPProfile, :create)
      assert :agent_ids in action.accept
    end

    test "update action accepts agent_ids" do
      action = ResourceInfo.action(SNMPProfile, :update)
      assert :agent_ids in action.accept
    end
  end

  describe "CRUD operations" do
    @tag :integration
    setup do
      ServiceRadar.TestSupport.start_core!()
      :ok
    end

    @tag :integration
    test "creates a profile with required fields" do
      actor = SystemActor.system(:test)

      {:ok, profile} =
        SNMPProfile
        |> Ash.Changeset.for_create(
          :create,
          %{name: "Test Profile"},
          actor: actor
        )
        |> Ash.create(actor: actor)

      assert profile.name == "Test Profile"
      assert profile.poll_interval == 60
      assert profile.timeout == 5
      assert profile.retries == 3
      assert profile.is_default == false
      assert profile.enabled == true
      assert profile.priority == 0
      assert profile.version == :v2c
    end

    @tag :integration
    test "creates a profile with all fields" do
      actor = SystemActor.system(:test)

      {:ok, profile} =
        SNMPProfile
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Custom Profile",
            description: "A custom monitoring profile",
            poll_interval: 30,
            timeout: 10,
            retries: 5,
            is_default: false,
            enabled: true,
            target_query: "in:devices tags.role:network",
            priority: 50,
            version: :v3,
            username: "snmpuser",
            security_level: :auth_no_priv,
            auth_protocol: :sha,
            priv_protocol: :aes
          },
          actor: actor
        )
        |> Ash.create(actor: actor)

      assert profile.name == "Custom Profile"
      assert profile.description == "A custom monitoring profile"
      assert profile.poll_interval == 30
      assert profile.timeout == 10
      assert profile.retries == 5
      assert profile.target_query == "in:devices tags.role:network"
      assert profile.priority == 50
      assert profile.version == :v3
      assert profile.username == "snmpuser"
      assert profile.security_level == :auth_no_priv
      assert profile.auth_protocol == :sha
      assert profile.priv_protocol == :aes
    end

    @tag :integration
    test "enforces unique name per instance" do
      actor = SystemActor.system(:test)

      {:ok, _profile1} =
        SNMPProfile
        |> Ash.Changeset.for_create(
          :create,
          %{name: "Duplicate Name"},
          actor: actor
        )
        |> Ash.create(actor: actor)

      {:error, _error} =
        SNMPProfile
        |> Ash.Changeset.for_create(
          :create,
          %{name: "Duplicate Name"},
          actor: actor
        )
        |> Ash.create(actor: actor)
    end

    @tag :integration
    test "set_as_default clears other defaults" do
      actor = SystemActor.system(:test)

      # Create first profile
      {:ok, profile1} =
        SNMPProfile
        |> Ash.Changeset.for_create(
          :create,
          %{name: "Profile 1"},
          actor: actor
        )
        |> Ash.create(actor: actor)

      # Create second profile
      {:ok, profile2} =
        SNMPProfile
        |> Ash.Changeset.for_create(
          :create,
          %{name: "Profile 2"},
          actor: actor
        )
        |> Ash.create(actor: actor)

      # Set profile2 as default
      {:ok, updated_profile2} =
        profile2
        |> Ash.Changeset.for_update(:set_as_default, %{}, actor: actor)
        |> Ash.update(actor: actor)

      assert updated_profile2.is_default == true

      # Reload profile1 and check it's no longer default
      {:ok, reloaded_profile1} = Ash.get(SNMPProfile, profile1.id, actor: actor)
      assert reloaded_profile1.is_default == false
    end
  end

  # A community string, SNMPv3 user name or password may legitimately begin or
  # end with whitespace; storing anything else fails authentication against the
  # device. Only an empty or whitespace-only value means "keep".
  describe "storing inline credentials" do
    @describetag :integration

    setup do
      ServiceRadar.TestSupport.start_core!()
      %{actor: SystemActor.system(:test), unique: System.unique_integer([:positive])}
    end

    test "keeps leading and trailing whitespace on create and update", %{
      actor: actor,
      unique: unique
    } do
      community = "  example ro #{unique} "

      v2c = create_profile!(actor, %{name: "Exact v2c #{unique}", community: community})
      assert decrypt!(reload!(v2c, actor).community_encrypted) == community

      v3_credentials = %{
        username: " example user ",
        auth_password: "\texample auth #{unique}  ",
        priv_password: " example priv #{unique}\n"
      }

      v3 =
        create_profile!(
          actor,
          Map.merge(v3_credentials, %{
            name: "Exact v3 #{unique}",
            version: :v3,
            security_level: :auth_priv,
            auth_protocol: :sha256,
            priv_protocol: :aes
          })
        )

      reloaded_v3 = reload!(v3, actor)
      assert reloaded_v3.username == v3_credentials.username
      assert decrypt!(reloaded_v3.auth_password_encrypted) == v3_credentials.auth_password
      assert decrypt!(reloaded_v3.priv_password_encrypted) == v3_credentials.priv_password

      replacement = " example rw #{unique}  "
      update_profile!(v2c, actor, %{community: replacement})
      assert decrypt!(reload!(v2c, actor).community_encrypted) == replacement

      update_profile!(v2c, actor, %{community: "   "})
      assert decrypt!(reload!(v2c, actor).community_encrypted) == replacement
    end

    defp decrypt!(ciphertext) do
      {:ok, plaintext} = ServiceRadar.Vault.decrypt(ciphertext)
      plaintext
    end
  end

  # Ash casts a blank :string argument to nil, so "" can only ever mean "keep".
  # Removing a stored secret is its own explicit input.
  describe "removing stored inline credentials" do
    @describetag :integration

    setup do
      ServiceRadar.TestSupport.start_core!()
      %{actor: SystemActor.system(:test), unique: System.unique_integer([:positive])}
    end

    test "a blank value keeps the stored community and clear_credentials removes it", %{
      actor: actor,
      unique: unique
    } do
      profile =
        create_profile!(actor, %{name: "Clear #{unique}", community: "example-ro-#{unique}"})

      assert profile.community_encrypted

      update_profile!(profile, actor, %{community: ""})
      assert reload!(profile, actor).community_encrypted

      update_profile!(profile, actor, %{clear_credentials: [:community]})
      assert reload!(profile, actor).community_encrypted == nil
    end

    test "binding a reusable credential removes the inline credentials it replaces", %{
      actor: actor,
      unique: unique
    } do
      profile =
        create_profile!(actor, %{
          name: "Bind #{unique}",
          version: :v2c,
          community: "example-ro-#{unique}"
        })

      secret = create_v3_secret!(actor, unique)

      update_profile!(profile, actor, %{credential_secret_id: secret.id, version: :v3})

      reloaded = reload!(profile, actor)
      assert reloaded.credential_secret_id == secret.id
      assert reloaded.version == :v3
      assert reloaded.community_encrypted == nil
    end

    test "a call that both supplies and removes a community is rejected", %{
      actor: actor,
      unique: unique
    } do
      profile =
        create_profile!(actor, %{name: "Conflict #{unique}", community: "example-ro-#{unique}"})

      secret = create_v3_secret!(actor, unique)

      for removal <- [%{clear_credentials: [:community]}, %{credential_secret_id: secret.id}] do
        input = Map.put(removal, :community, "example-rw-#{unique}")

        assert {:error, %Ash.Error.Invalid{errors: errors}} =
                 profile
                 |> Ash.Changeset.for_update(:update, input, actor: actor)
                 |> Ash.update(actor: actor)

        assert Enum.any?(errors, &(Map.get(&1, :field) == :community))
      end

      reloaded = reload!(profile, actor)
      assert reloaded.community_encrypted == profile.community_encrypted
      assert reloaded.credential_secret_id == nil
    end

    test "binding a reusable credential on an atomic device override removes its community", %{
      actor: actor,
      unique: unique
    } do
      device_uid = Ecto.UUID.generate()

      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: device_uid,
          hostname: "host#{unique}.example.com",
          type_id: 10,
          created_time: DateTime.utc_now(),
          modified_time: DateTime.utc_now()
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

      override =
        DeviceSNMPCredential
        |> Ash.Changeset.for_create(
          :create,
          %{device_id: device_uid, version: :v2c, community: "example-ro-#{unique}"},
          actor: actor
        )
        |> Ash.create!(actor: actor)

      assert override.community_encrypted

      secret = create_v3_secret!(actor, unique)

      override
      |> Ash.Changeset.for_update(:update, %{credential_secret_id: secret.id, version: :v3},
        actor: actor
      )
      |> Ash.update!(actor: actor)

      reloaded = Ash.get!(DeviceSNMPCredential, override.id, actor: actor)
      assert reloaded.credential_secret_id == secret.id
      assert reloaded.community_encrypted == nil
    end

    defp create_profile!(actor, attrs) do
      SNMPProfile
      |> Ash.Changeset.for_create(:create, attrs, actor: actor)
      |> Ash.create!(actor: actor)
    end

    defp create_v3_secret!(actor, unique) do
      NetworkCredentialSecret
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "snmp-v3-#{unique}",
          provider: "snmp",
          credential_kind: :snmp,
          username: "example-user",
          secret_payload: Jason.encode!(%{"username" => "example-user"}),
          metadata: %{"auth_method" => "v3"}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)
    end

    defp update_profile!(profile, actor, attrs) do
      profile
      |> Ash.Changeset.for_update(:update, attrs, actor: actor)
      |> Ash.update!(actor: actor)
    end

    defp reload!(profile, actor), do: Ash.get!(SNMPProfile, profile.id, actor: actor)
  end
end
