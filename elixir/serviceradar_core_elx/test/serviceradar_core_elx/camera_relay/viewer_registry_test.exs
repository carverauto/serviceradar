defmodule ServiceRadarCoreElx.CameraRelay.ViewerRegistryTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Camera.RelayPubSub
  alias ServiceRadarCoreElx.CameraRelay.ViewerRegistry

  defmodule RelaySessionCloserStub do
    @moduledoc false

    def request_close(relay_session_id, opts) do
      send(opts[:test_pid], {:request_close, relay_session_id, opts})
      {:ok, %{id: relay_session_id, status: Keyword.get(opts, :status, :closing)}}
    end
  end

  defmodule ScriptedRelaySessionCloserStub do
    @moduledoc false

    def request_close(relay_session_id, opts) do
      send(opts[:test_pid], {:request_close, relay_session_id, opts})
      opts[:close_result].(relay_session_id)
    end
  end

  defmodule RaisingRelaySessionCloserStub do
    @moduledoc false

    def request_close(relay_session_id, opts) do
      send(opts[:test_pid], {:request_close, relay_session_id, opts})

      raise KeyError,
        key: :field,
        term: [required_message: "is required", no_password_message: nil]
    end
  end

  defmodule SessionTrackerStub do
    @moduledoc false

    def sync_viewer_count(relay_session_id, viewer_count, attrs \\ %{}) do
      send(test_pid(), {:sync_viewer_count, relay_session_id, viewer_count})

      if attrs[:released_viewer_id] do
        send(test_pid(), {:released_viewer, relay_session_id, attrs.released_viewer_id})
      end

      :ok
    end

    def mark_closing(relay_session_id, attrs) do
      send(test_pid(), {:mark_closing, relay_session_id, attrs})
      :ok
    end

    def fetch_session(relay_session_id) do
      send(test_pid(), {:fetch_session, relay_session_id})
      %{relay_session_id: relay_session_id, status: "active"}
    end

    defp test_pid do
      Application.fetch_env!(:serviceradar_core_elx, :camera_relay_viewer_registry_test_pid)
    end
  end

  defmodule DroppedSessionTrackerStub do
    @moduledoc false

    defdelegate sync_viewer_count(relay_session_id, viewer_count), to: SessionTrackerStub
    defdelegate sync_viewer_count(relay_session_id, viewer_count, attrs), to: SessionTrackerStub
    defdelegate mark_closing(relay_session_id, attrs), to: SessionTrackerStub

    def fetch_session(relay_session_id) do
      send(test_pid(), {:dropped_session, relay_session_id})
      nil
    end

    defp test_pid do
      Application.fetch_env!(:serviceradar_core_elx, :camera_relay_viewer_registry_test_pid)
    end
  end

  defmodule NonOwnerSessionTrackerStub do
    @moduledoc false

    defdelegate sync_viewer_count(relay_session_id, viewer_count), to: SessionTrackerStub
    defdelegate sync_viewer_count(relay_session_id, viewer_count, attrs), to: SessionTrackerStub
    defdelegate mark_closing(relay_session_id, attrs), to: SessionTrackerStub

    def fetch_session(relay_session_id) do
      send(test_pid(), {:fetch_session, relay_session_id})
      nil
    end

    defp test_pid do
      Application.fetch_env!(:serviceradar_core_elx, :camera_relay_viewer_registry_test_pid)
    end
  end

  setup_all do
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)

    if !Process.whereis(ServiceRadar.PubSub) do
      start_supervised!({Phoenix.PubSub, name: ServiceRadar.PubSub})
    end

    if !Process.whereis(ViewerRegistry) do
      start_supervised!(ViewerRegistry)
    end

    :ok
  end

  setup do
    previous_state =
      ViewerRegistry
      |> :sys.get_state()
      |> cancel_close_timers()

    test_pid = self()

    previous_tracker_test_pid =
      Application.get_env(:serviceradar_core_elx, :camera_relay_viewer_registry_test_pid)

    Application.put_env(:serviceradar_core_elx, :camera_relay_viewer_registry_test_pid, test_pid)

    :sys.replace_state(ViewerRegistry, fn state ->
      state
      |> Map.put(:viewers, %{})
      |> Map.put(:close_timers, %{})
      |> Map.put(:idle_close_ms, 25)
      |> Map.put(:session_closer, RelaySessionCloserStub)
      |> Map.put(:session_closer_opts, test_pid: test_pid)
      |> Map.put(:session_tracker, SessionTrackerStub)
    end)

    on_exit(fn ->
      restore_env(:camera_relay_viewer_registry_test_pid, previous_tracker_test_pid)

      ViewerRegistry
      |> :sys.get_state()
      |> cancel_close_timers()

      :sys.replace_state(ViewerRegistry, fn _state -> previous_state end)
    end)

    :ok
  end

  test "fans chunks out and reports viewer counts while the registry process is busy" do
    relay_session_id = "relay-viewers-busy-#{System.unique_integer([:positive])}"
    viewer_id = "viewer-busy"

    :ok = RelayPubSub.subscribe_viewer(relay_session_id, viewer_id)
    :ok = RelayPubSub.viewer_join(relay_session_id, viewer_id)
    _ = :sys.get_state(ViewerRegistry)
    assert_receive {:sync_viewer_count, ^relay_session_id, 1}

    # Stand-in for a registry mailbox backed up behind other cameras' work.
    :ok = :sys.suspend(ViewerRegistry)

    try do
      count = Task.async(fn -> ViewerRegistry.viewer_count(relay_session_id) end)
      assert Task.yield(count, 500) == {:ok, 1}

      ViewerRegistry.broadcast_chunk(relay_session_id, %{
        media_ingest_id: "core-media-busy",
        sequence: 1,
        payload: <<9>>
      })

      assert_receive {:camera_relay_viewer_chunk,
                      %{relay_session_id: ^relay_session_id, viewer_id: ^viewer_id, sequence: 1}},
                     500
    after
      :sys.resume(ViewerRegistry)
    end

    :ok = RelayPubSub.viewer_leave(relay_session_id, viewer_id)
    _ = :sys.get_state(ViewerRegistry)
  end

  test "fans chunks only to registered viewers for a relay session" do
    relay_session_id = "relay-viewers-1"
    viewer_a = "viewer-a"
    viewer_b = "viewer-b"

    :ok = RelayPubSub.subscribe_viewer(relay_session_id, viewer_a)
    :ok = RelayPubSub.subscribe_viewer(relay_session_id, viewer_b)

    :ok = RelayPubSub.viewer_join(relay_session_id, viewer_a)
    :ok = RelayPubSub.viewer_join(relay_session_id, viewer_b)
    _ = :sys.get_state(ViewerRegistry)

    assert_receive {:sync_viewer_count, ^relay_session_id, 1}
    assert_receive {:sync_viewer_count, ^relay_session_id, 2}

    ViewerRegistry.broadcast_chunk(relay_session_id, %{
      media_ingest_id: "core-media-1",
      sequence: 5,
      payload: <<1, 2, 3>>
    })

    assert_receive {:camera_relay_viewer_chunk, %{viewer_id: ^viewer_a, sequence: 5, payload: <<1, 2, 3>>}}

    assert_receive {:camera_relay_viewer_chunk, %{viewer_id: ^viewer_b, sequence: 5, payload: <<1, 2, 3>>}}

    assert ViewerRegistry.viewer_count(relay_session_id) == 2

    :ok = RelayPubSub.viewer_leave(relay_session_id, viewer_b)
    _ = :sys.get_state(ViewerRegistry)
    assert_receive {:sync_viewer_count, ^relay_session_id, 1}

    ViewerRegistry.broadcast_chunk(relay_session_id, %{
      media_ingest_id: "core-media-1",
      sequence: 6,
      payload: <<4, 5, 6>>
    })

    assert_receive {:camera_relay_viewer_chunk, %{viewer_id: ^viewer_a, sequence: 6, payload: <<4, 5, 6>>}}

    refute_receive {:camera_relay_viewer_chunk, %{viewer_id: ^viewer_b, sequence: 6, payload: <<4, 5, 6>>}},
                   100

    assert ViewerRegistry.viewer_count(relay_session_id) == 1
  end

  test "requests relay close after idle timeout when the last viewer leaves" do
    relay_session_id = "relay-idle-close-1"
    viewer_id = "viewer-idle-close-1"

    :ok = RelayPubSub.subscribe_viewer(relay_session_id, viewer_id)
    :ok = RelayPubSub.viewer_join(relay_session_id, viewer_id)
    _ = :sys.get_state(ViewerRegistry)

    :ok = RelayPubSub.viewer_leave(relay_session_id, viewer_id)

    assert_receive {:sync_viewer_count, ^relay_session_id, 0}
    assert_receive {:request_close, ^relay_session_id, opts}, 500
    assert opts[:reason] == "viewer idle timeout"
    assert opts[:test_pid] == self()
    assert_receive {:released_viewer, ^relay_session_id, ^viewer_id}
    assert_receive {:mark_closing, ^relay_session_id, %{close_reason: "viewer idle timeout", viewer_count: 0}}
  end

  test "a retained ingest is not marked closing and idle close retries after consumers drain" do
    relay_session_id = "relay-retained-example"
    viewer_id = "viewer-retained-example"
    test_pid = self()

    :sys.replace_state(ViewerRegistry, fn state ->
      %{state | session_closer_opts: [test_pid: test_pid, status: :active]}
    end)

    :ok = RelayPubSub.viewer_join(relay_session_id, viewer_id)
    :ok = RelayPubSub.viewer_leave(relay_session_id, viewer_id)
    assert_receive {:request_close, ^relay_session_id, _}, 500
    refute_receive {:mark_closing, ^relay_session_id, _}, 50

    :sys.replace_state(ViewerRegistry, fn state ->
      %{state | session_closer_opts: [test_pid: test_pid, status: :closing]}
    end)

    assert_receive {:mark_closing, ^relay_session_id, _}, 500
  end

  test "does not crash when idle close raises during a stale relay transition" do
    relay_session_id = "relay-idle-close-raises-1"
    viewer_id = "viewer-idle-close-raises-1"

    :sys.replace_state(ViewerRegistry, fn state ->
      Map.put(state, :session_closer, RaisingRelaySessionCloserStub)
    end)

    :ok = RelayPubSub.subscribe_viewer(relay_session_id, viewer_id)
    :ok = RelayPubSub.viewer_join(relay_session_id, viewer_id)
    _ = :sys.get_state(ViewerRegistry)

    :ok = RelayPubSub.viewer_leave(relay_session_id, viewer_id)

    assert_receive {:sync_viewer_count, ^relay_session_id, 0}
    assert_receive {:request_close, ^relay_session_id, opts}, 500
    assert opts[:reason] == "viewer idle timeout"
    assert ViewerRegistry.viewer_count(relay_session_id) == 0
    refute_receive {:mark_closing, ^relay_session_id, _attrs}, 50
  end

  test "only the core replica that owns the relay session requests idle close" do
    relay_session_id = "relay-non-owner-idle-close-1"
    viewer_id = "viewer-non-owner-idle-close-1"

    :sys.replace_state(ViewerRegistry, fn state ->
      Map.put(state, :session_tracker, NonOwnerSessionTrackerStub)
    end)

    :ok = RelayPubSub.subscribe_viewer(relay_session_id, viewer_id)
    :ok = RelayPubSub.viewer_join(relay_session_id, viewer_id)
    _ = :sys.get_state(ViewerRegistry)

    :ok = RelayPubSub.viewer_leave(relay_session_id, viewer_id)

    assert_receive {:sync_viewer_count, ^relay_session_id, 0}
    assert_receive {:fetch_session, ^relay_session_id}, 500
    refute_receive {:request_close, ^relay_session_id, _opts}, 100
    refute_receive {:mark_closing, ^relay_session_id, _attrs}, 50
  end

  test "retries idle close after a transient refusal and does not retry a missing relay" do
    refused = "relay-idle-transient-#{System.unique_integer([:positive])}"
    missing = "relay-idle-missing-#{System.unique_integer([:positive])}"
    test_pid = self()
    {:ok, script} = Agent.start_link(fn -> :refuse end)
    on_exit(fn -> if Process.alive?(script), do: Agent.stop(script) end)

    :sys.replace_state(ViewerRegistry, fn state ->
      %{
        state
        | session_closer: ScriptedRelaySessionCloserStub,
          session_closer_opts: [
            test_pid: test_pid,
            close_result: fn relay_session_id ->
              if relay_session_id == missing do
                {:error, :not_found}
              else
                Agent.get_and_update(script, fn
                  :refuse ->
                    {{:error, :ambiguous_live_relays}, :close}

                  :close ->
                    {{:ok,
                      %{
                        id: relay_session_id,
                        status: :closing,
                        close_reason: "viewer idle timeout"
                      }}, :close}
                end)
              end
            end
          ]
      }
    end)

    :ok = RelayPubSub.viewer_join(refused, "viewer-transient")
    :ok = RelayPubSub.viewer_leave(refused, "viewer-transient")
    assert_receive {:request_close, ^refused, _opts}, 500
    assert_receive {:request_close, ^refused, _opts}, 500

    assert_receive {:mark_closing, ^refused, %{close_reason: "viewer idle timeout", viewer_count: 0}}

    :ok = RelayPubSub.viewer_join(missing, "viewer-missing")
    :ok = RelayPubSub.viewer_leave(missing, "viewer-missing")
    assert_receive {:request_close, ^missing, _opts}, 500
    refute_receive {:request_close, ^missing, _opts}, 200
    refute_receive {:mark_closing, ^missing, _attrs}, 50
  end

  test "a raised or exited idle close retries once and a viewer join cancels that retry" do
    raised = "relay-idle-raise-#{System.unique_integer([:positive])}"
    exited = "relay-idle-exit-#{System.unique_integer([:positive])}"
    cancelled = "relay-idle-cancel-failure-#{System.unique_integer([:positive])}"
    test_pid = self()

    {:ok, script} =
      Agent.start_link(fn -> %{raised => :fail, exited => :fail, cancelled => :fail} end)

    on_exit(fn -> if Process.alive?(script), do: Agent.stop(script) end)

    :sys.replace_state(ViewerRegistry, fn state ->
      %{
        state
        | idle_close_ms: 200,
          session_closer: ScriptedRelaySessionCloserStub,
          session_closer_opts: [
            test_pid: test_pid,
            close_result: fn relay_session_id ->
              phase =
                Agent.get_and_update(script, fn phases ->
                  {Map.get(phases, relay_session_id, :close), Map.put(phases, relay_session_id, :close)}
                end)

              case phase do
                :fail when relay_session_id == raised ->
                  raise "connection not available"

                :fail when relay_session_id == exited ->
                  exit(:db_connection_lost)

                :fail ->
                  raise "connection not available"

                :close ->
                  {:ok,
                   %{
                     id: relay_session_id,
                     status: :closing,
                     close_reason: "viewer idle timeout"
                   }}
              end
            end
          ]
      }
    end)

    :ok = RelayPubSub.viewer_join(raised, "viewer-raise")
    :ok = RelayPubSub.viewer_leave(raised, "viewer-raise")
    assert_receive {:request_close, ^raised, _opts}, 500
    assert_receive {:request_close, ^raised, _opts}, 500
    assert_receive {:mark_closing, ^raised, %{close_reason: "viewer idle timeout", viewer_count: 0}}

    :ok = RelayPubSub.viewer_join(exited, "viewer-exit")
    :ok = RelayPubSub.viewer_leave(exited, "viewer-exit")
    assert_receive {:request_close, ^exited, _opts}, 500
    assert_receive {:request_close, ^exited, _opts}, 500
    assert_receive {:mark_closing, ^exited, %{close_reason: "viewer idle timeout", viewer_count: 0}}

    :ok = RelayPubSub.viewer_join(cancelled, "viewer-cancel-failure")
    :ok = RelayPubSub.viewer_leave(cancelled, "viewer-cancel-failure")
    assert_receive {:request_close, ^cancelled, _opts}, 500
    :ok = RelayPubSub.viewer_join(cancelled, "viewer-cancel-failure")
    refute_receive {:request_close, ^cancelled, _opts}, 400
    refute_receive {:mark_closing, ^cancelled, _attrs}, 50
    assert ViewerRegistry.viewer_count(cancelled) == 1
  end

  test "a viewer join or a lost local session cancels the idle-close retry" do
    relay_session_id = "relay-idle-cancel-retry-#{System.unique_integer([:positive])}"
    viewer_id = "viewer-cancel-retry"
    untracked = "relay-idle-untracked-#{System.unique_integer([:positive])}"
    test_pid = self()

    scripted = fn _relay_session_id -> {:error, :ambiguous_live_relays} end

    :sys.replace_state(ViewerRegistry, fn state ->
      %{
        state
        | idle_close_ms: 200,
          session_closer: ScriptedRelaySessionCloserStub,
          session_closer_opts: [test_pid: test_pid, close_result: scripted]
      }
    end)

    :ok = RelayPubSub.viewer_join(relay_session_id, viewer_id)
    :ok = RelayPubSub.viewer_leave(relay_session_id, viewer_id)
    assert_receive {:request_close, ^relay_session_id, _opts}, 500
    :ok = RelayPubSub.viewer_join(relay_session_id, viewer_id)
    refute_receive {:request_close, ^relay_session_id, _opts}, 400
    assert ViewerRegistry.viewer_count(relay_session_id) == 1

    :ok = RelayPubSub.viewer_join(untracked, "viewer-untracked")
    :ok = RelayPubSub.viewer_leave(untracked, "viewer-untracked")
    assert_receive {:request_close, ^untracked, _opts}, 500
    flush_registry(untracked)

    :sys.replace_state(ViewerRegistry, fn state ->
      %{state | session_tracker: DroppedSessionTrackerStub}
    end)

    assert_receive {:dropped_session, ^untracked}, 500
    refute_receive {:request_close, ^untracked, _opts}, 50
  end

  test "cancels idle close if a viewer rejoins before timeout" do
    relay_session_id = "relay-idle-cancel-1"
    viewer_id = "viewer-idle-cancel-1"

    :ok = RelayPubSub.subscribe_viewer(relay_session_id, viewer_id)
    :ok = RelayPubSub.viewer_join(relay_session_id, viewer_id)
    _ = :sys.get_state(ViewerRegistry)

    :ok = RelayPubSub.viewer_leave(relay_session_id, viewer_id)
    :ok = RelayPubSub.viewer_join(relay_session_id, viewer_id)

    assert_receive {:sync_viewer_count, ^relay_session_id, 1}
    assert_receive {:sync_viewer_count, ^relay_session_id, 0}
    assert_receive {:sync_viewer_count, ^relay_session_id, 1}
    refute_receive {:request_close, ^relay_session_id, _opts}, 200
    refute_receive {:mark_closing, ^relay_session_id, _attrs}, 50
  end

  defp flush_registry(relay_session_id) do
    receive do
      {:fetch_session, ^relay_session_id} -> flush_registry(relay_session_id)
      {:sync_viewer_count, ^relay_session_id, _count} -> flush_registry(relay_session_id)
      {:released_viewer, ^relay_session_id, _viewer_id} -> flush_registry(relay_session_id)
    after
      0 -> :ok
    end
  end

  defp cancel_close_timers(state) do
    Enum.each(Map.values(Map.get(state, :close_timers, %{})), &Process.cancel_timer/1)
    Map.put(state, :close_timers, %{})
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core_elx, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core_elx, key, value)
end
