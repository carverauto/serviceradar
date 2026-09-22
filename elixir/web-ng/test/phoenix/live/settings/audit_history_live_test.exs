defmodule ServiceRadarWebNGWeb.Settings.AuditHistoryLiveTest do
  @moduledoc """
  Coverage for a user-reported set of bugs in Settings -> Audit -> History:

    * AshPaperTrail-only rows (e.g. AuthLockout, Controller, Playbook) never
      showed an Actor, because `version_action_inputs` never captured one --
      see `ServiceRadar.Security.Changes.StampAuditActor`.
    * A resolved actor rendered as a raw id/email rather than calling out a
      system/background actor explicitly.
    * Clicking a row appeared to do nothing, because the diff opened in an
      inline panel below a potentially long table rather than a modal.
  """

  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Security.AuditHistory
  alias ServiceRadar.Security.AuthLockout
  alias ServiceRadarWebNG.AccountsFixtures

  require Ash.Query

  setup :register_and_log_in_admin_user

  @path "/settings/audit/history"

  defp register_and_log_in_admin_user(%{conn: conn}) do
    user = AccountsFixtures.user_fixture(%{role: :admin})

    %{conn: log_in_user(conn, user), user: user}
  end

  defp lock_actor(actor_id, actor) do
    AuthLockout
    |> Ash.Changeset.for_create(
      :lock,
      %{actor_id: actor_id, reason: "audit history test lockout"},
      actor: actor
    )
    |> Ash.create!()
  end

  defp version_id_for(lockout) do
    [entry] =
      [resource_types: [AuthLockout], actor: system_actor()]
      |> AuditHistory.list_recent()
      |> Enum.filter(&(&1.version.version_source_id == lockout.id))

    entry.version.id
  end

  test "a plain-map actor (the real production shape) shows its email, not a raw id", %{
    conn: conn
  } do
    actor = admin_actor()
    lock_actor("locked-actor-#{System.unique_integer([:positive])}", actor)

    {:ok, _live, html} = live(conn, @path)

    assert html =~ actor.email
    refute html =~ actor.id
  end

  test "a system actor is called out explicitly instead of showing its raw id", %{conn: conn} do
    actor = SystemActor.system(:audit_history_test)
    lock_actor("locked-actor-#{System.unique_integer([:positive])}", actor)

    {:ok, _live, html} = live(conn, @path)

    assert html =~ "System · audit_history_test"
    refute html =~ actor.id
  end

  test "clicking a row opens a modal with the diff", %{conn: conn} do
    actor = admin_actor()
    lockout = lock_actor("locked-actor-#{System.unique_integer([:positive])}", actor)

    {:ok, live, _html} = live(conn, @path)

    refute has_element?(live, "#audit-history-version-modal")

    version_id = version_id_for(lockout)

    html =
      live
      |> element("tr[phx-value-id='#{version_id}']")
      |> render_click()

    assert html =~ ~s(id="audit-history-version-modal")
    assert html =~ "Changes"
    assert html =~ "Action inputs"
    assert html =~ lockout.reason
  end
end
