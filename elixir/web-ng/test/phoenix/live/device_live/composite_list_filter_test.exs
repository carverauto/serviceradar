defmodule ServiceRadarWebNGWeb.DeviceLive.CompositeListFilterTest do
  # Writes to shared tables; keep serial to avoid deadlocks in CNPG-backed tests.
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.CompositeChecks.CompositeCheckInput
  alias ServiceRadar.CompositeChecks.CompositeCheckRule
  alias ServiceRadar.CompositeChecks.DeviceCompositeCheckResult
  alias ServiceRadarWebNG.AccountsFixtures

  setup %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :admin})
    %{conn: log_in_user(conn, user)}
  end

  defp check_fixture(name) do
    CompositeCheck
    |> Ash.Changeset.for_create(
      :create,
      %{name: name, scope_query: "in:devices"},
      actor: system_actor()
    )
    |> Ash.create!()
  end

  defp rule_fixture(check, verdict, status) do
    CompositeCheckRule
    |> Ash.Changeset.for_create(
      :create,
      %{
        check_id: check.id,
        position: 0,
        match: %{"a" => "available"},
        verdict: verdict,
        verdict_label: verdict,
        status: status
      },
      actor: system_actor()
    )
    |> Ash.create!()
  end

  defp enable!(check) do
    # Enabling requires a liveness witness and coverage; the readiness gate is
    # Plan 1's and is exercised there. Here the state is set directly so the
    # list can be tested against an enabled check without standing up sweeps.
    CompositeCheckInput
    |> Ash.Changeset.for_create(
      :create,
      %{
        check_id: check.id,
        key: "solo",
        label: "solo",
        position: 0,
        kind: :vantage_point,
        expected: "available",
        config: %{"agent_id" => "solo"}
      },
      actor: system_actor()
    )
    |> Ash.create!()

    check
    |> Ash.Changeset.for_update(:enable, %{acknowledge_coverage_gap: true}, actor: system_actor())
    |> Ash.update!()
  end

  defp result_fixture(device, check, verdict, status) do
    now = DateTime.utc_now()

    DeviceCompositeCheckResult
    |> Ash.Changeset.for_create(
      :upsert,
      %{
        device_uid: device.uid,
        check_id: check.id,
        verdict: verdict,
        status: status,
        inputs: %{},
        evaluated_at: now,
        changed_at: now
      },
      actor: system_actor(),
      upsert?: true,
      upsert_identity: :unique_device_check
    )
    |> Ash.create!()
  end

  describe "verdict filter chips" do
    test "an enabled check's verdicts are offered as filters", %{conn: conn} do
      check = check_fixture("List Check #{System.unique_integer([:positive])}")
      rule_fixture(check, "isolated_verified", :healthy)
      rule_fixture(check, "not_isolated", :down)
      enable!(check)

      {:ok, _live, html} = live(conn, "/devices")

      assert html =~ "Composite verdict:"
      assert html =~ check.name
      assert html =~ "isolated_verified"
      assert html =~ "not_isolated"

      # The chip navigates to the same SRQL the query language accepts, so the
      # picker and the editor cannot offer different vocabularies.
      assert html =~ "composite.#{check.slug}%3Aisolated_verified"
    end

    test "a draft check is not offered", %{conn: conn} do
      check = check_fixture("Draft Check #{System.unique_integer([:positive])}")
      rule_fixture(check, "draft_only_verdict", :healthy)

      {:ok, _live, html} = live(conn, "/devices")

      # `composite.<slug>` matches nothing for a draft, so offering it would be
      # offering a filter guaranteed to return nothing.
      refute html =~ "draft_only_verdict"
    end

    test "an enabled check with no rules contributes no chips", %{conn: conn} do
      check = check_fixture("Ruleless #{System.unique_integer([:positive])}")
      enable!(check)

      {:ok, _live, html} = live(conn, "/devices")

      # Only the catch-all exists, and its verdict is a real one, so the check
      # itself still appears — what must not appear is a chip for a verdict no
      # rule produces.
      assert html =~ check.name
    end
  end

  describe "verdict column" do
    test "is absent on an unfiltered list", %{conn: conn} do
      check = check_fixture("Column Check #{System.unique_integer([:positive])}")
      rule_fixture(check, "isolated_verified", :healthy)
      enable!(check)

      device = device_fixture(%{})
      result_fixture(device, check, "isolated_verified", :healthy)

      {:ok, live, _html} = live(conn, "/devices")

      # Awaited rather than rendered immediately: the column is populated by the
      # enrichment task, so a refute before that task lands would pass whether
      # or not the column is suppressed.
      html = render_async(live, 15_000)

      # A device can hold a verdict for several checks at once, so "the" verdict
      # column is only well-defined once the list is narrowed to one check.
      refute html =~ "data-list-verdict"
      assert html =~ device.uid
    end

    test "appears and reports the verdict when filtering by that check", %{conn: conn} do
      check = check_fixture("Filtered Check #{System.unique_integer([:positive])}")
      rule_fixture(check, "not_isolated", :down)
      enable!(check)

      device = device_fixture(%{})
      result_fixture(device, check, "not_isolated", :down)

      {:ok, live, _html} =
        live(conn, "/devices?q=in:devices composite.#{check.slug}:not_isolated")

      # Enrichment runs in a start_async task against the shared fixture DB;
      # 100ms (the default) is not enough for a remote round trip.
      html = render_async(live, 15_000)

      assert html =~ ~s(data-list-verdict="not_isolated")
      assert html =~ ~s(data-list-status="down")
    end

    test "a status filter does not turn the verdict column on", %{conn: conn} do
      check = check_fixture("Status Filter #{System.unique_integer([:positive])}")
      rule_fixture(check, "not_isolated", :down)
      enable!(check)

      device = device_fixture(%{})
      result_fixture(device, check, "not_isolated", :down)

      {:ok, live, _html} =
        live(conn, "/devices?q=in:devices composite.#{check.slug}.status:down")

      # Enrichment runs in a start_async task against the shared fixture DB;
      # 100ms (the default) is not enough for a remote round trip.
      html = render_async(live, 15_000)

      # The status form names no verdict. Showing a verdict column for it would
      # claim a verdict the query never asked for.
      refute html =~ "data-list-verdict"
    end
  end
end
