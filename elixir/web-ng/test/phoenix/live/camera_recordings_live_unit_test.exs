defmodule ServiceRadarWebNGWeb.CameraRecordingsLiveUnitTest do
  use ExUnit.Case, async: false

  import Phoenix.Component, only: [assign: 2, assign: 3]

  alias Phoenix.LiveView.Socket
  alias ServiceRadar.Camera.RecordingPubSub
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.CameraLive.Recordings

  @moduletag :db_free

  @camera_id "00000000-0000-4000-8000-000000000601"
  @other_camera_id "00000000-0000-4000-8000-000000000602"
  @profile_id "00000000-0000-4000-8000-000000000610"
  @base_now_us 1_763_164_800_000_000
  @hour_us 3_600_000_000

  describe "disconnected mount and handle_params iron laws" do
    test "does not subscribe to PubSub, schedule timers, or query the database when disconnected" do
      forbidden_deps = %{
        authorize_timeline_view: fn _ -> flunk("disconnected mount/params must not authorize via DB") end,
        has_timeline_data?: fn _, _ -> flunk("disconnected mount/params must not query timeline") end,
        coverage: fn _, _, _ -> flunk("disconnected mount/params must not load coverage") end,
        list_relay_profiles: fn _, _ -> flunk("disconnected mount/params must not list profiles") end,
        list_holds: fn _, _ -> flunk("disconnected mount/params must not list holds") end,
        list_event_clips: fn _, _, _ -> flunk("disconnected mount/params must not list clips") end,
        subscribe: fn _ -> flunk("disconnected mount/params must not subscribe to PubSub") end,
        unsubscribe: fn _ -> flunk("disconnected mount/params must not unsubscribe from PubSub") end
      }

      socket =
        [connected?: false]
        |> base_socket()
        |> assign(:recordings_deps, forbidden_deps)

      assert {:ok, mounted} = Recordings.mount(%{"camera_source_id" => @camera_id}, %{}, socket)
      assert mounted.assigns.recording_subscribed_source_id == nil
      assert mounted.assigns.recording_refresh_timer_ref == nil

      assert {:noreply, after_params} =
               Recordings.handle_params(
                 %{"camera_source_id" => @camera_id, "mode" => "timeline"},
                 "/cameras/#{@camera_id}/recordings?mode=timeline",
                 mounted
               )

      assert after_params.assigns.recording_subscribed_source_id == nil
      assert after_params.assigns.recording_refresh_timer_ref == nil
      assert after_params.assigns.recording_debounce_timer_ref == nil
    end
  end

  describe "connected subscription and timer lifecycle" do
    test "subscribes to camera topic, schedules periodic refresh, and cleanly switches cameras on handle_params" do
      parent = self()

      deps =
        stub_deps(%{
          subscribe: fn id ->
            send(parent, {:subscribed, id})
            :ok
          end,
          unsubscribe: fn id ->
            send(parent, {:unsubscribed, id})
            :ok
          end,
          coverage: fn source_id, params, _scope ->
            {:ok, empty_coverage(source_id, params.from_us, params.to_us)}
          end
        })

      socket = mount_connected(@camera_id, deps, refresh_interval_ms: 15_000, debounce_ms: 500)
      on_exit(fn -> cancel_timers(socket) end)

      assert_receive {:subscribed, @camera_id}
      assert socket.assigns.recording_subscribed_source_id == @camera_id
      first_timer = socket.assigns.recording_refresh_timer_ref
      assert is_reference(first_timer)

      # Navigating to a second camera unsubscribes from the first and replaces the timer.
      {:noreply, switched} =
        Recordings.handle_params(
          %{"camera_source_id" => @other_camera_id, "mode" => "timeline"},
          "/cameras/#{@other_camera_id}/recordings?mode=timeline",
          socket
        )

      on_exit(fn -> cancel_timers(switched) end)

      assert_receive {:unsubscribed, @camera_id}
      assert_receive {:subscribed, @other_camera_id}
      assert switched.assigns.recording_subscribed_source_id == @other_camera_id
      assert is_reference(switched.assigns.recording_refresh_timer_ref)
      refute switched.assigns.recording_refresh_timer_ref == first_timer
      assert Process.read_timer(first_timer) == false
    end

    test "coalesces rapid PubSub bursts via debounce timer and ignores other cameras" do
      {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)

      if Process.whereis(ServiceRadar.PubSub) == nil do
        start_supervised!({Phoenix.PubSub, name: ServiceRadar.PubSub})
      end

      parent = self()

      deps =
        stub_deps(%{
          coverage: fn source_id, params, _scope ->
            send(parent, {:coverage_loaded, source_id, params.to_us})
            {:ok, empty_coverage(source_id, params.from_us, params.to_us)}
          end
        })

      socket = mount_connected(@camera_id, deps, refresh_interval_ms: 60_000, debounce_ms: 500)
      on_exit(fn -> cancel_timers(socket) end)

      assert_receive {:coverage_loaded, @camera_id, @base_now_us}

      # Broadcast via real ServiceRadar.PubSub for our camera.
      assert :ok = RecordingPubSub.broadcast_updated(@camera_id, :block_cataloged)
      assert_receive {:camera_recording_updated, %{camera_source_id: @camera_id, reason: :block_cataloged}} = msg1

      {:noreply, after_first} = Recordings.handle_info(msg1, socket)
      debounce_ref = after_first.assigns.recording_debounce_timer_ref
      assert is_reference(debounce_ref)
      refute_received {:coverage_loaded, _, _}

      # Second rapid event reuses the same debounce timer (coalesced).
      {:noreply, after_second} =
        Recordings.handle_info(
          {:camera_recording_updated, %{camera_source_id: @camera_id, reason: :archive_verified}},
          after_first
        )

      assert after_second.assigns.recording_debounce_timer_ref == debounce_ref

      # Event for another camera is ignored.
      {:noreply, after_other} =
        Recordings.handle_info(
          {:camera_recording_updated, %{camera_source_id: @other_camera_id, reason: :block_cataloged}},
          socket
        )

      assert after_other.assigns.recording_debounce_timer_ref == nil

      # Delivering the debounced tick triggers exactly one refresh.
      {:noreply, refreshed} = Recordings.handle_info(:debounced_recording_refresh, after_second)
      assert refreshed.assigns.recording_debounce_timer_ref == nil
      assert_receive {:coverage_loaded, @camera_id, @base_now_us}
      refute_received {:coverage_loaded, _, _}
    end
  end

  describe "smart live refresh invariants" do
    test "slides live window to now and auto-populates playback when previously empty" do
      {:ok, clock} = Agent.start_link(fn -> @base_now_us end)
      {:ok, state} = Agent.start_link(fn -> :empty end)

      later_now_us = @base_now_us + 60_000_000
      new_block = playable_block(later_now_us - 30_000_000, later_now_us, :pending)
      new_clip = sample_clip("clip-live-1", later_now_us - 20_000_000, later_now_us - 10_000_000)

      deps =
        stub_deps(%{
          now_us: fn -> Agent.get(clock, & &1) end,
          coverage: fn source_id, params, _scope ->
            case Agent.get(state, & &1) do
              :empty ->
                {:ok, empty_coverage(source_id, params.from_us, params.to_us)}

              :populated ->
                {:ok,
                 populated_coverage(source_id, params.from_us, params.to_us, [new_block],
                   continuous_recording_active?: true
                 )}
            end
          end,
          list_event_clips: fn _source_id, _params, _scope ->
            case Agent.get(state, & &1) do
              :empty -> {:ok, %{clips: []}}
              :populated -> {:ok, %{clips: [new_clip]}}
            end
          end
        })

      socket = mount_connected(@camera_id, deps, refresh_interval_ms: 15_000, debounce_ms: 0)
      on_exit(fn -> cancel_timers(socket) end)

      assert socket.assigns.timeline_playlist_path == nil
      assert socket.assigns.timeline_coverage.to_us == @base_now_us
      assert socket.assigns.timeline_coverage.continuous_recording_active? == false
      assert socket.assigns.timeline_event_clips == []

      # Advance clock and populate a newly sealed block.
      Agent.update(clock, fn _ -> later_now_us end)
      Agent.update(state, fn _ -> :populated end)

      {:noreply, refreshed} =
        Recordings.handle_info(
          {:camera_recording_updated, %{camera_source_id: @camera_id, reason: :block_cataloged}},
          socket
        )

      assert refreshed.assigns.timeline_coverage.to_us == later_now_us
      assert refreshed.assigns.timeline_coverage.continuous_recording_active? == true
      assert is_binary(refreshed.assigns.timeline_playlist_path)
      assert refreshed.assigns.timeline_play_to_us == later_now_us
      assert Enum.map(refreshed.assigns.timeline_event_clips, & &1.id) == ["clip-live-1"]
    end

    test "preserves active user playback window and selected clip while updating coverage and event clips" do
      {:ok, clock} = Agent.start_link(fn -> @base_now_us end)

      first_block = playable_block(@base_now_us - 600_000_000, @base_now_us - 300_000_000, :pending)
      later_now_us = @base_now_us + 120_000_000
      second_block = playable_block(later_now_us - 60_000_000, later_now_us, :pending)

      clip_one = sample_clip("clip-selected-1", @base_now_us - 500_000_000, @base_now_us - 480_000_000)
      clip_two = sample_clip("clip-new-2", later_now_us - 40_000_000, later_now_us - 20_000_000)

      {:ok, phase} = Agent.start_link(fn -> :initial end)

      deps =
        stub_deps(%{
          now_us: fn -> Agent.get(clock, & &1) end,
          coverage: fn source_id, params, _scope ->
            blocks =
              if Agent.get(phase, & &1) == :initial do
                [first_block]
              else
                [%{first_block | archive_state: :verified}, second_block]
              end

            opts = [continuous_recording_active?: true]
            {:ok, populated_coverage(source_id, params.from_us, params.to_us, blocks, opts)}
          end,
          list_event_clips: fn _source_id, _params, _scope ->
            clips =
              if Agent.get(phase, & &1) == :initial do
                [clip_one]
              else
                [clip_one, clip_two]
              end

            {:ok, %{clips: clips}}
          end
        })

      socket = mount_connected(@camera_id, deps, refresh_interval_ms: 15_000, debounce_ms: 0)
      on_exit(fn -> cancel_timers(socket) end)

      # User selects a specific event clip, locking their playback window.
      {:noreply, selected_socket} =
        Recordings.handle_event("select_event_clip", %{"clip_id" => "clip-selected-1"}, socket)

      orig_play_from = selected_socket.assigns.timeline_play_from_us
      orig_play_to = selected_socket.assigns.timeline_play_to_us
      orig_playlist_path = selected_socket.assigns.timeline_playlist_path
      assert selected_socket.assigns.timeline_selected_clip_id == "clip-selected-1"
      assert is_binary(orig_playlist_path)

      # New block arrives and clock advances.
      Agent.update(clock, fn _ -> later_now_us end)
      Agent.update(phase, fn _ -> :updated end)

      {:noreply, refreshed} = Recordings.handle_info(:refresh_timeline_tick, selected_socket)
      on_exit(fn -> cancel_timers(refreshed) end)

      # Playback window and selected clip are preserved intact.
      assert refreshed.assigns.timeline_play_from_us == orig_play_from
      assert refreshed.assigns.timeline_play_to_us == orig_play_to
      assert refreshed.assigns.timeline_playlist_path == orig_playlist_path
      assert refreshed.assigns.timeline_selected_clip_id == "clip-selected-1"

      # Coverage window slid forward to later_now_us and event clips updated.
      assert refreshed.assigns.timeline_coverage.to_us == later_now_us
      assert length(refreshed.assigns.timeline_coverage.blocks) == 2
      assert Enum.map(refreshed.assigns.timeline_event_clips, & &1.id) == ["clip-selected-1", "clip-new-2"]
      assert is_reference(refreshed.assigns.recording_refresh_timer_ref)
    end

    test "refreshes archive state transitions in a historical window without shifting its time range" do
      hist_from_us = @base_now_us - 4 * @hour_us
      hist_to_us = @base_now_us - 3 * @hour_us
      {:ok, archive_state} = Agent.start_link(fn -> :pending end)

      deps =
        stub_deps(%{
          coverage: fn source_id, params, _scope ->
            block = playable_block(hist_from_us + 60_000_000, hist_from_us + 180_000_000, Agent.get(archive_state, & &1))
            {:ok, populated_coverage(source_id, params.from_us, params.to_us, [block])}
          end
        })

      socket =
        mount_connected(@camera_id, deps,
          params: %{
            "camera_source_id" => @camera_id,
            "mode" => "timeline",
            "from" => Integer.to_string(hist_from_us),
            "to" => Integer.to_string(hist_to_us)
          },
          refresh_interval_ms: 15_000,
          debounce_ms: 0
        )

      on_exit(fn -> cancel_timers(socket) end)

      assert socket.assigns.timeline_coverage.from_us == hist_from_us
      assert socket.assigns.timeline_coverage.to_us == hist_to_us
      assert hd(socket.assigns.timeline_coverage.blocks).archive_state == :pending

      # Archive job verifies the historical block.
      Agent.update(archive_state, fn _ -> :verified end)

      {:noreply, refreshed} =
        Recordings.handle_info(
          {:camera_recording_updated, %{camera_source_id: @camera_id, reason: :archive_verified}},
          socket
        )

      assert refreshed.assigns.timeline_coverage.from_us == hist_from_us
      assert refreshed.assigns.timeline_coverage.to_us == hist_to_us
      assert hd(refreshed.assigns.timeline_coverage.blocks).archive_state == :verified
    end

    test "unsubscribes and stops periodic ticks if permissions are revoked on refresh" do
      parent = self()
      {:ok, allowed?} = Agent.start_link(fn -> true end)

      deps =
        stub_deps(%{
          authorize_timeline_view: fn socket ->
            if Agent.get(allowed?, & &1) do
              {:ok, socket.assigns.current_scope, synthetic_source(socket.assigns.camera_source_id)}
            else
              {:error, :permission_revoked}
            end
          end,
          unsubscribe: fn id ->
            send(parent, {:unsubscribed, id})
            :ok
          end,
          coverage: fn source_id, params, _scope ->
            {:ok, empty_coverage(source_id, params.from_us, params.to_us)}
          end
        })

      socket = mount_connected(@camera_id, deps, refresh_interval_ms: 15_000, debounce_ms: 0)
      on_exit(fn -> cancel_timers(socket) end)

      Agent.update(allowed?, fn _ -> false end)

      {:noreply, revoked} = Recordings.handle_info(:refresh_timeline_tick, socket)
      assert_receive {:unsubscribed, @camera_id}
      assert revoked.assigns.recording_subscribed_source_id == nil
      assert revoked.assigns.recording_refresh_timer_ref == nil
      assert revoked.assigns.error =~ "permission"
    end
  end

  defp mount_connected(camera_id, deps, opts) do
    refresh_ms = Keyword.get(opts, :refresh_interval_ms, 15_000)
    debounce_ms = Keyword.get(opts, :debounce_ms, 500)
    params = Keyword.get(opts, :params, %{"camera_source_id" => camera_id, "mode" => "timeline"})

    socket =
      [connected?: true]
      |> base_socket()
      |> assign(
        recordings_deps: deps,
        recording_refresh_interval_ms: refresh_ms,
        recording_debounce_ms: debounce_ms
      )

    {:ok, mounted} = Recordings.mount(%{"camera_source_id" => camera_id}, %{}, socket)

    {:noreply, loaded} =
      Recordings.handle_params(params, "/cameras/#{camera_id}/recordings?mode=timeline", mounted)

    loaded
  end

  defp base_socket(opts) do
    connected? = Keyword.get(opts, :connected?, false)

    scope = %Scope{
      user: %{
        id: "00000000-0000-4000-8000-000000000699",
        email: "operator@example.com",
        timezone: "Etc/UTC"
      },
      permissions: MapSet.new(["devices.view", "devices.cameras.recordings.view"])
    }

    %Socket{
      endpoint: ServiceRadarWebNGWeb.Endpoint,
      transport_pid: if(connected?, do: self()),
      assigns: %{
        __changed__: %{},
        flash: %{},
        current_scope: scope
      }
    }
  end

  defp stub_deps(overrides) do
    Map.merge(
      %{
        authorize_timeline_view: fn socket ->
          {:ok, socket.assigns.current_scope, synthetic_source(socket.assigns.camera_source_id)}
        end,
        has_timeline_data?: fn _source_id, _scope -> true end,
        coverage: fn source_id, params, _scope ->
          {:ok, empty_coverage(source_id, params.from_us, params.to_us)}
        end,
        list_relay_profiles: fn _scope, _source_id -> [] end,
        list_holds: fn _source_id, _scope -> {:ok, []} end,
        list_event_clips: fn _source_id, _params, _scope -> {:ok, %{clips: []}} end,
        subscribe: &RecordingPubSub.subscribe/1,
        unsubscribe: &RecordingPubSub.unsubscribe/1,
        now_us: fn -> @base_now_us end
      },
      overrides
    )
  end

  defp synthetic_source(id) do
    %{
      id: id,
      device_uid: "sr:synthetic-cam-#{id}",
      display_name: "Synthetic Gate Camera"
    }
  end

  defp empty_coverage(source_id, from_us, to_us) do
    %{
      camera_source_id: source_id,
      from_us: from_us,
      to_us: to_us,
      buckets: [],
      blocks: [],
      gaps: [],
      holds: [],
      reanchors: [],
      time_basis: "received",
      time_uncertainty: "unmeasured",
      scheduled_continuous?: true,
      continuous_recording_active?: false
    }
  end

  defp populated_coverage(source_id, from_us, to_us, blocks, opts \\ []) do
    %{
      camera_source_id: source_id,
      from_us: from_us,
      to_us: to_us,
      buckets: [
        %{
          start_us: from_us,
          end_us: to_us,
          state: :local_and_archive,
          provisional?: false
        }
      ],
      blocks: blocks,
      gaps: [],
      holds: [],
      reanchors: [],
      time_basis: "received",
      time_uncertainty: "unmeasured",
      scheduled_continuous?: true,
      continuous_recording_active?: Keyword.get(opts, :continuous_recording_active?, false)
    }
  end

  defp playable_block(start_us, end_us, archive_state) do
    %{
      id: "00000000-0000-4000-8000-000000000701",
      stream_profile_id: @profile_id,
      timeline_start_us: start_us,
      timeline_end_us: end_us,
      local_state: :present,
      archive_state: archive_state
    }
  end

  defp sample_clip(id, start_us, end_us) do
    %{
      id: id,
      start_us: start_us,
      end_us: end_us,
      peak_ts_us: start_us + div(end_us - start_us, 2),
      category: "person",
      mode: "smart",
      visual_frame_id: nil
    }
  end

  defp cancel_timers(socket) do
    for key <- [:recording_refresh_timer_ref, :recording_debounce_timer_ref] do
      case Map.get(socket.assigns, key) do
        ref when is_reference(ref) -> Process.cancel_timer(ref)
        _ -> :ok
      end
    end

    if is_binary(socket.assigns[:recording_subscribed_source_id]) do
      RecordingPubSub.unsubscribe(socket.assigns.recording_subscribed_source_id)
    end
  end
end
