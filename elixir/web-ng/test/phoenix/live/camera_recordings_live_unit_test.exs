defmodule ServiceRadarWebNGWeb.CameraRecordingsLiveUnitTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Phoenix.LiveView.Socket
  alias ServiceRadar.Camera.RecordingEventClips
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
        list_cameras: fn _, _ -> flunk("disconnected mount/params must not list cameras") end,
        list_window_overlays: fn _, _, _, _, _ ->
          flunk("disconnected mount/params must not list window overlays")
        end,
        get_frame_overlay: fn _, _, _ ->
          flunk("disconnected mount/params must not load frame overlay")
        end,
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

      assert {:noreply, after_live_params} =
               Recordings.handle_params(
                 %{"camera_source_id" => @camera_id, "mode" => "live"},
                 "/cameras/#{@camera_id}/recordings?mode=live",
                 mounted
               )

      assert after_live_params.assigns.live_mode? == true
      assert after_live_params.assigns.recording_subscribed_source_id == nil
      assert after_live_params.assigns.recording_refresh_timer_ref == nil
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
      debounce_token = after_first.assigns.recording_debounce_token
      assert is_reference(debounce_ref)
      assert is_reference(debounce_token)
      refute_received {:coverage_loaded, _, _}

      # Second rapid event reuses the same debounce timer (coalesced).
      {:noreply, after_second} =
        Recordings.handle_info(
          {:camera_recording_updated, %{camera_source_id: @camera_id, reason: :archive_verified}},
          after_first
        )

      assert after_second.assigns.recording_debounce_timer_ref == debounce_ref
      assert after_second.assigns.recording_debounce_token == debounce_token

      # Event for another camera is ignored.
      {:noreply, after_other} =
        Recordings.handle_info(
          {:camera_recording_updated, %{camera_source_id: @other_camera_id, reason: :block_cataloged}},
          socket
        )

      assert after_other.assigns.recording_debounce_timer_ref == nil

      # Delivering the debounced tick triggers exactly one refresh.
      {:noreply, refreshed} =
        Recordings.handle_info({:debounced_recording_refresh, debounce_token}, after_second)

      assert refreshed.assigns.recording_debounce_timer_ref == nil
      assert refreshed.assigns.recording_debounce_token == nil
      assert_receive {:coverage_loaded, @camera_id, @base_now_us}
      refute_received {:coverage_loaded, _, _}
    end

    test "ignores stale periodic tick tokens after handle_params so timers never multiply" do
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

      first_timer = socket.assigns.recording_refresh_timer_ref
      first_token = socket.assigns.recording_refresh_token
      assert is_reference(first_timer)
      assert is_reference(first_token)

      {:noreply, patched} =
        Recordings.handle_params(
          %{"camera_source_id" => @camera_id, "mode" => "timeline", "span" => "6h"},
          "/cameras/#{@camera_id}/recordings?mode=timeline&span=6h",
          socket
        )

      on_exit(fn -> cancel_timers(patched) end)
      assert_receive {:coverage_loaded, @camera_id, @base_now_us}

      second_timer = patched.assigns.recording_refresh_timer_ref
      second_token = patched.assigns.recording_refresh_token
      assert is_reference(second_timer)
      assert is_reference(second_token)
      refute second_timer == first_timer
      refute second_token == first_token

      {:noreply, after_stale} = Recordings.handle_info({:refresh_timeline_tick, first_token}, patched)
      assert after_stale.assigns.recording_refresh_timer_ref == second_timer
      assert after_stale.assigns.recording_refresh_token == second_token
      assert Process.read_timer(second_timer) != false
      refute_received {:coverage_loaded, _, _}

      no_token_socket = assign(patched, recording_refresh_token: nil)
      {:noreply, after_nil} = Recordings.handle_info({:refresh_timeline_tick, nil}, no_token_socket)
      assert after_nil.assigns.recording_refresh_timer_ref == second_timer
      refute_received {:coverage_loaded, _, _}
    end

    test "ignores stale debounced refresh tokens after a refresh or handle_params reset" do
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

      {:noreply, with_debounce} =
        Recordings.handle_info(
          {:camera_recording_updated, %{camera_source_id: @camera_id, reason: :block_cataloged}},
          socket
        )

      stale_debounce_token = with_debounce.assigns.recording_debounce_token
      assert is_reference(stale_debounce_token)

      tick_token = with_debounce.assigns.recording_refresh_token
      {:noreply, after_tick} = Recordings.handle_info({:refresh_timeline_tick, tick_token}, with_debounce)
      on_exit(fn -> cancel_timers(after_tick) end)
      assert_receive {:coverage_loaded, @camera_id, @base_now_us}
      assert after_tick.assigns.recording_debounce_timer_ref == nil
      assert after_tick.assigns.recording_debounce_token == nil

      {:noreply, after_stale_debounce} =
        Recordings.handle_info({:debounced_recording_refresh, stale_debounce_token}, after_tick)

      assert after_stale_debounce.assigns.recording_debounce_timer_ref == nil
      refute_received {:coverage_loaded, _, _}

      {:noreply, with_new_debounce} =
        Recordings.handle_info(
          {:camera_recording_updated, %{camera_source_id: @camera_id, reason: :archive_verified}},
          after_stale_debounce
        )

      on_exit(fn -> cancel_timers(with_new_debounce) end)
      new_debounce_ref = with_new_debounce.assigns.recording_debounce_timer_ref
      new_debounce_token = with_new_debounce.assigns.recording_debounce_token
      assert is_reference(new_debounce_token)
      refute new_debounce_token == stale_debounce_token

      {:noreply, still_pending} =
        Recordings.handle_info({:debounced_recording_refresh, stale_debounce_token}, with_new_debounce)

      assert still_pending.assigns.recording_debounce_timer_ref == new_debounce_ref
      assert still_pending.assigns.recording_debounce_token == new_debounce_token
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
          list_event_clips: fn _source_id, params, _scope ->
            case Agent.get(state, & &1) do
              :empty -> {:ok, list_page_result([], params)}
              :populated -> {:ok, list_page_result([new_clip], params)}
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
          list_event_clips: fn _source_id, params, _scope ->
            clips =
              if Agent.get(phase, & &1) == :initial do
                [clip_one]
              else
                [clip_one, clip_two]
              end

            {:ok, list_page_result(clips, params)}
          end
        })

      socket = mount_connected(@camera_id, deps, refresh_interval_ms: 15_000, debounce_ms: 0)
      on_exit(fn -> cancel_timers(socket) end)

      # User selects a specific event clip (opens modal), then clicks View in Timeline to lock playback window.
      {:noreply, modal_socket} =
        Recordings.handle_event("select_event_clip", %{"clip_id" => "clip-selected-1"}, socket)

      assert modal_socket.assigns.timeline_selected_clip_id == "clip-selected-1"
      assert is_map(modal_socket.assigns.clip_modal)
      assert is_binary(modal_socket.assigns.clip_modal.playlist_path)

      {:noreply, selected_socket} =
        Recordings.handle_event("open_clip_in_timeline", %{}, modal_socket)

      orig_play_from = selected_socket.assigns.timeline_play_from_us
      orig_play_to = selected_socket.assigns.timeline_play_to_us
      orig_playlist_path = selected_socket.assigns.timeline_playlist_path
      assert selected_socket.assigns.clip_modal == nil
      assert selected_socket.assigns.timeline_selected_clip_id == "clip-selected-1"
      assert is_binary(orig_playlist_path)

      # New block arrives and clock advances.
      Agent.update(clock, fn _ -> later_now_us end)
      Agent.update(phase, fn _ -> :updated end)

      {:noreply, refreshed} =
        Recordings.handle_info(
          {:refresh_timeline_tick, selected_socket.assigns.recording_refresh_token},
          selected_socket
        )

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

      {:noreply, revoked} =
        Recordings.handle_info({:refresh_timeline_tick, socket.assigns.recording_refresh_token}, socket)

      assert_receive {:unsubscribed, @camera_id}
      assert revoked.assigns.recording_subscribed_source_id == nil
      assert revoked.assigns.recording_refresh_timer_ref == nil
      assert revoked.assigns.recording_refresh_token == nil
      assert revoked.assigns.error =~ "permission"
    end

    test "keeps active playback intact and reschedules ticks on transient refresh errors" do
      {:ok, clock} = Agent.start_link(fn -> @base_now_us end)
      {:ok, fault} = Agent.start_link(fn -> :ok end)

      first_block = playable_block(@base_now_us - 600_000_000, @base_now_us - 300_000_000, :pending)
      later_now_us = @base_now_us + 30_000_000
      second_block = playable_block(later_now_us - 20_000_000, later_now_us, :pending)

      deps =
        stub_deps(%{
          now_us: fn -> Agent.get(clock, & &1) end,
          authorize_timeline_view: fn socket ->
            case Agent.get(fault, & &1) do
              :auth_timeout ->
                {:error, :db_connection_timeout}

              _ ->
                {:ok, socket.assigns.current_scope, synthetic_source(socket.assigns.camera_source_id)}
            end
          end,
          coverage: fn source_id, params, _scope ->
            case Agent.get(fault, & &1) do
              :coverage_timeout ->
                {:error, :timeout}

              :recovered ->
                {:ok, populated_coverage(source_id, params.from_us, params.to_us, [first_block, second_block])}

              _ ->
                {:ok, populated_coverage(source_id, params.from_us, params.to_us, [first_block])}
            end
          end,
          list_holds: fn _source_id, _scope ->
            case Agent.get(fault, & &1) do
              :holds_pool_error -> {:error, :checkout_timeout}
              _ -> {:ok, []}
            end
          end
        })

      socket = mount_connected(@camera_id, deps, refresh_interval_ms: 15_000, debounce_ms: 0)
      on_exit(fn -> cancel_timers(socket) end)

      orig_playlist_path = socket.assigns.timeline_playlist_path
      orig_coverage = socket.assigns.timeline_coverage
      orig_play_from = socket.assigns.timeline_play_from_us
      orig_play_to = socket.assigns.timeline_play_to_us
      assert is_binary(orig_playlist_path)

      for transient_fault <- [:coverage_timeout, :holds_pool_error, :auth_timeout] do
        Agent.update(fault, fn _ -> transient_fault end)

        {result, log} =
          with_log(fn ->
            Recordings.handle_info(
              {:refresh_timeline_tick, socket.assigns.recording_refresh_token},
              socket
            )
          end)

        {:noreply, after_error} = result
        on_exit(fn -> cancel_timers(after_error) end)

        assert log =~ "Transient camera recordings live refresh error"
        assert after_error.assigns.error == nil
        assert after_error.assigns.timeline_playlist_path == orig_playlist_path
        assert after_error.assigns.timeline_coverage == orig_coverage
        assert after_error.assigns.timeline_play_from_us == orig_play_from
        assert after_error.assigns.timeline_play_to_us == orig_play_to
        assert after_error.assigns.recording_subscribed_source_id == @camera_id
        assert is_reference(after_error.assigns.recording_refresh_timer_ref)
        assert is_reference(after_error.assigns.recording_refresh_token)
        refute after_error.assigns.recording_refresh_token == socket.assigns.recording_refresh_token
      end

      Agent.update(fault, fn _ -> :coverage_timeout end)

      {result, _log} =
        with_log(fn ->
          Recordings.handle_info(
            {:refresh_timeline_tick, socket.assigns.recording_refresh_token},
            socket
          )
        end)

      {:noreply, after_transient} = result
      on_exit(fn -> cancel_timers(after_transient) end)

      Agent.update(clock, fn _ -> later_now_us end)
      Agent.update(fault, fn _ -> :recovered end)

      {:noreply, recovered} =
        Recordings.handle_info(
          {:refresh_timeline_tick, after_transient.assigns.recording_refresh_token},
          after_transient
        )

      on_exit(fn -> cancel_timers(recovered) end)

      assert recovered.assigns.error == nil
      assert recovered.assigns.timeline_playlist_path == orig_playlist_path
      assert recovered.assigns.timeline_coverage.to_us == later_now_us
      assert length(recovered.assigns.timeline_coverage.blocks) == 2
    end

    test "handles transient vs fatal errors when checking published-to-timeline auto-switch" do
      {:ok, state} = Agent.start_link(fn -> :ok end)
      parent = self()

      deps =
        stub_deps(%{
          authorize_timeline_view: fn socket ->
            case Agent.get(state, & &1) do
              :auth_transient -> {:error, :db_timeout}
              :forbidden -> {:error, :forbidden}
              :not_found -> {:error, :not_found}
              _ -> {:ok, socket.assigns.current_scope, synthetic_source(socket.assigns.camera_source_id)}
            end
          end,
          has_timeline_data?: fn _source_id, _scope -> true end,
          coverage: fn _source_id, _params, _scope ->
            case Agent.get(state, & &1) do
              :coverage_transient -> {:error, :timeout}
              _ -> {:ok, empty_coverage(@camera_id, @base_now_us - @hour_us, @base_now_us)}
            end
          end,
          unsubscribe: fn id ->
            send(parent, {:unsubscribed, id})
            :ok
          end
        })

      base =
        @camera_id
        |> mount_connected(deps, refresh_interval_ms: 15_000, debounce_ms: 0)
        |> assign(
          mode: :published,
          requested_mode: nil,
          timeline_coverage: nil,
          timeline_playlist_path: nil,
          timeline_user_selected_window?: false
        )

      on_exit(fn -> cancel_timers(base) end)
      assert is_reference(base.assigns.recording_refresh_token)

      for transient_state <- [:auth_transient, :coverage_transient] do
        Agent.update(state, fn _ -> transient_state end)

        {result, log} =
          with_log(fn ->
            Recordings.handle_info({:refresh_timeline_tick, base.assigns.recording_refresh_token}, base)
          end)

        {:noreply, after_transient} = result
        on_exit(fn -> cancel_timers(after_transient) end)

        assert log =~ "Transient camera recordings live refresh error"
        assert after_transient.assigns.mode == :published
        assert after_transient.assigns.error == nil
        assert after_transient.assigns.recording_subscribed_source_id == @camera_id
        assert is_reference(after_transient.assigns.recording_refresh_timer_ref)
      end

      for {fatal_state, expected_substring} <- [{:forbidden, "permission"}, {:not_found, "not be found"}] do
        Agent.update(state, fn _ -> fatal_state end)

        {:noreply, after_fatal} =
          Recordings.handle_info({:refresh_timeline_tick, base.assigns.recording_refresh_token}, base)

        assert_receive {:unsubscribed, @camera_id}
        assert after_fatal.assigns.recording_subscribed_source_id == nil
        assert after_fatal.assigns.recording_refresh_timer_ref == nil
        assert after_fatal.assigns.error =~ expected_substring
      end
    end

    test "preserves user-selected empty bucket window across ticks and activates playback in place when a block seals" do
      {:ok, clock} = Agent.start_link(fn -> @base_now_us end)
      {:ok, phase} = Agent.start_link(fn -> :initial end)

      span_from_us = @base_now_us - 6 * @hour_us
      early_block = playable_block(span_from_us + 60_000_000, span_from_us + 180_000_000, :pending)

      bucket_start_us = @base_now_us - 2 * @hour_us
      bucket_end_us = bucket_start_us + 180_000_000
      sealed_in_bucket = playable_block(bucket_start_us + 30_000_000, bucket_start_us + 120_000_000, :pending)
      later_now_us = @base_now_us + 30_000_000
      newer_block = playable_block(later_now_us - 15_000_000, later_now_us, :pending)

      deps =
        stub_deps(%{
          now_us: fn -> Agent.get(clock, & &1) end,
          coverage: fn source_id, params, _scope ->
            blocks =
              case Agent.get(phase, & &1) do
                :initial -> [early_block]
                :sealed_in_bucket -> [early_block, sealed_in_bucket]
                :sealed_later -> [early_block, sealed_in_bucket, newer_block]
              end

            {:ok, populated_coverage(source_id, params.from_us, params.to_us, blocks)}
          end
        })

      socket =
        mount_connected(@camera_id, deps,
          params: %{"camera_source_id" => @camera_id, "mode" => "timeline", "span" => "6h"},
          refresh_interval_ms: 15_000,
          debounce_ms: 0
        )

      on_exit(fn -> cancel_timers(socket) end)

      assert socket.assigns.timeline_user_selected_window? == false
      assert socket.assigns.timeline_play_from_us == early_block.timeline_start_us

      {:noreply, bucket_socket} =
        Recordings.handle_event(
          "select_timeline_bucket",
          %{
            "start_us" => Integer.to_string(bucket_start_us),
            "end_us" => Integer.to_string(bucket_end_us)
          },
          socket
        )

      chosen_from = bucket_socket.assigns.timeline_play_from_us
      chosen_to = bucket_socket.assigns.timeline_play_to_us
      assert chosen_from == bucket_start_us
      assert chosen_to == bucket_start_us + @hour_us
      assert bucket_socket.assigns.timeline_playlist_path == nil
      assert bucket_socket.assigns.timeline_user_selected_window? == true

      Agent.update(clock, fn _ -> @base_now_us + 15_000_000 end)

      {:noreply, after_empty_tick} =
        Recordings.handle_info(
          {:refresh_timeline_tick, bucket_socket.assigns.recording_refresh_token},
          bucket_socket
        )

      on_exit(fn -> cancel_timers(after_empty_tick) end)

      assert after_empty_tick.assigns.timeline_play_from_us == chosen_from
      assert after_empty_tick.assigns.timeline_play_to_us == chosen_to
      assert after_empty_tick.assigns.timeline_playlist_path == nil
      assert after_empty_tick.assigns.timeline_user_selected_window? == true

      Agent.update(phase, fn _ -> :sealed_in_bucket end)

      {:noreply, after_sealed_tick} =
        Recordings.handle_info(
          {:refresh_timeline_tick, after_empty_tick.assigns.recording_refresh_token},
          after_empty_tick
        )

      on_exit(fn -> cancel_timers(after_sealed_tick) end)

      assert after_sealed_tick.assigns.timeline_play_from_us == chosen_from
      assert after_sealed_tick.assigns.timeline_play_to_us == chosen_to
      assert is_binary(after_sealed_tick.assigns.timeline_playlist_path)
      assert after_sealed_tick.assigns.timeline_playlist_path =~ "from=#{chosen_from}&to=#{chosen_to}"
      assert after_sealed_tick.assigns.timeline_playlist_origin_us == sealed_in_bucket.timeline_start_us

      active_playlist_path = after_sealed_tick.assigns.timeline_playlist_path
      Agent.update(clock, fn _ -> later_now_us end)
      Agent.update(phase, fn _ -> :sealed_later end)

      {:noreply, after_later_tick} =
        Recordings.handle_info(
          {:refresh_timeline_tick, after_sealed_tick.assigns.recording_refresh_token},
          after_sealed_tick
        )

      on_exit(fn -> cancel_timers(after_later_tick) end)

      assert after_later_tick.assigns.timeline_play_from_us == chosen_from
      assert after_later_tick.assigns.timeline_play_to_us == chosen_to
      assert after_later_tick.assigns.timeline_playlist_path == active_playlist_path

      {:noreply, after_span_reset} =
        Recordings.handle_event("select_timeline_span", %{"span" => "1h"}, after_later_tick)

      assert after_span_reset.assigns.timeline_user_selected_window? == false

      {:noreply, after_bucket_again} =
        Recordings.handle_event(
          "select_timeline_bucket",
          %{
            "start_us" => Integer.to_string(bucket_start_us),
            "end_us" => Integer.to_string(bucket_end_us)
          },
          after_later_tick
        )

      assert after_bucket_again.assigns.timeline_user_selected_window? == true

      {:noreply, after_profile_reset} =
        Recordings.handle_event(
          "select_timeline_profile",
          %{"stream_profile_id" => @profile_id},
          after_bucket_again
        )

      assert after_profile_reset.assigns.timeline_user_selected_window? == false
    end

    test "only auto-switches from published to timeline when published items are empty and nothing is playing" do
      block = playable_block(@base_now_us - 120_000_000, @base_now_us - 60_000_000, :pending)

      deps =
        stub_deps(%{
          has_timeline_data?: fn _source_id, _scope -> true end,
          coverage: fn source_id, params, _scope ->
            {:ok, populated_coverage(source_id, params.from_us, params.to_us, [block])}
          end
        })

      published_item = %{block_id: "pub-block-1", started_at: @base_now_us - 300_000_000}

      selected_recording = %{
        block_id: "pub-block-1",
        window: %{index: 0, first: 0, count: 10},
        playlist_path: "/api/cameras/#{@camera_id}/recordings/pub-block-1/playlist.m3u8?first=0&count=10"
      }

      base =
        @camera_id
        |> mount_connected(deps, refresh_interval_ms: 15_000, debounce_ms: 0)
        |> assign(
          mode: :published,
          requested_mode: nil,
          timeline_coverage: nil,
          timeline_playlist_path: nil,
          timeline_user_selected_window?: false
        )

      on_exit(fn -> cancel_timers(base) end)

      with_items = assign(base, items: [published_item], selected: nil)

      {:noreply, after_items_tick} =
        Recordings.handle_info({:refresh_timeline_tick, with_items.assigns.recording_refresh_token}, with_items)

      on_exit(fn -> cancel_timers(after_items_tick) end)
      assert after_items_tick.assigns.mode == :published
      assert after_items_tick.assigns.items == [published_item]
      assert is_reference(after_items_tick.assigns.recording_refresh_timer_ref)

      playing_published = assign(base, items: [published_item], selected: selected_recording)

      {:noreply, after_playing_pubsub} =
        Recordings.handle_info(
          {:camera_recording_updated, %{camera_source_id: @camera_id, reason: :block_cataloged}},
          playing_published
        )

      assert after_playing_pubsub.assigns.mode == :published
      assert after_playing_pubsub.assigns.selected == selected_recording

      selected_only = assign(base, items: [], selected: selected_recording)

      {:noreply, after_selected_only} =
        Recordings.handle_info(
          {:camera_recording_updated, %{camera_source_id: @camera_id, reason: :block_cataloged}},
          selected_only
        )

      assert after_selected_only.assigns.mode == :published
      assert after_selected_only.assigns.selected == selected_recording

      empty_idle = assign(base, items: [], selected: nil)

      {:noreply, switched} =
        Recordings.handle_info(
          {:camera_recording_updated, %{camera_source_id: @camera_id, reason: :block_cataloged}},
          empty_idle
        )

      assert switched.assigns.mode == :timeline
      assert is_binary(switched.assigns.timeline_playlist_path)
    end

    test "preserves live refresh on non-fatal unavailable errors and re-arms after recovery from teardown" do
      parent = self()
      {:ok, mode} = Agent.start_link(fn -> :ok end)

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
          authorize_timeline_view: fn socket ->
            case Agent.get(mode, & &1) do
              :fatal_auth -> {:error, :permission_revoked}
              _ -> {:ok, socket.assigns.current_scope, synthetic_source(socket.assigns.camera_source_id)}
            end
          end,
          coverage: fn source_id, params, _scope ->
            case Agent.get(mode, & &1) do
              :non_fatal_timeout -> {:error, :timeout}
              _ -> {:ok, empty_coverage(source_id, params.from_us, params.to_us)}
            end
          end
        })

      socket = mount_connected(@camera_id, deps, refresh_interval_ms: 15_000, debounce_ms: 0)
      on_exit(fn -> cancel_timers(socket) end)
      assert_receive {:subscribed, @camera_id}

      Agent.update(mode, fn _ -> :non_fatal_timeout end)
      {:noreply, non_fatal_socket} = Recordings.handle_event("refresh_timeline", %{}, socket)

      assert non_fatal_socket.assigns.error =~ "temporarily unavailable"
      refute_received {:unsubscribed, @camera_id}
      assert non_fatal_socket.assigns.recording_subscribed_source_id == @camera_id
      assert is_reference(non_fatal_socket.assigns.recording_refresh_timer_ref)
      assert is_reference(non_fatal_socket.assigns.recording_refresh_token)

      dropped_timer_socket =
        assign(non_fatal_socket, recording_refresh_timer_ref: nil, recording_refresh_token: nil)

      Agent.update(mode, fn _ -> :ok end)
      {:noreply, rearmed_timer} = Recordings.handle_event("refresh_timeline", %{}, dropped_timer_socket)
      on_exit(fn -> cancel_timers(rearmed_timer) end)

      assert rearmed_timer.assigns.error == nil
      assert rearmed_timer.assigns.recording_subscribed_source_id == @camera_id
      assert is_reference(rearmed_timer.assigns.recording_refresh_timer_ref)
      assert is_reference(rearmed_timer.assigns.recording_refresh_token)
      refute_received {:subscribed, @camera_id}

      Agent.update(mode, fn _ -> :fatal_auth end)
      {:noreply, torn_down} = Recordings.handle_event("refresh_timeline", %{}, rearmed_timer)

      assert_receive {:unsubscribed, @camera_id}
      assert torn_down.assigns.recording_subscribed_source_id == nil
      assert torn_down.assigns.recording_refresh_timer_ref == nil
      assert torn_down.assigns.recording_refresh_token == nil

      Agent.update(mode, fn _ -> :ok end)

      {:noreply, recovered} =
        Recordings.handle_event("switch_recordings_mode", %{"mode" => "timeline"}, torn_down)

      on_exit(fn -> cancel_timers(recovered) end)

      assert_receive {:subscribed, @camera_id}
      assert recovered.assigns.error == nil
      assert recovered.assigns.recording_subscribed_source_id == @camera_id
      assert is_reference(recovered.assigns.recording_refresh_timer_ref)
      assert is_reference(recovered.assigns.recording_refresh_token)
    end

    test "keeps periodic refresh ticks alive across consecutive transient errors after non-fatal unavailable" do
      {:ok, mode} = Agent.start_link(fn -> :ok end)
      block = playable_block(@base_now_us - 120_000_000, @base_now_us - 60_000_000, :pending)

      deps =
        stub_deps(%{
          coverage: fn source_id, params, _scope ->
            case Agent.get(mode, & &1) do
              :timeout -> {:error, :timeout}
              :recovered -> {:ok, populated_coverage(source_id, params.from_us, params.to_us, [block])}
              :ok -> {:ok, empty_coverage(source_id, params.from_us, params.to_us)}
            end
          end
        })

      socket = mount_connected(@camera_id, deps, refresh_interval_ms: 15_000, debounce_ms: 0)
      on_exit(fn -> cancel_timers(socket) end)

      Agent.update(mode, fn _ -> :timeout end)
      {:noreply, after_non_fatal} = Recordings.handle_event("refresh_timeline", %{}, socket)
      assert after_non_fatal.assigns.error =~ "temporarily unavailable"
      assert after_non_fatal.assigns.recording_subscribed_source_id == @camera_id
      assert is_reference(after_non_fatal.assigns.recording_refresh_token)

      # Next periodic tick hits the same transient timeout while error is still populated.
      {tick_result, log} =
        with_log(fn ->
          Recordings.handle_info(
            {:refresh_timeline_tick, after_non_fatal.assigns.recording_refresh_token},
            after_non_fatal
          )
        end)

      {:noreply, after_still_failing_tick} = tick_result
      on_exit(fn -> cancel_timers(after_still_failing_tick) end)

      assert log =~ "Transient camera recordings live refresh error"
      assert after_still_failing_tick.assigns.recording_subscribed_source_id == @camera_id
      assert is_reference(after_still_failing_tick.assigns.recording_refresh_timer_ref)
      assert is_reference(after_still_failing_tick.assigns.recording_refresh_token)
      refute after_still_failing_tick.assigns.recording_refresh_token == after_non_fatal.assigns.recording_refresh_token

      # Following tick succeeds once the backend recovers and clears the error automatically.
      Agent.update(mode, fn _ -> :recovered end)

      {:noreply, auto_recovered} =
        Recordings.handle_info(
          {:refresh_timeline_tick, after_still_failing_tick.assigns.recording_refresh_token},
          after_still_failing_tick
        )

      on_exit(fn -> cancel_timers(auto_recovered) end)

      assert auto_recovered.assigns.error == nil
      assert length(auto_recovered.assigns.timeline_coverage.blocks) == 1
      assert is_binary(auto_recovered.assigns.timeline_playlist_path)
      assert is_reference(auto_recovered.assigns.recording_refresh_timer_ref)
    end

    test "renders newly sealed block, archive copy-state transition, and event clip while keeping player playlist path stable" do
      {:ok, clock} = Agent.start_link(fn -> @base_now_us end)
      {:ok, phase} = Agent.start_link(fn -> :initial end)

      first_block_id = "00000000-0000-4000-8000-000000000711"
      second_block_id = "00000000-0000-4000-8000-000000000712"
      later_now_us = @base_now_us + 45_000_000

      first_pending =
        (@base_now_us - 600_000_000)
        |> playable_block(@base_now_us - 300_000_000, :pending)
        |> Map.merge(%{id: first_block_id, copy_state: :pending_archive})

      first_archived =
        Map.merge(first_pending, %{archive_state: :verified, copy_state: :local_and_archived})

      second_sealed =
        (later_now_us - 30_000_000)
        |> playable_block(later_now_us, :pending)
        |> Map.merge(%{id: second_block_id, copy_state: :pending_archive})

      initial_clip = sample_clip("clip-initial-1", @base_now_us - 500_000_000, @base_now_us - 485_000_000)
      new_clip = sample_clip("clip-live-new", later_now_us - 25_000_000, later_now_us - 10_000_000)

      deps =
        stub_deps(%{
          now_us: fn -> Agent.get(clock, & &1) end,
          coverage: fn source_id, params, _scope ->
            blocks =
              if Agent.get(phase, & &1) == :initial do
                [first_pending]
              else
                [first_archived, second_sealed]
              end

            opts = [continuous_recording_active?: true]
            {:ok, populated_coverage(source_id, params.from_us, params.to_us, blocks, opts)}
          end,
          list_event_clips: fn _source_id, params, _scope ->
            clips =
              if Agent.get(phase, & &1) == :initial do
                [initial_clip]
              else
                [initial_clip, new_clip]
              end

            {:ok, list_page_result(clips, params)}
          end
        })

      socket = mount_connected(@camera_id, deps, refresh_interval_ms: 15_000, debounce_ms: 0)
      on_exit(fn -> cancel_timers(socket) end)

      before_doc = LazyHTML.from_fragment(render_component(&Recordings.render/1, socket.assigns))

      [orig_playlist_path] =
        before_doc |> LazyHTML.query("#camera-timeline-player") |> LazyHTML.attribute("data-playlist-path")

      assert is_binary(orig_playlist_path) and orig_playlist_path != ""

      assert before_doc
             |> LazyHTML.query("#camera-timeline-player")
             |> LazyHTML.attribute("data-has-adjacent-window") == ["false"]

      assert before_doc
             |> LazyHTML.query("#camera-timeline-block-#{first_block_id}")
             |> LazyHTML.attribute("data-copy-state") == ["pending_archive"]

      assert before_doc |> LazyHTML.query("#camera-timeline-block-#{second_block_id}") |> Enum.to_list() == []
      assert before_doc |> LazyHTML.query("#camera-clip-card-clip-live-new") |> Enum.to_list() == []

      Agent.update(clock, fn _ -> later_now_us end)
      Agent.update(phase, fn _ -> :updated end)

      {:noreply, refreshed} =
        Recordings.handle_info(
          {:camera_recording_updated, %{camera_source_id: @camera_id, reason: :block_cataloged}},
          socket
        )

      after_doc = LazyHTML.from_fragment(render_component(&Recordings.render/1, refreshed.assigns))

      assert after_doc |> LazyHTML.query("#camera-timeline-player") |> LazyHTML.attribute("data-playlist-path") == [
               orig_playlist_path
             ]

      assert after_doc
             |> LazyHTML.query("#camera-timeline-player")
             |> LazyHTML.attribute("data-has-adjacent-window") == ["true"]

      assert after_doc
             |> LazyHTML.query("#camera-timeline-block-#{first_block_id}")
             |> LazyHTML.attribute("data-copy-state") == ["local_and_archived"]

      assert after_doc
             |> LazyHTML.query("#camera-timeline-block-#{second_block_id}")
             |> LazyHTML.attribute("data-copy-state") == ["pending_archive"]

      assert length(Enum.to_list(LazyHTML.query(after_doc, "#camera-clip-card-clip-live-new"))) == 1
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

  describe "3-pane workspace interactions (vertical seek, zoom, switcher, clips pagination, manage drawer)" do
    test "seek_timeline_fraction maps vertical fraction (0.0 newest -> 1.0 oldest) to exact timestamp and seek offset" do
      from_us = @base_now_us - @hour_us
      to_us = @base_now_us
      block = playable_block(from_us, to_us, :verified)

      deps =
        stub_deps(%{
          coverage: fn source_id, params, _scope ->
            {:ok, populated_coverage(source_id, params.from_us, params.to_us, [block])}
          end
        })

      socket = mount_connected(@camera_id, deps, refresh_interval_ms: 0, debounce_ms: 0)
      on_exit(fn -> cancel_timers(socket) end)

      # 0.25 from top = 25% older than to_us = to_us - 15 minutes
      {:noreply, sought} =
        Recordings.handle_event("seek_timeline_fraction", %{"fraction" => 0.25}, socket)

      expected_ts = round(to_us - 0.25 * @hour_us)
      assert sought.assigns.timeline_seek_us == expected_ts
      assert sought.assigns.timeline_user_selected_window? == true
      assert_in_delta sought.assigns.timeline_seek_offset_seconds, 2700.0, 0.5
    end

    test "zoom_timeline_span steps through 15m/1h/6h/24h/7d and resets clip pagination" do
      socket =
        @camera_id
        |> mount_connected(stub_deps(%{}), refresh_interval_ms: 0, debounce_ms: 0)
        |> assign(:timeline_clips_page, 3)

      on_exit(fn -> cancel_timers(socket) end)

      {:noreply, zoomed_in} = Recordings.handle_event("zoom_timeline_span", %{"direction" => "in"}, socket)
      assert zoomed_in.assigns.timeline_span == "15m"
      assert zoomed_in.assigns.timeline_clips_page == 1

      {:noreply, zoomed_out} = Recordings.handle_event("zoom_timeline_span", %{"direction" => "out"}, zoomed_in)
      assert zoomed_out.assigns.timeline_span == "1h"

      {:noreply, zoomed_out_2} = Recordings.handle_event("zoom_timeline_span", %{"direction" => "out"}, zoomed_out)
      assert zoomed_out_2.assigns.timeline_span == "6h"
    end

    test "paginates event clips server-side and resets to page 1 on filter changes" do
      parent = self()

      all_clips =
        for idx <- 1..25 do
          start_us = @base_now_us - idx * 60_000_000
          sample_clip("clip-#{idx}", start_us, start_us + 10_000_000)
        end

      deps =
        stub_deps(%{
          list_event_clips: fn _source_id, params, _scope ->
            send(parent, {:clips_queried, params.page, params.per_page, params.mode, params.category})
            {:ok, list_page_result(all_clips, params)}
          end
        })

      socket = mount_connected(@camera_id, deps, refresh_interval_ms: 0, debounce_ms: 0)
      on_exit(fn -> cancel_timers(socket) end)

      # Defaults to Smart when smart detections exist in the window
      assert_receive {:clips_queried, 1, 12, "smart", "all"}
      assert socket.assigns.timeline_clips_mode == "smart"
      assert length(socket.assigns.timeline_event_clips) == 12
      assert socket.assigns.timeline_clips_total_count == 25
      assert socket.assigns.timeline_clips_total_pages == 3
      assert socket.assigns.timeline_clips_page == 1

      {:noreply, page2} = Recordings.handle_event("paginate_event_clips", %{"page" => "2"}, socket)
      assert_receive {:clips_queried, 2, 12, "smart", "all"}
      assert page2.assigns.timeline_clips_page == 2
      assert length(page2.assigns.timeline_event_clips) == 12

      {:noreply, page3} = Recordings.handle_event("paginate_event_clips", %{"page" => "3"}, page2)
      assert_receive {:clips_queried, 3, 12, "smart", "all"}
      assert page3.assigns.timeline_clips_page == 3
      assert length(page3.assigns.timeline_event_clips) == 1

      # Switching filter resets page back to 1
      {:noreply, filtered} = Recordings.handle_event("filter_event_clips_mode", %{"mode" => "all"}, page3)
      assert_receive {:clips_queried, 1, 12, "all", "all"}
      assert filtered.assigns.timeline_clips_page == 1
    end

    test "select_event_clip focuses playback on an off-page list_page marker without crashing" do
      from_us = @base_now_us - @hour_us
      to_us = @base_now_us
      block = playable_block(from_us, to_us, :verified)
      off_page_frame_id = "00000000-0000-4000-8000-000000000888"

      entries =
        for idx <- 1..15 do
          start_us = from_us + idx * 120_000_000

          %{
            id: Ecto.UUID.generate(),
            recording_block_id: Ecto.UUID.generate(),
            camera_source_id: @camera_id,
            stream_profile_id: @profile_id,
            timeline_start_us: start_us,
            timeline_end_us: start_us + 60_000_000,
            local_state: :present,
            archive_state: :verified,
            quarantine_reason: nil,
            fragment_count: 10
          }
        end

      oldest_entry = hd(entries)

      person_frame = %{
        id: off_page_frame_id,
        catalog_entry_id: oldest_entry.id,
        camera_source_id: @camera_id,
        stream_profile_id: @profile_id,
        fragment_sequence: 1,
        timeline_ts_us: oldest_entry.timeline_start_us + 10_000_000,
        scene_suppressed: false,
        detections: [
          %{"object_class" => "person", "confidence" => 0.94, "dominant_colors" => ["blue"]}
        ]
      }

      deps =
        stub_deps(%{
          coverage: fn source_id, params, _scope ->
            {:ok, populated_coverage(source_id, params.from_us, params.to_us, [block])}
          end,
          list_event_clips: fn source_id, params, _scope ->
            RecordingEventClips.list_page(
              source_id,
              Map.delete(params, :catalog_blocks),
              loaders: %{
                catalog_loader: fn _cam, _prof, _from, _to -> {:ok, entries} end,
                visual_frames_loader: fn _cam, _prof, _from, _to -> {:ok, [person_frame]} end
              }
            )
          end
        })

      socket = mount_connected(@camera_id, deps, refresh_interval_ms: 0, debounce_ms: 0)
      on_exit(fn -> cancel_timers(socket) end)

      # Switch to "all" so the 15 newer recording segments push the older person clip off page 1
      {:noreply, socket} = Recordings.handle_event("filter_event_clips_mode", %{"mode" => "all"}, socket)

      off_page_clip_id = "evt-#{off_page_frame_id}-person"
      refute Enum.any?(socket.assigns.timeline_event_clips, &(&1.id == off_page_clip_id))
      assert Enum.any?(socket.assigns.timeline_event_markers, &(&1.id == off_page_clip_id))

      {:noreply, modal_socket} =
        Recordings.handle_event("select_event_clip", %{"clip_id" => off_page_clip_id}, socket)

      assert modal_socket.assigns.timeline_selected_clip_id == off_page_clip_id
      assert modal_socket.assigns.clip_modal.highlight_frame_id == off_page_frame_id
      assert modal_socket.assigns.clip_modal.play_from_us == oldest_entry.timeline_start_us + 5_000_000
      assert modal_socket.assigns.clip_modal.play_to_us == oldest_entry.timeline_start_us + 24_000_000

      {:noreply, focused} = Recordings.handle_event("open_clip_in_timeline", %{}, modal_socket)
      assert focused.assigns.clip_modal == nil
      assert focused.assigns.timeline_selected_clip_id == off_page_clip_id
      assert focused.assigns.timeline_highlight_frame_id == off_page_frame_id
      assert focused.assigns.timeline_play_from_us == oldest_entry.timeline_start_us + 5_000_000
      assert focused.assigns.timeline_play_to_us == oldest_entry.timeline_start_us + 24_000_000
    end

    test "camera switcher supports debounced search and bounded pagination, logs query failures, and manage drawer toggles cleanly" do
      parent = self()

      deps =
        stub_deps(%{
          list_cameras: fn _scope, opts ->
            send(parent, {:cameras_queried, opts.search, opts.page, opts.per_page})

            {:ok,
             %{
               cameras: [synthetic_source(@other_camera_id)],
               total_count: 45,
               page: opts.page,
               per_page: opts.per_page,
               total_pages: 3
             }}
          end
        })

      socket = mount_connected(@camera_id, deps, refresh_interval_ms: 0, debounce_ms: 0)
      on_exit(fn -> cancel_timers(socket) end)

      assert_receive {:cameras_queried, "", 1, 20}
      assert socket.assigns.switcher_total_count == 45
      assert socket.assigns.switcher_total_pages == 3

      {:noreply, searched} = Recordings.handle_event("switcher_search", %{"search" => "gate"}, socket)
      assert_receive {:cameras_queried, "gate", 1, 20}
      assert searched.assigns.switcher_search == "gate"

      {:noreply, page2} = Recordings.handle_event("switcher_paginate", %{"page" => "2"}, searched)
      assert_receive {:cameras_queried, "gate", 2, 20}
      assert page2.assigns.switcher_page == 2

      {:noreply, opened} = Recordings.handle_event("toggle_manage_drawer", %{}, page2)
      assert opened.assigns.timeline_manage_drawer_open? == true

      {:noreply, closed} = Recordings.handle_event("close_manage_drawer", %{}, opened)
      assert closed.assigns.timeline_manage_drawer_open? == false

      failing_deps = Map.delete(stub_deps(%{}), :list_cameras)

      log =
        capture_log(fn ->
          failed_socket = mount_connected(@camera_id, failing_deps, refresh_interval_ms: 0, debounce_ms: 0)
          on_exit(fn -> cancel_timers(failed_socket) end)
          assert failed_socket.assigns.switcher_cameras == []
        end)

      assert log =~ "Failed to list cameras for switcher"
    end

    test "select_event_clip uses exact [start_us, end_us] for :recording segments and pads smart/motion detections" do
      from_us = @base_now_us - @hour_us
      to_us = @base_now_us
      block = playable_block(from_us, to_us, :verified)

      rec_start = from_us + 600_000_000
      rec_end = rec_start + 110_000_000

      recording_clip =
        "rec-seg-exact"
        |> sample_clip(rec_start, rec_end)
        |> Map.merge(%{
          category: :recording,
          smart_type: :basic,
          label: "Recording",
          peak_ts_us: rec_start
        })

      det_start = from_us + 1_200_000_000
      det_end = det_start + 4_000_000
      person_clip = sample_clip("evt-person-pad", det_start, det_end)

      deps =
        stub_deps(%{
          coverage: fn source_id, params, _scope ->
            {:ok, populated_coverage(source_id, params.from_us, params.to_us, [block])}
          end,
          list_event_clips: fn _source_id, params, _scope ->
            {:ok, list_page_result([recording_clip, person_clip], params)}
          end
        })

      socket = mount_connected(@camera_id, deps, refresh_interval_ms: 0, debounce_ms: 0)
      on_exit(fn -> cancel_timers(socket) end)

      # Switch to "all" to display the :recording fallback segment alongside smart detections
      {:noreply, socket} = Recordings.handle_event("filter_event_clips_mode", %{"mode" => "all"}, socket)

      # Recording segment opens exact [start_us, end_us] without pre/post-roll padding in clip modal & timeline
      {:noreply, rec_modal} =
        Recordings.handle_event("select_event_clip", %{"clip_id" => "rec-seg-exact"}, socket)

      assert rec_modal.assigns.clip_modal.play_from_us == rec_start
      assert rec_modal.assigns.clip_modal.play_to_us == rec_end
      {:noreply, rec_selected} = Recordings.handle_event("open_clip_in_timeline", %{}, rec_modal)
      assert rec_selected.assigns.timeline_play_from_us == rec_start
      assert rec_selected.assigns.timeline_play_to_us == rec_end

      # Smart detection clip retains 5s pre-roll and 10s post-roll context padding in clip modal & timeline
      {:noreply, det_modal} =
        Recordings.handle_event("select_event_clip", %{"clip_id" => "evt-person-pad"}, socket)

      assert det_modal.assigns.clip_modal.play_from_us == det_start - 5_000_000
      assert det_modal.assigns.clip_modal.play_to_us == det_end + 10_000_000
      {:noreply, det_selected} = Recordings.handle_event("open_clip_in_timeline", %{}, det_modal)
      assert det_selected.assigns.timeline_play_from_us == det_start - 5_000_000
      assert det_selected.assigns.timeline_play_to_us == det_end + 10_000_000
    end
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
        list_event_clips: fn _source_id, params, _scope -> {:ok, list_page_result([], params)} end,
        list_cameras: fn _scope, _opts ->
          {:ok,
           %{
             cameras: [],
             total_count: 0,
             page: 1,
             per_page: 20,
             total_pages: 1
           }}
        end,
        list_window_overlays: fn _source_id, _from_us, _to_us, _profile_id, _scope -> [] end,
        get_frame_overlay: fn _source_id, _frame_id, _scope -> [] end,
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

  describe "recorded gaps pagination state" do
    test "paginates recorded gaps via select_gaps_page, clamps bounds, and resets page on window/profile/camera change" do
      gaps =
        for idx <- 1..25 do
          start_us = @base_now_us - (30 - idx) * 60_000_000

          %{
            id: "gap-#{idx}",
            start_us: start_us,
            end_us: start_us + 5_000_000,
            reason: :nvr_refused,
            detail_class: "http_503"
          }
        end

      deps =
        stub_deps(%{
          coverage: fn source_id, params, _scope ->
            cov =
              source_id
              |> empty_coverage(params.from_us, params.to_us)
              |> Map.put(:gaps, gaps)

            {:ok, cov}
          end
        })

      socket = mount_connected(@camera_id, deps, refresh_interval_ms: 60_000, debounce_ms: 0)
      on_exit(fn -> cancel_timers(socket) end)

      assert socket.assigns.gaps_page == 1

      {:noreply, page2} = Recordings.handle_event("select_gaps_page", %{"page" => "2"}, socket)
      assert page2.assigns.gaps_page == 2

      {:noreply, page3} = Recordings.handle_event("select_gaps_page", %{"page" => "3"}, page2)
      assert page3.assigns.gaps_page == 3

      # Out-of-range and invalid pages clamp to valid bounds [1, total_pages]
      {:noreply, clamped} = Recordings.handle_event("select_gaps_page", %{"page" => "99"}, page3)
      assert clamped.assigns.gaps_page == 3

      for invalid <- ["0", "-5", "abc"] do
        {:noreply, clamped_low} = Recordings.handle_event("select_gaps_page", %{"page" => invalid}, clamped)
        assert clamped_low.assigns.gaps_page == 1
      end

      # Window span change resets gaps_page to 1
      {:noreply, after_span} = Recordings.handle_event("select_timeline_span", %{"span" => "6h"}, clamped)
      assert after_span.assigns.gaps_page == 1

      # Window navigation resets gaps_page to 1
      {:noreply, page2_again} = Recordings.handle_event("select_gaps_page", %{"page" => "2"}, after_span)
      assert page2_again.assigns.gaps_page == 2

      {:noreply, after_nav} =
        Recordings.handle_event("navigate_timeline_window", %{"direction" => "previous"}, page2_again)

      assert after_nav.assigns.gaps_page == 1

      # Profile change resets gaps_page to 1
      {:noreply, page2_prof} = Recordings.handle_event("select_gaps_page", %{"page" => "2"}, after_nav)
      assert page2_prof.assigns.gaps_page == 2

      {:noreply, after_profile} =
        Recordings.handle_event("select_timeline_profile", %{"stream_profile_id" => @profile_id}, page2_prof)

      assert after_profile.assigns.gaps_page == 1

      # Camera switch via handle_params resets gaps_page to 1
      {:noreply, page2_cam} = Recordings.handle_event("select_gaps_page", %{"page" => "2"}, after_profile)
      assert page2_cam.assigns.gaps_page == 2

      {:noreply, after_cam} =
        Recordings.handle_params(
          %{"camera_source_id" => @other_camera_id, "mode" => "timeline"},
          "/cameras/#{@other_camera_id}/recordings?mode=timeline",
          page2_cam
        )

      on_exit(fn -> cancel_timers(after_cam) end)
      assert after_cam.assigns.gaps_page == 1
    end
  end

  describe "window overlay detections, live refresh, and camera switch search reset" do
    test "loads bounded window overlay detections during normal playback, clip playback, and live refresh" do
      from_us = @base_now_us - @hour_us
      to_us = @base_now_us
      block = playable_block(from_us, to_us, :verified)
      parent = self()

      frame_1_id = "00000000-0000-4000-8000-000000000801"
      frame_2_id = "00000000-0000-4000-8000-000000000802"
      missing_highlight_id = "00000000-0000-4000-8000-000000000803"

      det_start = from_us + 1_200_000_000
      det_end = det_start + 4_000_000

      person_clip =
        "evt-person-window"
        |> sample_clip(det_start, det_end)
        |> Map.put(:visual_frame_id, frame_1_id)

      rec_start = from_us + 600_000_000
      rec_end = rec_start + 110_000_000

      recording_clip =
        "rec-seg-window"
        |> sample_clip(rec_start, rec_end)
        |> Map.merge(%{
          category: :recording,
          smart_type: :basic,
          label: "Recording",
          peak_ts_us: rec_start,
          visual_frame_id: nil
        })

      missing_highlight_clip =
        "evt-missing-highlight"
        |> sample_clip(det_start + 5_000_000, det_end + 5_000_000)
        |> Map.put(:visual_frame_id, missing_highlight_id)

      window_det_1 = %{
        visual_frame_id: frame_1_id,
        timeline_ts_us: det_start + 1_000_000,
        start_us: max(det_start - 500_000, 0),
        end_us: det_start + 2_500_000,
        bbox: [0.1, 0.2, 0.3, 0.8],
        object_class: "person",
        score: 0.93,
        dominant_colors: ["navy"],
        time_basis: "received"
      }

      window_det_2 = %{
        visual_frame_id: frame_2_id,
        timeline_ts_us: det_start + 3_000_000,
        start_us: det_start + 1_500_000,
        end_us: det_start + 4_500_000,
        bbox: [0.4, 0.3, 0.7, 0.75],
        object_class: "vehicle",
        score: 0.88,
        dominant_colors: ["silver"],
        time_basis: "received"
      }

      extra_live_det = %{
        visual_frame_id: "00000000-0000-4000-8000-000000000804",
        timeline_ts_us: det_start + 5_000_000,
        start_us: det_start + 3_500_000,
        end_us: det_start + 6_500_000,
        bbox: [0.2, 0.2, 0.4, 0.6],
        object_class: "package",
        score: 0.81,
        dominant_colors: ["brown"],
        time_basis: "received"
      }

      highlight_det = %{
        visual_frame_id: missing_highlight_id,
        timeline_ts_us: det_start + 6_000_000,
        start_us: det_start + 4_500_000,
        end_us: det_start + 7_500_000,
        bbox: [0.5, 0.1, 0.8, 0.5],
        object_class: "animal",
        score: 0.9,
        dominant_colors: ["black"],
        time_basis: "received"
      }

      :ets.new(:overlay_test_state, [:set, :public, :named_table])
      on_exit(fn -> if :ets.whereis(:overlay_test_state) != :undefined, do: :ets.delete(:overlay_test_state) end)
      :ets.insert(:overlay_test_state, {:overlays, [window_det_1, window_det_2]})

      deps =
        stub_deps(%{
          coverage: fn source_id, params, _scope ->
            {:ok, populated_coverage(source_id, params.from_us, params.to_us, [block])}
          end,
          list_event_clips: fn _source_id, params, _scope ->
            {:ok, list_page_result([recording_clip, person_clip, missing_highlight_clip], params)}
          end,
          list_window_overlays: fn source_id, w_from, w_to, profile_id, _scope ->
            send(parent, {:window_overlays_queried, source_id, w_from, w_to, profile_id})
            [{:overlays, current}] = :ets.lookup(:overlay_test_state, :overlays)
            current
          end,
          get_frame_overlay: fn source_id, frame_id, _scope ->
            send(parent, {:frame_overlay_queried, source_id, frame_id})
            [highlight_det]
          end
        })

      socket = mount_connected(@camera_id, deps, refresh_interval_ms: 15_000, debounce_ms: 0)
      on_exit(fn -> cancel_timers(socket) end)

      # 1. Initial normal timeline playback loads window overlays without search or highlight_frame
      assert_receive {:window_overlays_queried, @camera_id, ^from_us, ^to_us, ""}
      refute_received {:frame_overlay_queried, _, _}
      assert socket.assigns.timeline_overlay_detections == [window_det_1, window_det_2]

      # 2. Selecting smart event clip loads window overlays in clip modal and skips redundant
      #    get_frame_overlay when frame_1_id is in window; open_clip_in_timeline focuses main stage
      {:noreply, smart_modal} =
        Recordings.handle_event("select_event_clip", %{"clip_id" => "evt-person-window"}, socket)

      expected_smart_from = det_start - 5_000_000
      expected_smart_to = det_end + 10_000_000
      assert_receive {:window_overlays_queried, @camera_id, ^expected_smart_from, ^expected_smart_to, ""}
      refute_received {:frame_overlay_queried, _, _}
      assert smart_modal.assigns.clip_modal.overlay_detections == [window_det_1, window_det_2]

      {:noreply, smart_selected} = Recordings.handle_event("open_clip_in_timeline", %{}, smart_modal)
      assert_receive {:window_overlays_queried, @camera_id, ^expected_smart_from, ^expected_smart_to, ""}
      refute_received {:frame_overlay_queried, _, _}
      assert smart_selected.assigns.timeline_overlay_detections == [window_det_1, window_det_2]

      # 3. Live refresh preserving window updates timeline_overlay_detections with newly indexed frames
      :ets.insert(:overlay_test_state, {:overlays, [window_det_1, window_det_2, extra_live_det]})
      token = smart_selected.assigns.recording_refresh_token
      {:noreply, refreshed} = Recordings.handle_info({:refresh_timeline_tick, token}, smart_selected)
      on_exit(fn -> cancel_timers(refreshed) end)

      assert_receive {:window_overlays_queried, @camera_id, ^expected_smart_from, ^expected_smart_to, ""}
      assert refreshed.assigns.timeline_overlay_detections == [window_det_1, window_det_2, extra_live_det]

      # 4. Selecting :recording segment (visual_frame_id == nil) still loads window overlays across [rec_start, rec_end]
      {:noreply, refreshed_all} = Recordings.handle_event("filter_event_clips_mode", %{"mode" => "all"}, refreshed)

      {:noreply, rec_modal} =
        Recordings.handle_event("select_event_clip", %{"clip_id" => "rec-seg-window"}, refreshed_all)

      assert_receive {:window_overlays_queried, @camera_id, ^rec_start, ^rec_end, ""}
      assert rec_modal.assigns.clip_modal.overlay_detections == [window_det_1, window_det_2, extra_live_det]

      # 5. When highlight_frame_id is not present in window overlays, get_frame_overlay is invoked and merged
      {:noreply, highlight_modal} =
        Recordings.handle_event("select_event_clip", %{"clip_id" => "evt-missing-highlight"}, rec_modal)

      assert_receive {:window_overlays_queried, @camera_id, _, _, ""}
      assert_receive {:frame_overlay_queried, @camera_id, ^missing_highlight_id}

      assert highlight_modal.assigns.clip_modal.overlay_detections == [
               highlight_det,
               window_det_1,
               window_det_2,
               extra_live_det
             ]
    end

    test "resets semantic search assigns and mobile switcher drawer when switching cameras via handle_params, and resets results when q changes on the same camera" do
      deps = stub_deps(%{})
      socket = mount_connected(@camera_id, deps, refresh_interval_ms: 0, debounce_ms: 0)
      on_exit(fn -> cancel_timers(socket) end)

      dirty_socket =
        assign(socket,
          timeline_search_query: "person in red",
          timeline_search_object_class: "person",
          timeline_search_results: [%{visual_frame_id: "f1", clip_start_us: 1, clip_end_us: 2}],
          timeline_search_executed?: true,
          timeline_search_error: "Semantic clip search is temporarily unavailable.",
          timeline_embedder_unavailable?: true,
          timeline_overlay_detections: [%{visual_frame_id: "f1", bbox: [0.1, 0.1, 0.2, 0.2]}],
          switcher_open_mobile?: true
        )

      # Changing "q" on the same camera resets search results/error/overlay state
      {:noreply, same_cam_new_q} =
        Recordings.handle_params(
          %{"camera_source_id" => @camera_id, "mode" => "timeline", "q" => ""},
          "/cameras/#{@camera_id}/recordings?mode=timeline&q=",
          dirty_socket
        )

      assert same_cam_new_q.assigns.timeline_search_query == ""
      assert same_cam_new_q.assigns.timeline_search_object_class == "person"
      assert same_cam_new_q.assigns.timeline_search_results == []
      assert same_cam_new_q.assigns.timeline_search_executed? == false
      assert same_cam_new_q.assigns.timeline_search_error == nil
      assert same_cam_new_q.assigns.timeline_embedder_unavailable? == false
      assert same_cam_new_q.assigns.timeline_overlay_detections == []
      assert same_cam_new_q.assigns.switcher_open_mobile? == true

      # Changing "object_class" without changing "q" resets and re-triggers semantic search
      parent = self()

      vehicle_hit = %{
        catalog_entry_id: "00000000-0000-4000-8000-000000000810",
        visual_frame_id: "00000000-0000-4000-8000-000000000811",
        camera_source_id: @camera_id,
        camera_display_name: "Synthetic Gate Camera",
        clip_start_us: @base_now_us - 60_000_000,
        clip_end_us: @base_now_us - 50_000_000,
        best_timeline_ts_us: @base_now_us - 55_000_000,
        time_basis: "received",
        score: 0.94,
        object_class: "vehicle",
        dominant_colors: ["silver"],
        bbox: [0.2, 0.3, 0.7, 0.8]
      }

      search_socket =
        assign(dirty_socket,
          camera_semantic_search_opts: [
            search_fn: fn search_params, _opts ->
              send(parent, {:semantic_search_ran, search_params})
              {:ok, [vehicle_hit]}
            end
          ]
        )

      {:noreply, same_cam_new_class} =
        Recordings.handle_params(
          %{"camera_source_id" => @camera_id, "mode" => "timeline", "object_class" => "vehicle"},
          "/cameras/#{@camera_id}/recordings?mode=timeline&object_class=vehicle",
          search_socket
        )

      assert_receive {:semantic_search_ran, search_params}
      assert search_params.query == "person in red"
      assert search_params.object_class == "vehicle"
      assert same_cam_new_class.assigns.timeline_search_query == "person in red"
      assert same_cam_new_class.assigns.timeline_search_object_class == "vehicle"
      assert same_cam_new_class.assigns.timeline_search_executed? == true
      assert same_cam_new_class.assigns.timeline_search_error == nil
      assert same_cam_new_class.assigns.timeline_embedder_unavailable? == false
      assert [%{object_class: "vehicle"}] = same_cam_new_class.assigns.timeline_search_results
      assert [%{object_class: "vehicle"}] = same_cam_new_class.assigns.timeline_overlay_detections

      # Switching cameras resets all semantic search assigns and mobile switcher drawer
      {:noreply, switched} =
        Recordings.handle_params(
          %{"camera_source_id" => @other_camera_id, "mode" => "timeline"},
          "/cameras/#{@other_camera_id}/recordings?mode=timeline",
          dirty_socket
        )

      on_exit(fn -> cancel_timers(switched) end)

      assert switched.assigns.camera_source_id == @other_camera_id
      assert switched.assigns.timeline_search_query == ""
      assert switched.assigns.timeline_search_object_class == ""
      assert switched.assigns.timeline_search_results == []
      assert switched.assigns.timeline_search_executed? == false
      assert switched.assigns.timeline_search_error == nil
      assert switched.assigns.timeline_embedder_unavailable? == false
      assert switched.assigns.timeline_overlay_detections == []
      assert switched.assigns.switcher_open_mobile? == false
    end
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
      started_at: DateTime.from_unix!(start_us, :microsecond),
      ended_at: DateTime.from_unix!(end_us, :microsecond),
      peak_ts_us: start_us + div(end_us - start_us, 2),
      duration_seconds: max(div(end_us - start_us, 1_000_000), 1),
      category: :person,
      smart_type: :smart,
      mode: "smart",
      label: "Person",
      confidence: 0.91,
      local_state: :present,
      archive_state: :pending,
      thumbnail_url: nil,
      visual_frame_id: nil,
      attributes: %{dominant_colors: ["navy"]}
    }
  end

  defp list_page_result(clips, params) do
    paged = RecordingEventClips.paginate_clips(clips, params)

    markers =
      clips
      |> Enum.reject(&(&1.category == :recording))
      |> Enum.map(fn clip ->
        %{
          id: clip.id,
          category: clip.category,
          smart_type: clip.smart_type,
          label: clip.label,
          confidence: clip.confidence,
          start_us: clip.start_us,
          end_us: clip.end_us,
          peak_ts_us: clip.peak_ts_us,
          visual_frame_id: clip.visual_frame_id
        }
      end)

    Map.put(paged, :markers, markers)
  end

  describe "workspace UX pass (in-place live, smart default, confidence slider, non-PTZ ROI grid)" do
    test "enters in-place live mode and exits automatically on exit_live_mode, Latest, seek, or clip selection" do
      from_us = @base_now_us - @hour_us
      to_us = @base_now_us
      block = playable_block(from_us, to_us, :verified)
      clip = sample_clip("evt-live-exit", from_us + 600_000_000, from_us + 610_000_000)

      deps =
        stub_deps(%{
          coverage: fn source_id, params, _scope ->
            {:ok, populated_coverage(source_id, params.from_us, params.to_us, [block])}
          end,
          list_event_clips: fn _source_id, params, _scope ->
            {:ok, list_page_result([clip], params)}
          end,
          open_source_preview: fn _scope, _source_id, _opts ->
            %{
              camera_source_id: @camera_id,
              label: "Camera",
              detail: "High",
              session: %{id: Ecto.UUID.generate(), status: :active, media_ingest_id: "ingest-live"},
              error: nil
            }
          end
        })

      socket = mount_connected(@camera_id, deps, refresh_interval_ms: 0, debounce_ms: 0)
      on_exit(fn -> cancel_timers(socket) end)

      refute socket.assigns.live_mode?

      {:noreply, live_socket} = Recordings.handle_event("enter_live_mode", %{}, socket)
      assert live_socket.assigns.live_mode? == true
      assert is_map(live_socket.assigns.live_tile)

      # Explicit one-click exit back to timeline
      {:noreply, exited} = Recordings.handle_event("exit_live_mode", %{}, live_socket)
      refute exited.assigns.live_mode?
      assert exited.assigns.live_tile == nil

      # Clicking Latest exits live mode
      {:noreply, live_again} = Recordings.handle_event("enter_live_mode", %{}, exited)
      assert live_again.assigns.live_mode? == true

      {:noreply, after_latest} =
        Recordings.handle_event("navigate_timeline_window", %{"direction" => "latest"}, live_again)

      refute after_latest.assigns.live_mode?

      # Clicking vertical timeline scrubber exits live mode
      {:noreply, live_seek} = Recordings.handle_event("enter_live_mode", %{}, after_latest)
      {:noreply, after_seek} = Recordings.handle_event("seek_timeline_fraction", %{"fraction" => 0.5}, live_seek)
      refute after_seek.assigns.live_mode?

      # Clicking an event clip card while in live mode opens the clip modal WITHOUT hijacking live mode
      {:noreply, live_clip} = Recordings.handle_event("enter_live_mode", %{}, after_seek)
      {:noreply, modal_over_live} = Recordings.handle_event("select_event_clip", %{"clip_id" => clip.id}, live_clip)
      assert modal_over_live.assigns.live_mode? == true
      assert modal_over_live.assigns.live_tile == live_clip.assigns.live_tile
      assert is_map(modal_over_live.assigns.clip_modal)
      assert modal_over_live.assigns.clip_modal.clip_id == clip.id

      # Closing the clip modal leaves live mode untouched
      {:noreply, closed_over_live} = Recordings.handle_event("close_clip_modal", %{}, modal_over_live)
      assert closed_over_live.assigns.clip_modal == nil
      assert closed_over_live.assigns.live_mode? == true

      # Clicking View in Timeline from the clip modal exits live mode and disables adjacent-window auto-advance
      {:noreply, reopened_modal} =
        Recordings.handle_event("select_event_clip", %{"clip_id" => clip.id}, closed_over_live)

      {:noreply, after_clip} = Recordings.handle_event("open_clip_in_timeline", %{}, reopened_modal)
      assert after_clip.assigns.clip_modal == nil
      refute after_clip.assigns.live_mode?
      assert after_clip.assigns.timeline_has_adjacent_window == false

      # Live refresh while an event clip is selected keeps timeline_has_adjacent_window false
      {:noreply, refreshed_clip} =
        Recordings.handle_info({:refresh_timeline_tick, after_clip.assigns.recording_refresh_token}, after_clip)

      assert refreshed_clip.assigns.timeline_has_adjacent_window == false

      # Selecting a semantic hit opens the clip modal and View in Timeline disables adjacent-window auto-advance
      {:noreply, hit_modal} =
        Recordings.handle_event(
          "select_timeline_semantic_hit",
          %{
            "seek_us" => Integer.to_string(from_us + 605_000_000),
            "start_us" => Integer.to_string(from_us + 600_000_000),
            "end_us" => Integer.to_string(from_us + 610_000_000),
            "frame_id" => Ecto.UUID.generate()
          },
          refreshed_clip
        )

      assert hit_modal.assigns.clip_modal.kind == :semantic_hit
      {:noreply, after_hit} = Recordings.handle_event("open_clip_in_timeline", %{}, hit_modal)
      assert after_hit.assigns.clip_modal == nil
      assert after_hit.assigns.timeline_has_adjacent_window == false
    end

    test "falls back gracefully to Motion or All when zero smart detections exist, and filters clips + overlays by confidence threshold" do
      from_us = @base_now_us - @hour_us
      to_us = @base_now_us
      block = playable_block(from_us, to_us, :verified)

      # 1. Zero smart events, 1 motion event -> falls back to Motion
      motion_clip =
        "evt-motion-only"
        |> sample_clip(from_us + 100_000_000, from_us + 110_000_000)
        |> Map.merge(%{category: :motion, smart_type: :basic, label: "Motion", confidence: nil})

      rec_clip =
        "rec-fallback-1"
        |> sample_clip(from_us + 200_000_000, from_us + 320_000_000)
        |> Map.merge(%{category: :recording, smart_type: :basic, label: "Recording", confidence: nil})

      motion_deps =
        stub_deps(%{
          coverage: fn source_id, params, _scope ->
            {:ok, populated_coverage(source_id, params.from_us, params.to_us, [block])}
          end,
          list_event_clips: fn _source_id, params, _scope ->
            {:ok, list_page_result([motion_clip, rec_clip], params)}
          end
        })

      motion_socket = mount_connected(@camera_id, motion_deps, refresh_interval_ms: 0, debounce_ms: 0)
      on_exit(fn -> cancel_timers(motion_socket) end)

      assert motion_socket.assigns.timeline_clips_mode == "basic"
      assert motion_socket.assigns.timeline_clips_category == "motion"
      assert Enum.map(motion_socket.assigns.timeline_event_clips, & &1.id) == ["evt-motion-only"]

      # 2. Confidence slider filters both smart clips and overlay detections
      high_clip = Map.put(sample_clip("evt-high", from_us + 300_000_000, from_us + 304_000_000), :confidence, 0.88)
      low_clip = Map.put(sample_clip("evt-low", from_us + 400_000_000, from_us + 404_000_000), :confidence, 0.42)

      high_det = %{
        visual_frame_id: "frame-high",
        timeline_ts_us: from_us + 300_000_000,
        start_us: from_us + 298_000_000,
        end_us: from_us + 302_000_000,
        bbox: [0.1, 0.1, 0.4, 0.4],
        object_class: "person",
        score: 0.88,
        dominant_colors: [],
        time_basis: "received"
      }

      low_det = %{high_det | visual_frame_id: "frame-low", score: 0.42}

      conf_deps =
        stub_deps(%{
          coverage: fn source_id, params, _scope ->
            {:ok, populated_coverage(source_id, params.from_us, params.to_us, [block])}
          end,
          list_event_clips: fn _source_id, params, _scope ->
            {:ok, list_page_result([high_clip, low_clip], params)}
          end,
          list_window_overlays: fn _source_id, _from, _to, _profile, _scope ->
            [high_det, low_det]
          end
        })

      conf_socket = mount_connected(@camera_id, conf_deps, refresh_interval_ms: 0, debounce_ms: 0)
      on_exit(fn -> cancel_timers(conf_socket) end)

      # Default 50% keeps high (0.88) and filters out low (0.42)
      assert conf_socket.assigns.timeline_min_confidence == 50
      assert Enum.map(conf_socket.assigns.timeline_event_clips, & &1.id) == ["evt-high"]
      assert Enum.map(conf_socket.assigns.timeline_overlay_detections, & &1.visual_frame_id) == ["frame-high"]

      # Lowering slider to 35% reveals both clips and both overlays
      {:noreply, lowered} = Recordings.handle_event("set_min_confidence", %{"min_confidence" => "35"}, conf_socket)
      assert lowered.assigns.timeline_min_confidence == 35
      assert Enum.map(lowered.assigns.timeline_event_clips, & &1.id) == ["evt-high", "evt-low"]

      assert Enum.map(lowered.assigns.timeline_overlay_detections, & &1.visual_frame_id) == [
               "frame-high",
               "frame-low"
             ]
    end

    test "toggles, resets, clears, and persists non-PTZ ROI detection zones while blocking PTZ cameras" do
      parent = self()

      deps =
        stub_deps(%{
          save_roi_grid: fn source, payload, _scope ->
            send(parent, {:roi_saved, source.id, payload})
            {:ok, Map.put(source, :metadata, Map.put(Map.get(source, :metadata) || %{}, "detection_roi_grid", payload))}
          end
        })

      socket = mount_connected(@camera_id, deps, refresh_interval_ms: 0, debounce_ms: 0)
      on_exit(fn -> cancel_timers(socket) end)

      {:noreply, opened} = Recordings.handle_event("toggle_roi_drawer", %{}, socket)
      assert opened.assigns.roi_drawer_open? == true
      assert opened.assigns.roi_paint_mode == "focus"

      # Paint cell 5 as focus
      {:noreply, s1} = Recordings.handle_event("roi_toggle_cell", %{"cell" => "5"}, opened)
      assert MapSet.member?(s1.assigns.roi_focus_cells, 5)

      # Switch to ignore mode and paint cell 12 as ignore
      {:noreply, s2} = Recordings.handle_event("roi_set_paint_mode", %{"mode" => "ignore"}, s1)
      {:noreply, s3} = Recordings.handle_event("roi_toggle_cell", %{"cell" => "12"}, s2)
      assert MapSet.member?(s3.assigns.roi_ignore_cells, 12)

      # View-only scope cannot save detection zones
      {:noreply, denied} = Recordings.handle_event("roi_save_grid", %{}, s3)
      assert denied.assigns.roi_feedback == "Not authorized to edit detection zones."
      refute_received {:roi_saved, _, _}

      # Operator with recording manage permission can save
      manager_scope = %{
        s3.assigns.current_scope
        | permissions: MapSet.put(s3.assigns.current_scope.permissions, "settings.recording.manage")
      }

      {:noreply, saved} = Recordings.handle_event("roi_save_grid", %{}, assign(s3, :current_scope, manager_scope))

      assert_receive {:roi_saved, @camera_id,
                      %{"version" => 1, "cols" => 12, "rows" => 8, "focus" => [5], "ignore" => [12]}}

      assert saved.assigns.roi_feedback == "Detection zones saved."

      # Clear removes draft cells, Reset restores saved cells
      {:noreply, cleared} = Recordings.handle_event("roi_clear_grid", %{}, saved)
      assert MapSet.size(cleared.assigns.roi_focus_cells) == 0
      assert MapSet.size(cleared.assigns.roi_ignore_cells) == 0

      {:noreply, restored} = Recordings.handle_event("roi_reset_grid", %{}, cleared)
      assert MapSet.member?(restored.assigns.roi_focus_cells, 5)
      assert MapSet.member?(restored.assigns.roi_ignore_cells, 12)

      # PTZ camera detection helper and save guard
      assert Recordings.ptz_camera?(%{metadata: %{"ptz" => true}})
      assert Recordings.ptz_camera?(%{metadata: %{"capabilities" => ["pan_tilt_zoom"]}})
      refute Recordings.ptz_camera?(%{metadata: %{"site" => "lab"}})

      ptz_deps =
        stub_deps(%{
          authorize_timeline_view: fn sock ->
            {:ok, sock.assigns.current_scope,
             Map.put(synthetic_source(sock.assigns.camera_source_id), :metadata, %{"ptz" => true})}
          end
        })

      {:noreply, ptz_blocked} =
        Recordings.handle_event(
          "roi_save_grid",
          %{},
          saved |> assign(:current_scope, manager_scope) |> assign(:recordings_deps, ptz_deps)
        )

      assert ptz_blocked.assigns.roi_feedback == "Detection zones are not applicable for PTZ cameras."
    end

    test "set_timeline_zoom slider maps 0..4 smoothly between 7d and 15m spans" do
      deps =
        stub_deps(%{
          coverage: fn source_id, params, _scope ->
            {:ok, empty_coverage(source_id, params.from_us, params.to_us)}
          end
        })

      socket = mount_connected(@camera_id, deps, refresh_interval_ms: 60_000, debounce_ms: 0)
      on_exit(fn -> cancel_timers(socket) end)

      for {zoom_val, expected_span} <- [{"0", "7d"}, {"1", "24h"}, {"2", "6h"}, {"3", "1h"}, {"4", "15m"}] do
        {:noreply, updated} = Recordings.handle_event("set_timeline_zoom", %{"zoom" => zoom_val}, socket)
        assert updated.assigns.timeline_span == expected_span
      end
    end

    test "select_timeline_semantic_hit focuses playback onto a tight padded clip window instead of the full 1h coverage span" do
      from_us = @base_now_us - @hour_us
      to_us = @base_now_us
      block = playable_block(from_us, to_us, :verified)

      deps =
        stub_deps(%{
          coverage: fn source_id, params, _scope ->
            {:ok, populated_coverage(source_id, params.from_us, params.to_us, [block])}
          end
        })

      socket = mount_connected(@camera_id, deps, refresh_interval_ms: 60_000, debounce_ms: 0)
      on_exit(fn -> cancel_timers(socket) end)

      clip_start_us = from_us + 1_200_000_000
      clip_end_us = clip_start_us + 10_000_000
      seek_us = clip_start_us + 4_000_000

      orig_from = socket.assigns.timeline_play_from_us
      orig_to = socket.assigns.timeline_play_to_us

      {:noreply, modal_socket} =
        Recordings.handle_event(
          "select_timeline_semantic_hit",
          %{
            "start_us" => Integer.to_string(clip_start_us),
            "end_us" => Integer.to_string(clip_end_us),
            "seek_us" => Integer.to_string(seek_us),
            "frame_id" => Ecto.UUID.generate()
          },
          socket
        )

      # Main stage timeline window is untouched while clip modal holds tight padded 25s window
      assert modal_socket.assigns.timeline_play_from_us == orig_from
      assert modal_socket.assigns.timeline_play_to_us == orig_to
      assert modal_socket.assigns.clip_modal.play_from_us == clip_start_us - 5_000_000
      assert modal_socket.assigns.clip_modal.play_to_us == clip_end_us + 10_000_000
      assert modal_socket.assigns.clip_modal.seek_us == seek_us
      assert modal_socket.assigns.clip_modal.play_to_us - modal_socket.assigns.clip_modal.play_from_us == 25_000_000

      # View in Timeline closes modal and focuses main stage onto that exact tight clip window
      {:noreply, focused} = Recordings.handle_event("open_clip_in_timeline", %{}, modal_socket)
      assert focused.assigns.clip_modal == nil
      assert focused.assigns.timeline_play_from_us == clip_start_us - 5_000_000
      assert focused.assigns.timeline_play_to_us == clip_end_us + 10_000_000
      assert focused.assigns.timeline_seek_us == seek_us
      assert focused.assigns.timeline_play_to_us - focused.assigns.timeline_play_from_us == 25_000_000
    end
  end

  describe "detection clips mode and category reconciliation" do
    test "selecting Motion while Smart is active switches mode to basic" do
      parent = self()

      deps =
        stub_deps(%{
          list_event_clips: fn _source_id, params, _scope ->
            send(parent, {:clips_queried, params.mode, params.category})
            {:ok, list_page_result([sample_clip("clip-1", @base_now_us - 60_000_000, @base_now_us - 50_000_000)], params)}
          end
        })

      socket = mount_connected(@camera_id, deps, refresh_interval_ms: 0, debounce_ms: 0)
      on_exit(fn -> cancel_timers(socket) end)

      assert_receive {:clips_queried, "smart", "all"}
      assert socket.assigns.timeline_clips_mode == "smart"
      assert socket.assigns.timeline_clips_category == "all"

      {:noreply, updated} = Recordings.handle_event("filter_event_clips_category", %{"category" => "motion"}, socket)
      assert_receive {:clips_queried, "basic", "motion"}
      assert updated.assigns.timeline_clips_mode == "basic"
      assert updated.assigns.timeline_clips_category == "motion"
    end

    test "selecting Smart while Motion is active resets category to all and preserves reconciliation across span change" do
      parent = self()
      smart_clip = sample_clip("clip-smart-6h", @base_now_us - 3 * @hour_us, @base_now_us - 3 * @hour_us + 10_000_000)

      motion_clip =
        Map.merge(
          sample_clip("clip-motion-1h", @base_now_us - 60_000_000, @base_now_us - 50_000_000),
          %{category: :motion, smart_type: :basic}
        )

      deps =
        stub_deps(%{
          list_event_clips: fn _source_id, params, _scope ->
            send(parent, {:clips_queried, params.to_us - params.from_us, params.mode, params.category})

            if params.to_us - params.from_us > @hour_us do
              clips = if params.mode == "smart" and params.category == "all", do: [smart_clip], else: []

              {:ok,
               %{
                 clips: clips,
                 total_count: length(clips),
                 page: params.page,
                 per_page: params.per_page,
                 total_pages: 1,
                 counts: %{all: 2, smart: 1, basic: 1, person: 1, motion: 1},
                 markers: clips
               }}
            else
              clips = if params.mode == "basic" and params.category in ["all", "motion"], do: [motion_clip], else: []

              {:ok,
               %{
                 clips: clips,
                 total_count: length(clips),
                 page: params.page,
                 per_page: params.per_page,
                 total_pages: 1,
                 counts: %{all: 1, smart: 0, basic: 1, person: 0, motion: 1},
                 markers: clips
               }}
            end
          end
        })

      socket = mount_connected(@camera_id, deps, refresh_interval_ms: 0, debounce_ms: 0)
      on_exit(fn -> cancel_timers(socket) end)

      # Initial 1h window has only motion clips, so smart-default selects basic + motion.
      assert_receive {:clips_queried, @hour_us, "smart", "all"}
      assert_receive {:clips_queried, @hour_us, "basic", "motion"}
      assert socket.assigns.timeline_clips_mode == "basic"
      assert socket.assigns.timeline_clips_category == "motion"

      # Clicking Smart resets category from motion to all.
      {:noreply, smart_socket} = Recordings.handle_event("filter_event_clips_mode", %{"mode" => "smart"}, socket)
      assert_receive {:clips_queried, @hour_us, "smart", "all"}
      assert smart_socket.assigns.timeline_clips_mode == "smart"
      assert smart_socket.assigns.timeline_clips_category == "all"

      # Switching span from 1h to 6h reloads clips with reconciled (smart, all) and returns smart clips.
      {:noreply, span_6h} = Recordings.handle_event("select_timeline_span", %{"span" => "6h"}, smart_socket)
      six_hours_us = 6 * @hour_us
      assert_receive {:clips_queried, ^six_hours_us, "smart", "all"}
      assert span_6h.assigns.timeline_clips_mode == "smart"
      assert span_6h.assigns.timeline_clips_category == "all"
      assert Enum.map(span_6h.assigns.timeline_event_clips, & &1.id) == ["clip-smart-6h"]
    end

    test "selecting Person while Basic is active switches mode to smart" do
      parent = self()

      deps =
        stub_deps(%{
          list_event_clips: fn _source_id, params, _scope ->
            send(parent, {:clips_queried, params.mode, params.category})
            {:ok, list_page_result([sample_clip("clip-1", @base_now_us - 60_000_000, @base_now_us - 50_000_000)], params)}
          end
        })

      socket = mount_connected(@camera_id, deps, refresh_interval_ms: 0, debounce_ms: 0)
      on_exit(fn -> cancel_timers(socket) end)
      assert_receive {:clips_queried, "smart", "all"}

      {:noreply, basic_socket} = Recordings.handle_event("filter_event_clips_mode", %{"mode" => "basic"}, socket)
      assert_receive {:clips_queried, "basic", "all"}
      assert basic_socket.assigns.timeline_clips_mode == "basic"

      {:noreply, person_socket} =
        Recordings.handle_event("filter_event_clips_category", %{"category" => "person"}, basic_socket)

      assert_receive {:clips_queried, "smart", "person"}
      assert person_socket.assigns.timeline_clips_mode == "smart"
      assert person_socket.assigns.timeline_clips_category == "person"
    end

    test "selecting Basic while Person is active resets category to all" do
      parent = self()

      deps =
        stub_deps(%{
          list_event_clips: fn _source_id, params, _scope ->
            send(parent, {:clips_queried, params.mode, params.category})
            {:ok, list_page_result([sample_clip("clip-1", @base_now_us - 60_000_000, @base_now_us - 50_000_000)], params)}
          end
        })

      socket = mount_connected(@camera_id, deps, refresh_interval_ms: 0, debounce_ms: 0)
      on_exit(fn -> cancel_timers(socket) end)
      assert_receive {:clips_queried, "smart", "all"}

      {:noreply, person_socket} =
        Recordings.handle_event("filter_event_clips_category", %{"category" => "person"}, socket)

      assert_receive {:clips_queried, "smart", "person"}
      assert person_socket.assigns.timeline_clips_mode == "smart"
      assert person_socket.assigns.timeline_clips_category == "person"

      {:noreply, basic_socket} =
        Recordings.handle_event("filter_event_clips_mode", %{"mode" => "basic"}, person_socket)

      assert_receive {:clips_queried, "basic", "all"}
      assert basic_socket.assigns.timeline_clips_mode == "basic"
      assert basic_socket.assigns.timeline_clips_category == "all"
    end
  end

  describe "non-blocking live-first mount (mode=live)" do
    test "starts live stream immediately and defers timeline and switcher queries into :load_timeline_data async task" do
      {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)

      if Process.whereis(ServiceRadar.PubSub) == nil do
        start_supervised!({Phoenix.PubSub, name: ServiceRadar.PubSub})
      end

      parent = self()

      deps =
        stub_deps(%{
          authorize_timeline_view: fn socket ->
            scope = %{
              socket.assigns.current_scope
              | permissions: MapSet.put(socket.assigns.current_scope.permissions, "devices.cameras.view")
            }

            {:ok, scope, synthetic_source(socket.assigns.camera_source_id)}
          end,
          open_source_preview: fn _scope, _source_id, _opts ->
            %{
              camera_source_id: @camera_id,
              label: "Camera",
              detail: "High",
              session: %{id: Ecto.UUID.generate(), status: :active, media_ingest_id: "ingest-async"},
              error: nil
            }
          end,
          coverage: fn _source_id, _params, _scope ->
            send(parent, :coverage_called_sync)
            {:ok, empty_coverage(@camera_id, @base_now_us - @hour_us, @base_now_us)}
          end,
          list_holds: fn _source_id, _scope ->
            send(parent, :holds_called_sync)
            {:ok, []}
          end,
          list_event_clips: fn _source_id, params, _scope ->
            send(parent, :clips_called_sync)
            {:ok, list_page_result([], params)}
          end,
          list_cameras: fn _scope, _opts ->
            send(parent, :cameras_called_sync)
            {:ok, %{cameras: [], total_count: 0, total_pages: 1, page: 1, per_page: 20}}
          end
        })

      socket =
        mount_connected(@camera_id, deps,
          params: %{"camera_source_id" => @camera_id, "mode" => "live"},
          refresh_interval_ms: 15_000,
          debounce_ms: 0
        )

      on_exit(fn -> cancel_timers(socket) end)

      # Initial connected render is ready immediately in live mode without blocking on heavy timeline queries.
      assert socket.assigns.loading == false
      assert socket.assigns.mode == :timeline
      assert socket.assigns.live_mode? == true
      assert socket.assigns.source.id == @camera_id
      assert is_map(socket.assigns.live_tile)
      assert socket.assigns.timeline_coverage == nil
      assert socket.assigns.switcher_cameras == []

      refute_received :coverage_called_sync
      refute_received :holds_called_sync
      refute_received :clips_called_sync
      refute_received :cameras_called_sync

      # Only :camera_live_open is queued initially so timeline DB queries do not contend with WebRTC startup.
      async_names =
        socket.private
        |> Map.get(:live_async, %{})
        |> Map.keys()

      assert :camera_live_open in async_names
      refute :load_timeline_data in async_names

      # Completing :camera_live_open pushes any preloaded WebRTC offer via push_event and then starts :load_timeline_data.
      relay_session_id = Ecto.UUID.generate()
      viewer_session_id = Ecto.UUID.generate()

      live_tile = %{
        label: "Camera",
        detail: "High",
        session: %{id: relay_session_id, status: :active, media_ingest_id: "ingest-1"},
        error: nil
      }

      preloaded_offer = %{
        "relay_session_id" => relay_session_id,
        "viewer_session_id" => viewer_session_id,
        "offer_sdp" => "v=0\r\nm=video",
        "signaling_path" => "/api/camera-relay-sessions/#{relay_session_id}/webrtc/session",
        "transport" => "membrane_webrtc"
      }

      {:noreply, with_live_tile} =
        Recordings.handle_async(:camera_live_open, {:ok, {live_tile, preloaded_offer}}, socket)

      assert with_live_tile.assigns.live_tile == live_tile
      assert with_live_tile.assigns.pending_deferred_timeline_load? == false

      after_open_async_names =
        with_live_tile.private
        |> Map.get(:live_async, %{})
        |> Map.keys()

      assert :load_timeline_data in after_open_async_names

      pushed_events = get_in(with_live_tile.private, [:live_temp, :push_events]) || []

      assert [
               [
                 "camera-relay:webrtc-offer",
                 %{
                   "signaling_path" => "/api/camera-relay-sessions/" <> _,
                   "data" => ^preloaded_offer
                 }
               ]
             ] = pushed_events

      cov = populated_coverage(@camera_id, @base_now_us - @hour_us, @base_now_us, [])
      clip = sample_clip("clip-deferred-1", @base_now_us - 60_000_000, @base_now_us - 50_000_000)
      other_cam = synthetic_source(@other_camera_id)

      {:noreply, hydrated} =
        Recordings.handle_async(
          :load_timeline_data,
          {:ok,
           {@camera_id,
            [switcher_cameras: [other_cam], switcher_total_count: 1, switcher_total_pages: 1, switcher_page: 1],
            {:ok, [timeline_coverage: cov, timeline_event_clips: [clip]]}}},
          with_live_tile
        )

      assert hydrated.assigns.live_mode? == true
      assert hydrated.assigns.live_tile == live_tile
      assert hydrated.assigns.timeline_coverage == cov
      assert hydrated.assigns.timeline_event_clips == [clip]
      assert hydrated.assigns.switcher_cameras == [other_cam]

      # Stale :load_timeline_data results for a different camera are ignored.
      {:noreply, ignored_stale} =
        Recordings.handle_async(
          :load_timeline_data,
          {:ok, {@other_camera_id, [switcher_cameras: []], {:ok, [timeline_coverage: nil]}}},
          hydrated
        )

      assert ignored_stale.assigns.timeline_coverage == cov
      assert ignored_stale.assigns.switcher_cameras == [other_cam]

      # Deferred task exit logs a warning and keeps the live stream intact.
      {{:noreply, after_exit}, log} =
        with_log(fn ->
          Recordings.handle_async(:load_timeline_data, {:exit, :timeout}, hydrated)
        end)

      assert log =~ "Deferred camera timeline load exited"
      assert after_exit.assigns.live_mode? == true
      assert after_exit.assigns.live_tile == live_tile
    end
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
