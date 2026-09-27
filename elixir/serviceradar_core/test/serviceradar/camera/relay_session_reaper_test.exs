defmodule ServiceRadar.Camera.RelaySessionReaperTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Camera.RelaySessionReaper

  @now ~U[2026-09-27 01:00:00.000000Z]

  defp session(status, attrs \\ %{}) do
    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        status: status,
        lease_expires_at: DateTime.add(@now, -3600),
        inserted_at: DateTime.add(@now, -7200),
        close_reason: nil
      },
      attrs
    )
  end

  defp reap(sessions, closer) do
    lister = fn _lease_cutoff, _unleased_cutoff, _batch, _actor -> {:ok, sessions} end
    RelaySessionReaper.reap(now: @now, lister: lister, closer: closer, actor: :test_actor)
  end

  defp recording_closer(parent, result \\ :ok) do
    fn session, attrs, lease_cutoff, _actor ->
      send(parent, {:close, session.id, attrs, lease_cutoff})

      case result do
        :ok -> {:ok, session}
        other -> other
      end
    end
  end

  test "closes an active session whose lease lapsed long ago" do
    stuck = session(:active)

    assert {:ok, %{closed: 1, skipped: 0, failed: 0}} = reap([stuck], recording_closer(self()))

    assert_receive {:close, id, attrs, lease_cutoff}
    assert id == stuck.id
    assert attrs == %{close_reason: "relay lease expired", viewer_count: 0}
    assert lease_cutoff == DateTime.add(@now, -120)
  end

  test "leaves a session whose lease is still renewing" do
    live = session(:active, %{lease_expires_at: DateTime.add(@now, 20)})
    just_lapsed = session(:active, %{lease_expires_at: DateTime.add(@now, -60)})

    assert {:ok, %{closed: 0}} = reap([live, just_lapsed], recording_closer(self()))
    refute_receive {:close, _id, _attrs, _cutoff}
  end

  test "keeps the close reason of a session stuck in closing" do
    stuck = session(:closing, %{close_reason: "viewer idle timeout"})

    assert {:ok, %{closed: 1}} = reap([stuck], recording_closer(self()))
    assert_receive {:close, _id, attrs, _cutoff}
    assert attrs == %{viewer_count: 0}
  end

  test "judges sessions that never received a lease by age" do
    old = session(:requested, %{lease_expires_at: nil, inserted_at: DateTime.add(@now, -3600)})
    fresh = session(:requested, %{lease_expires_at: nil, inserted_at: DateTime.add(@now, -30)})

    assert {:ok, %{closed: 1}} = reap([old, fresh], recording_closer(self()))
    assert_receive {:close, id, _attrs, _cutoff}
    assert id == old.id
    refute_receive {:close, _id, _attrs, _cutoff}
  end

  test "never touches terminal sessions" do
    assert {:ok, %{closed: 0}} =
             reap([session(:closed), session(:failed)], recording_closer(self()))

    refute_receive {:close, _id, _attrs, _cutoff}
  end

  test "counts a session renewed between read and update as skipped" do
    closer = recording_closer(self(), {:skip, :renewed_or_changed})

    assert {:ok, %{closed: 0, skipped: 1, failed: 0}} = reap([session(:active)], closer)
  end

  test "counts a failed close without aborting the batch" do
    first = session(:active)
    second = session(:opening)
    parent = self()

    closer = fn s, _attrs, _cutoff, _actor ->
      send(parent, {:attempt, s.id})
      if s.id == first.id, do: {:error, :db_unavailable}, else: {:ok, s}
    end

    assert {:ok, %{closed: 1, failed: 1}} = reap([first, second], closer)
    assert_receive {:attempt, _}
    assert_receive {:attempt, _}
  end

  test "propagates a listing error" do
    lister = fn _lease_cutoff, _unleased_cutoff, _batch, _actor -> {:error, :query_failed} end

    assert {:error, :query_failed} =
             RelaySessionReaper.reap(now: @now, lister: lister, closer: recording_closer(self()))
  end
end
