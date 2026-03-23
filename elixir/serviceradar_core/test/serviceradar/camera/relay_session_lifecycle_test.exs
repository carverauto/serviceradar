defmodule ServiceRadar.Camera.RelaySessionLifecycleTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Camera.RelaySessionLifecycle

  test "activates an opening relay session with media ingest metadata" do
    relay_session_id = Ecto.UUID.generate()
    parent = self()

    session_fetcher = fn ^relay_session_id, _actor ->
      {:ok, %{id: relay_session_id, status: :opening, media_ingest_id: nil}}
    end

    activator = fn session, attrs, _actor ->
      send(parent, {:activate, session.id, attrs})
      {:ok, session |> Map.merge(attrs) |> Map.put(:status, :active)}
    end

    assert {:ok, session} =
             RelaySessionLifecycle.activate_session(
               relay_session_id,
               "core-media-1",
               %{lease_expires_at_unix: 1_900_000_000},
               session_fetcher: session_fetcher,
               activator: activator
             )

    assert session.status == :active
    assert session.media_ingest_id == "core-media-1"
    assert_receive {:activate, ^relay_session_id, attrs}
    assert attrs.media_ingest_id == "core-media-1"
    assert %DateTime{} = attrs.lease_expires_at
  end

  test "renews lease on heartbeat for an active relay session" do
    relay_session_id = Ecto.UUID.generate()
    parent = self()

    session_fetcher = fn ^relay_session_id, _actor ->
      {:ok, %{id: relay_session_id, status: :active, media_ingest_id: "core-media-1"}}
    end

    renewer = fn session, attrs, _actor ->
      send(parent, {:renew_lease, session.id, attrs})
      {:ok, Map.merge(session, attrs)}
    end

    assert {:ok, _session} =
             RelaySessionLifecycle.heartbeat_session(
               relay_session_id,
               "core-media-1",
               %{lease_expires_at_unix: 1_900_000_010},
               session_fetcher: session_fetcher,
               renewer: renewer
             )

    assert_receive {:renew_lease, ^relay_session_id, %{lease_expires_at: %DateTime{}}}
  end

  test "marks a relay session closed with the media-plane reason" do
    relay_session_id = Ecto.UUID.generate()
    parent = self()

    session_fetcher = fn ^relay_session_id, _actor ->
      {:ok, %{id: relay_session_id, status: :active, media_ingest_id: "core-media-1"}}
    end

    closer = fn session, attrs, _actor ->
      send(parent, {:mark_closed, session.id, attrs})
      {:ok, session |> Map.merge(attrs) |> Map.put(:status, :closed)}
    end

    assert {:ok, session} =
             RelaySessionLifecycle.close_session(
               relay_session_id,
               "core-media-1",
               %{close_reason: "agent stopped relay"},
               session_fetcher: session_fetcher,
               closer: closer
             )

    assert session.status == :closed
    assert_receive {:mark_closed, ^relay_session_id, %{close_reason: "agent stopped relay"}}
  end

  test "returns not_found when the relay session does not exist" do
    relay_session_id = Ecto.UUID.generate()

    session_fetcher = fn ^relay_session_id, _actor -> {:ok, nil} end

    assert {:error, :not_found} =
             RelaySessionLifecycle.activate_session(
               relay_session_id,
               "core-media-1",
               %{},
               session_fetcher: session_fetcher
             )
  end

  test "rejects media ingest mismatches after activation" do
    relay_session_id = Ecto.UUID.generate()

    session_fetcher = fn ^relay_session_id, _actor ->
      {:ok, %{id: relay_session_id, status: :active, media_ingest_id: "core-media-1"}}
    end

    assert {:error, :media_ingest_mismatch} =
             RelaySessionLifecycle.heartbeat_session(
               relay_session_id,
               "core-media-2",
               %{lease_expires_at_unix: 1_900_000_010},
               session_fetcher: session_fetcher
             )
  end
end
