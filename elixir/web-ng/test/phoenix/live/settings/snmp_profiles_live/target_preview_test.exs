defmodule ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.TargetPreviewTest do
  @moduledoc """
  The settings preview counts a profile's `target_query` the way the
  compiler does: by executing the normalized SRQL query, not by
  reimplementing its filter tables.

  `Targeting` used to carry its own device/interface field maps and op
  clauses. Anything outside that subset -- `tags.*` filters (the spec's own
  `tags.role:core` example), `in:` lists, and other compiler-accepted
  filters -- fell through to `:unknown`, so the preview read "Unknown
  targets" for every narrowed query and the operator could not scope an
  over-limit profile down safely.
  """
  use ServiceRadarWebNG.DataCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  alias ServiceRadar.Inventory.Interface
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures
  alias ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Targeting

  @moduletag :web_ng_shared_fixture_db

  setup do
    user = AccountsFixtures.user_fixture()
    scope = Scope.for_user(user)

    alpha1 =
      device_fixture(%{
        uid: "snmp-preview-alpha-1",
        hostname: "snmp-preview-alpha-1.example.invalid",
        tags: %{"preview" => "core"}
      })

    alpha2 =
      device_fixture(%{
        uid: "snmp-preview-alpha-2",
        hostname: "snmp-preview-alpha-2.example.invalid",
        tags: %{"preview" => "core"}
      })

    _beta =
      device_fixture(%{
        uid: "snmp-preview-beta-1",
        hostname: "snmp-preview-beta-1.example.invalid",
        tags: %{"preview" => "edge"}
      })

    {:ok, scope: scope, alpha1: alpha1, alpha2: alpha2}
  end

  test "counts an unfiltered device query", %{scope: scope} do
    assert {:ok, 3} = Targeting.count_target_devices(scope, "in:devices")
  end

  test "counts an equality-filtered device query", %{scope: scope} do
    assert {:ok, 1} =
             Targeting.count_target_devices(
               scope,
               "in:devices hostname:snmp-preview-alpha-1.example.invalid"
             )
  end

  test "counts a tag-filtered device query", %{scope: scope} do
    assert {:ok, 2} =
             Targeting.count_target_devices(scope, "in:devices tags.preview:core")
  end

  test "counts a builder-style like-filtered device query", %{scope: scope} do
    assert {:ok, 2} =
             Targeting.count_target_devices(scope, "in:devices hostname:%snmp-preview-alpha%")
  end

  test "counts an in-list filtered device query", %{scope: scope} do
    assert {:ok, 2} =
             Targeting.count_target_devices(
               scope,
               "in:devices hostname:(snmp-preview-alpha-1.example.invalid,snmp-preview-alpha-2.example.invalid)"
             )
  end

  test "an unparseable query counts nothing, like the compiler", %{scope: scope} do
    assert {:ok, 0} = Targeting.count_target_devices(scope, "in:devices (((")
  end

  test "counts an interface query once per device", %{scope: scope, alpha1: alpha1} do
    for {uid, name} <- [{"ifindex:10", "snmp-preview-eth"}, {"ifindex:11", "snmp-preview-eth"}] do
      Interface
      |> Ash.Changeset.for_create(
        :create,
        %{device_id: alpha1.uid, interface_uid: uid, if_name: name, timestamp: DateTime.utc_now()},
        actor: system_actor()
      )
      |> Ash.create!()
    end

    assert {:ok, 1} =
             Targeting.count_target_devices(scope, "in:interfaces if_name:snmp-preview-eth")
  end

  test "format_target_count renders counts and unknown" do
    assert Targeting.format_target_count({:ok, 1}) == "1 target"
    assert Targeting.format_target_count({:ok, 3}) == "3 targets"
    assert Targeting.format_target_count(:unknown) == "Unknown"
  end
end
