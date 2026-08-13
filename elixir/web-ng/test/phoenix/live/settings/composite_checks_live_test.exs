defmodule ServiceRadarWebNGWeb.Settings.CompositeChecksLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadarWebNG.AccountsFixtures

  setup :register_and_log_in_admin_user

  @path "/settings/networks/composite-checks"

  defp register_and_log_in_admin_user(%{conn: conn}) do
    user = AccountsFixtures.user_fixture(%{role: :admin})

    %{conn: log_in_user(conn, user), user: user}
  end

  defp create_check(attrs) do
    defaults = %{
      name: "Live Check #{System.unique_integer([:positive])}",
      scope_query: "in:devices"
    }

    CompositeCheck
    |> Ash.Changeset.for_create(:create, Map.merge(defaults, attrs), actor: system_actor())
    |> Ash.create!()
  end

  describe "access" do
    test "renders for an admin", %{conn: conn} do
      {:ok, _live, html} = live(conn, @path)
      assert html =~ "Composite Checks"
    end

    test "renders for a viewer, who holds composite_checks.view", %{conn: conn} do
      viewer = AccountsFixtures.user_fixture(%{role: :viewer})

      {:ok, _live, html} = live(log_in_user(conn, viewer), @path)

      assert html =~ "Composite Checks"
    end
  end

  describe "index" do
    test "explains the liveness witness requirement when empty", %{conn: conn} do
      {:ok, _live, html} = live(conn, @path)

      # The empty state is the only place a first-time operator learns why one
      # vantage point is never enough.
      assert html =~ "powered-off device"
    end

    test "lists an existing check with its scope and state", %{conn: conn} do
      check = create_check(%{scope_query: "in:devices source:armis"})

      {:ok, _live, html} = live(conn, @path)

      assert html =~ check.name
      assert html =~ "in:devices source:armis"
      assert html =~ "draft"
    end

    test "a draft check says it has not been evaluated rather than showing a zero rollup", %{
      conn: conn
    } do
      create_check(%{})

      {:ok, _live, html} = live(conn, @path)

      # A rollup of zeros reads like a computed answer. "Not yet evaluated" is
      # the honest statement for a check that has never run.
      assert html =~ "Not yet evaluated"
    end

    test "renders verdict counts for a check with results", %{conn: conn} do
      check = create_check(%{})
      now = DateTime.utc_now()

      for {uid, verdict, status} <- [
            {"idx-a", "isolated_verified", :healthy},
            {"idx-b", "isolated_verified", :healthy},
            {"idx-c", "not_isolated", :down}
          ] do
        ServiceRadar.CompositeChecks.DeviceCompositeCheckResult
        |> Ash.Changeset.for_create(
          :upsert,
          %{
            device_uid: uid,
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

      {:ok, _live, html} = live(conn, @path)

      assert html =~ "isolated_verified"
      assert html =~ "not_isolated"
      refute html =~ "Not yet evaluated"
    end

    test "offers the new-check action to an operator", %{conn: conn} do
      {:ok, _live, html} = live(conn, @path)
      assert html =~ "New check"
    end
  end

  describe "manage-gated actions" do
    # Scope must come from the logged-in user: a LiveView resolves it through
    # the session on mount, so assigning :current_scope on the conn has no
    # effect on what the LiveView sees.
    test "a viewer is not offered the new-check action", %{conn: conn} do
      viewer = AccountsFixtures.user_fixture(%{role: :viewer})

      {:ok, _live, html} = live(log_in_user(conn, viewer), @path)

      refute html =~ "New check"
    end

    test "a viewer is redirected away from the new-check route", %{conn: conn} do
      viewer = AccountsFixtures.user_fixture(%{role: :viewer})

      # A push_patch issued during the initial mount surfaces to the test client
      # as a live_redirect rather than a patch.
      assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
               live(log_in_user(conn, viewer), @path <> "/new")

      assert to == @path
      assert flash["error"] =~ "do not have permission"
    end

    test "an admin can reach the new-check route", %{conn: conn} do
      {:ok, _live, html} = live(conn, @path <> "/new")

      assert html =~ "Composite Check"
    end
  end
end
