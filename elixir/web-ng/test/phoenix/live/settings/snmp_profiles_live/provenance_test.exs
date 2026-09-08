defmodule ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.ProvenanceTest do
  @moduledoc """
  Plugin provenance and the no-credential warning on /settings/snmp.

  Recording provenance in a column nothing renders does not satisfy the
  requirement: configuration appearing in an operator's list with no explanation
  of where it came from is the buried-backend-state problem plugin-declared SNMP
  requirements exist to avoid.
  """

  use ServiceRadarWebNGWeb.ConnCase, async: true
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.SNMPProfiles.SNMPProfile
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures
  alias ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Provenance
  alias ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.View.TemplateBrowserModal

  setup :register_and_log_in_admin_user

  describe "provenance badge" do
    test "names the package that contributed a profile", %{conn: conn, scope: scope} do
      package = create_package(scope)
      profile = create_profile(scope, plugin_package_id: package.id, package_name: package.name)

      {:ok, _lv, html} = live(conn, ~p"/settings/snmp")

      assert html =~ "Plugin: #{package.name}"
      assert html =~ "snmp-profile-#{profile.id}-provenance"
    end

    test "an operator-authored profile carries no badge", %{conn: conn, scope: scope} do
      profile = create_profile(scope)

      {:ok, _lv, html} = live(conn, ~p"/settings/snmp")

      refute html =~ "snmp-profile-#{profile.id}-provenance"
    end

    # plugin_package_id is NILIFIEd when the package is deleted, so the id alone
    # cannot distinguish a removed package from an operator-authored row. The
    # qualified name is what survives.
    test "still attributes a profile whose package has been removed", %{conn: conn, scope: scope} do
      package = create_package(scope)
      _profile = create_profile(scope, plugin_package_id: package.id, package_name: package.name)

      Ash.destroy!(package, scope: scope)

      {:ok, _lv, html} = live(conn, ~p"/settings/snmp")

      assert html =~ "removed"
      assert html =~ package.name
    end
  end

  describe "no-credential warning" do
    # An enabled profile with no credential compiles to zero targets and
    # collects nothing, silently: every skip is a Logger.debug.
    test "flags an enabled profile that has no credential bound", %{conn: conn, scope: scope} do
      profile = create_profile(scope, enabled: true)

      {:ok, _lv, html} = live(conn, ~p"/settings/snmp")

      assert html =~ "snmp-profile-#{profile.id}-no-credential"
      assert html =~ "No credential"
    end

    test "does not flag an enabled profile that has one", %{conn: conn, scope: scope} do
      profile = create_profile(scope, enabled: true, community: "public")

      {:ok, _lv, html} = live(conn, ~p"/settings/snmp")

      refute html =~ "snmp-profile-#{profile.id}-no-credential"
    end

    # A disabled profile collecting nothing is the operator's intent, not a
    # problem to report.
    test "does not flag a disabled profile", %{conn: conn, scope: scope} do
      profile = create_profile(scope, enabled: false)

      {:ok, _lv, html} = live(conn, ~p"/settings/snmp")

      refute html =~ "snmp-profile-#{profile.id}-no-credential"
    end
  end

  describe "describe/2" do
    test "prefers the live package over the name it was created with" do
      row = %{plugin_package_id: "pkg-1", name: "plugin:Old Name:entry"}

      assert Provenance.describe(row, %{"pkg-1" => "Current Name"}) ==
               {:plugin, "Current Name"}
    end

    test "reports an unresolvable package id as removed rather than unattributed" do
      row = %{plugin_package_id: "pkg-gone", name: "plugin:ClearPass:node-health"}

      assert Provenance.describe(row, %{}) == {:plugin_removed, "ClearPass"}
    end

    test "keeps a colon in the entry name out of the package name" do
      row = %{plugin_package_id: nil, name: "plugin:ClearPass:node:health"}

      assert Provenance.describe(row, %{}) == {:plugin_removed, "ClearPass"}
    end

    test "treats an operator-authored name as unattributed" do
      assert Provenance.describe(%{plugin_package_id: nil, name: "Core switches"}, %{}) == :none
      assert Provenance.describe(%{plugin_package_id: nil, name: nil}, %{}) == :none
    end
  end

  test "template browser Custom tab badges a plugin-removed template" do
    template_id = Ecto.UUID.generate()

    html =
      render_component(&TemplateBrowserModal.template_browser_modal/1, %{
        search: "",
        selected_vendor: "custom",
        custom_templates: [
          %{
            id: template_id,
            name: "plugin:ClearPass:node-health",
            description: "Node health",
            vendor: "plugin",
            category: "system",
            oids: [%{"oid" => ".1.3.6.1.2.1.1.1.0"}],
            plugin_package_id: nil
          }
        ],
        package_names: %{}
      })

    assert html =~ "Plugin: ClearPass (removed)"
    assert html =~ "snmp-template-#{template_id}-provenance"
  end

  defp register_and_log_in_admin_user(%{conn: conn}) do
    user = AccountsFixtures.user_fixture(%{role: :admin})
    scope = Scope.for_user(user)

    %{conn: log_in_user(conn, user), user: user, scope: scope}
  end

  defp create_package(scope) do
    unique = System.unique_integer([:positive])
    plugin_id = "clearpass-policy-manager-#{unique}"
    name = "ClearPass Policy Manager #{unique}"

    {:ok, _plugin} =
      ServiceRadar.Plugins.Plugin
      |> Ash.Changeset.for_create(:create, %{plugin_id: plugin_id, name: name})
      |> Ash.create(scope: scope)

    {:ok, package} =
      PluginPackage
      |> Ash.Changeset.for_create(:create, %{
        plugin_id: plugin_id,
        name: name,
        version: "0.1.0",
        entrypoint: "run_check",
        runtime: "wasi-preview1",
        outputs: "serviceradar.plugin_result.v1",
        manifest: %{
          "id" => plugin_id,
          "name" => name,
          "version" => "0.1.0",
          "entrypoint" => "run_check",
          "runtime" => "wasi-preview1",
          "outputs" => "serviceradar.plugin_result.v1",
          "capabilities" => ["get_config", "log", "submit_result"],
          "resources" => %{"requested_memory_mb" => 32, "requested_cpu_ms" => 100}
        },
        content_hash: "sha256:provenance-#{unique}",
        source_type: :upload
      })
      |> Ash.create(scope: scope)

    package
  end

  defp create_profile(scope, opts \\ []) do
    unique = System.unique_integer([:positive])

    name =
      case Keyword.get(opts, :package_name) do
        nil -> "Operator Profile #{unique}"
        package -> "plugin:#{package}:node-health-#{unique}"
      end

    attrs =
      maybe_put(%{name: name, enabled: Keyword.get(opts, :enabled, false)}, :community, Keyword.get(opts, :community))

    changeset = Ash.Changeset.for_create(SNMPProfile, :create, attrs)

    changeset =
      case Keyword.get(opts, :plugin_package_id) do
        nil -> changeset
        id -> Ash.Changeset.force_change_attribute(changeset, :plugin_package_id, id)
      end

    {:ok, profile} = Ash.create(changeset, scope: scope)
    profile
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
