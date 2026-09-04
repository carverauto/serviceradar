defmodule ServiceRadar.SNMPProfiles.SNMPProfileLifecycleDbTest do
  @moduledoc """
  Retiring an SNMP profile. GitHub #4170.

  A default profile used to be a dead end: `:destroy` is forbidden while
  `is_default` is true, and nothing exposed a way to clear the flag. The escape
  is demote-then-delete, so the destroy guard stays honest rather than being
  relaxed into an admin-only override.

  An instance with no profile at all is a legitimate state -- it means SNMP
  polling is off -- so nothing may recreate one behind the operator's back.
  """
  use ServiceRadar.DataCase, async: false

  alias Ash.Error.Forbidden
  alias ServiceRadar.Cluster.CoordinatorChildren
  alias ServiceRadar.SNMPProfiles.SNMPProfile

  require Ash.Query

  @moduletag :integration

  @admin %{
    id: "snmp-profile-lifecycle-admin",
    role: :admin,
    permissions: MapSet.new(["settings.snmp_profiles.manage"])
  }

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup :demote_existing_default

  # `snmp_profiles_unique_default_index` is a partial unique index on
  # `is_default WHERE is_default`, so the database allows exactly one default
  # profile. The fixture database has run the migration that seeds one, and a
  # fixture here asking for `is_default: true` would collide with it. The
  # sandbox rolls this demotion back after each test.
  defp demote_existing_default(_context) do
    case Ash.read_one(Ash.Query.for_read(SNMPProfile, :get_default, %{}), actor: @admin) do
      {:ok, %SNMPProfile{} = existing} ->
        existing
        |> Ash.Changeset.for_update(:unset_default, %{}, actor: @admin)
        |> Ash.update!(actor: @admin)

        :ok

      _ ->
        :ok
    end
  end

  describe "retiring a default profile" do
    test "destroy is forbidden while the profile is the default" do
      profile = profile_fixture(is_default: true)

      assert {:error, %Forbidden{}} = Ash.destroy(profile, actor: @admin)
      assert {:ok, _still_there} = Ash.get(SNMPProfile, profile.id, actor: @admin)
    end

    test "unset_default clears the flag so the profile can then be destroyed" do
      profile = profile_fixture(is_default: true)

      assert {:ok, demoted} =
               profile
               |> Ash.Changeset.for_update(:unset_default, %{}, actor: @admin)
               |> Ash.update(actor: @admin)

      refute demoted.is_default

      assert :ok = Ash.destroy(demoted, actor: @admin)
      assert {:error, _} = Ash.get(SNMPProfile, profile.id, actor: @admin)
    end

    test "unset_default is admin-gated" do
      profile = profile_fixture(is_default: true)
      viewer = %{id: "snmp-profile-lifecycle-viewer", role: :viewer, permissions: MapSet.new()}

      assert {:error, %Forbidden{}} =
               profile
               |> Ash.Changeset.for_update(:unset_default, %{}, actor: viewer)
               |> Ash.update(actor: viewer)
    end
  end

  describe "no profile means SNMP is off" do
    test "nothing in the coordinator supervision tree recreates a deleted profile" do
      # config/test.exs sets `seeders_enabled: false`, so `children/0` lists no
      # seeder at all by default and a bare refute here would pass whatever the
      # supervision tree said -- it passed against a deliberately wrong module
      # name when this was written. Enable seeders, then assert that a seeder
      # which IS still supervised shows up: that positive control is the only
      # thing making the refute below mean anything.
      previous = Application.get_env(:serviceradar_core, :seeders_enabled)
      Application.put_env(:serviceradar_core, :seeders_enabled, true)
      on_exit(fn -> Application.put_env(:serviceradar_core, :seeders_enabled, previous) end)

      modules = Enum.map(CoordinatorChildren.children(), &child_module/1)

      assert Enum.any?(modules, &seeder_named?(&1, "RoleProfileSeeder")),
             "positive control failed: no seeder is visible in children/0, so the refute below proves nothing"

      refute Enum.any?(modules, &seeder_named?(&1, "SNMPProfileSeeder")),
             """
             A supervised SNMP profile seeder resurrects a profile the operator \
             deleted, and the revival is silent. Seed the starter profile from a \
             migration, which runs exactly once, instead.
             """
    end
  end

  defp seeder_named?(module, name), do: String.contains?(to_string(module), name)

  defp child_module(%{start: {module, _fun, _args}}), do: module
  defp child_module({module, _arg}), do: module
  defp child_module(module) when is_atom(module), do: module
  defp child_module(_other), do: nil

  defp profile_fixture(opts) do
    attrs = %{
      name: "lifecycle-#{System.unique_integer([:positive])}",
      poll_interval: 60,
      timeout: 5,
      retries: 3,
      target_query: "in:devices",
      is_default: Keyword.get(opts, :is_default, false)
    }

    SNMPProfile
    |> Ash.Changeset.for_create(:create, attrs, actor: @admin)
    |> Ash.create!(actor: @admin)
  end
end
