defmodule ServiceRadar.Camera.RelaySessionReaperIntegrationTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.RelaySession
  alias ServiceRadar.Camera.RelaySessionReaper
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Camera.StreamProfile

  @moduletag :integration

  setup do
    actor = SystemActor.system(:relay_session_reaper_integration_test)
    unique = System.unique_integer([:positive])

    {:ok, source} =
      Source.create_source(
        %{
          device_uid: "sr:reaper-test-#{unique}",
          vendor: "acme",
          vendor_camera_id: "cam-#{unique}"
        },
        actor: actor
      )

    {:ok, profile} =
      StreamProfile.create_profile(
        %{camera_source_id: source.id, profile_name: "main-#{unique}"},
        actor: actor
      )

    %{actor: actor, source: source, profile: profile}
  end

  defp create_session(ctx, status, lease_offset_seconds) do
    now = DateTime.utc_now()
    lease = lease_offset_seconds && DateTime.add(now, lease_offset_seconds)

    {:ok, session} =
      RelaySession.create_session(
        %{
          camera_source_id: ctx.source.id,
          stream_profile_id: ctx.profile.id,
          agent_id: "agent-test",
          gateway_id: "gateway-test",
          lease_expires_at: lease
        },
        actor: ctx.actor
      )

    advance(session, status, ctx.actor)
  end

  defp advance(session, :requested, _actor), do: session

  defp advance(session, :opening, actor) do
    {:ok, session} = RelaySession.mark_opening(session, %{}, actor: actor)
    session
  end

  defp advance(session, :active, actor) do
    {:ok, session} = RelaySession.activate(session, %{}, actor: actor)
    session
  end

  defp advance(session, :closing, actor) do
    {:ok, session} =
      RelaySession.request_close(session, %{close_reason: "viewer idle timeout"}, actor: actor)

    session
  end

  defp advance(session, :closed, actor) do
    {:ok, session} = RelaySession.mark_closed(session, %{}, actor: actor)
    session
  end

  defp reload(session, actor) do
    {:ok, session} = RelaySession.get_by_id(session.id, actor: actor)
    session
  end

  test "closes stuck live sessions and leaves live, fresh and terminal ones alone", ctx do
    stuck_active = create_session(ctx, :active, -3600)
    stuck_opening = create_session(ctx, :opening, -3600)
    stuck_requested = create_session(ctx, :requested, -3600)
    stuck_closing = create_session(ctx, :closing, -3600)
    live = create_session(ctx, :active, 20)
    just_lapsed = create_session(ctx, :active, -60)
    unleased_fresh = create_session(ctx, :requested, nil)
    already_closed = create_session(ctx, :closed, -3600)

    assert {:ok, %{closed: closed, failed: 0}} = RelaySessionReaper.reap(actor: ctx.actor)
    assert closed >= 4

    for stuck <- [stuck_active, stuck_opening, stuck_requested] do
      reaped = reload(stuck, ctx.actor)
      assert reaped.status == :closed
      assert reaped.close_reason == "relay lease expired"
      assert reaped.viewer_count == 0
      assert %DateTime{} = reaped.closed_at
    end

    reaped_closing = reload(stuck_closing, ctx.actor)
    assert reaped_closing.status == :closed
    assert reaped_closing.close_reason == "viewer idle timeout"

    for untouched <- [live, just_lapsed, unleased_fresh] do
      assert reload(untouched, ctx.actor).status == untouched.status
    end

    assert reload(already_closed, ctx.actor).close_reason == already_closed.close_reason
  end

  test "judges sessions that never received a lease by age", ctx do
    unleased = create_session(ctx, :requested, nil)

    assert {:ok, _result} = RelaySessionReaper.reap(actor: ctx.actor)
    assert reload(unleased, ctx.actor).status == :requested

    later = DateTime.add(DateTime.utc_now(), 3600)
    assert {:ok, _result} = RelaySessionReaper.reap(actor: ctx.actor, now: later)

    reaped = reload(unleased, ctx.actor)
    assert reaped.status == :closed
    assert reaped.close_reason == "relay lease expired"
  end

  test "skips a session whose lease was renewed between the read and the close", ctx do
    stuck = create_session(ctx, :active, -3600)
    snapshot = reload(stuck, ctx.actor)

    {:ok, _renewed} =
      RelaySession.renew_lease(
        stuck,
        %{lease_expires_at: DateTime.add(DateTime.utc_now(), 30), viewer_count: 1},
        actor: ctx.actor
      )

    lister = fn _lease_cutoff, _unleased_cutoff, _batch, _actor -> {:ok, [snapshot]} end

    assert {:ok, %{closed: 0, skipped: 1, failed: 0}} =
             RelaySessionReaper.reap(actor: ctx.actor, lister: lister)

    survivor = reload(stuck, ctx.actor)
    assert survivor.status == :active
    assert survivor.viewer_count == 1
  end

  test "skips a session that already left the status it was read in", ctx do
    stuck = create_session(ctx, :active, -3600)
    snapshot = reload(stuck, ctx.actor)

    {:ok, _closing} =
      RelaySession.request_close(stuck, %{close_reason: "viewer requested"}, actor: ctx.actor)

    lister = fn _lease_cutoff, _unleased_cutoff, _batch, _actor -> {:ok, [snapshot]} end

    assert {:ok, %{closed: 0, skipped: 1, failed: 0}} =
             RelaySessionReaper.reap(actor: ctx.actor, lister: lister)

    assert reload(stuck, ctx.actor).status == :closing
  end
end
