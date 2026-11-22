defmodule ServiceRadarWebNGWeb.CameraRecordingsLiveUnitTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveViewTest, only: [render_component: 2]

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
        list_cameras: fn _, _ -> flunk("disconnected mount/params must not list cameras") end,
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
          list_event_clips: fn _source_id, _params, _scope ->
            clips =
              if Agent.get(phase, & &1) == :initial do
                [initial_clip]
              else
                [initial_clip, new_clip]
              end

            {:ok, %{clips: clips}}
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
            {:ok, %{clips: all_clips}}
          end
        })

      socket = mount_connected(@camera_id, deps, refresh_interval_ms: 0, debounce_ms: 0)
      on_exit(fn -> cancel_timers(socket) end)

      assert_receive {:clips_queried, 1, 12, "all", "all"}
      assert length(socket.assigns.timeline_event_clips) == 12
      assert socket.assigns.timeline_clips_total_count == 25
      assert socket.assigns.timeline_clips_total_pages == 3
      assert socket.assigns.timeline_clips_page == 1

      {:noreply, page2} = Recordings.handle_event("paginate_event_clips", %{"page" => "2"}, socket)
      assert_receive {:clips_queried, 2, 12, "all", "all"}
      assert page2.assigns.timeline_clips_page == 2
      assert length(page2.assigns.timeline_event_clips) == 12

      {:noreply, page3} = Recordings.handle_event("paginate_event_clips", %{"page" => "3"}, page2)
      assert_receive {:clips_queried, 3, 12, "all", "all"}
      assert page3.assigns.timeline_clips_page == 3
      assert length(page3.assigns.timeline_event_clips) == 1

      # Switching filter resets page back to 1
      {:noreply, filtered} = Recordings.handle_event("filter_event_clips_mode", %{"mode" => "smart"}, page3)
      assert_receive {:clips_queried, 1, 12, "smart", "all"}
      assert filtered.assigns.timeline_clips_page == 1
    end

    test "camera switcher supports debounced search, status filter, and bounded pagination, and manage drawer toggles cleanly" do
      parent = self()

      deps =
        stub_deps(%{
          list_cameras: fn _scope, opts ->
            send(parent, {:cameras_queried, opts.search, opts.filter, opts.page, opts.per_page})

            {:ok,
             %{
               cameras: [synthetic_source(@other_camera_id)],
               recording_ids: MapSet.new([@other_camera_id]),
               total_count: 45,
               page: opts.page,
               per_page: opts.per_page,
               total_pages: 3
             }}
          end
        })

      socket = mount_connected(@camera_id, deps, refresh_interval_ms: 0, debounce_ms: 0)
      on_exit(fn -> cancel_timers(socket) end)

      assert_receive {:cameras_queried, "", "all", 1, 20}
      assert socket.assigns.switcher_total_count == 45
      assert socket.assigns.switcher_total_pages == 3

      {:noreply, searched} = Recordings.handle_event("switcher_search", %{"search" => "gate"}, socket)
      assert_receive {:cameras_queried, "gate", "all", 1, 20}
      assert searched.assigns.switcher_search == "gate"

      {:noreply, filtered} = Recordings.handle_event("switcher_filter", %{"filter" => "recording"}, searched)
      assert_receive {:cameras_queried, "gate", "recording", 1, 20}
      assert filtered.assigns.switcher_filter == "recording"

      {:noreply, page2} = Recordings.handle_event("switcher_paginate", %{"page" => "2"}, filtered)
      assert_receive {:cameras_queried, "gate", "recording", 2, 20}
      assert page2.assigns.switcher_page == 2

      {:noreply, opened} = Recordings.handle_event("toggle_manage_drawer", %{}, page2)
      assert opened.assigns.timeline_manage_drawer_open? == true

      {:noreply, closed} = Recordings.handle_event("close_manage_drawer", %{}, opened)
      assert closed.assigns.timeline_manage_drawer_open? == false
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
          list_event_clips: fn _source_id, _params, _scope ->
            {:ok, %{clips: [recording_clip, person_clip]}}
          end
        })

      socket = mount_connected(@camera_id, deps, refresh_interval_ms: 0, debounce_ms: 0)
      on_exit(fn -> cancel_timers(socket) end)

      # Recording segment opens exact [start_us, end_us] without pre/post-roll padding
      {:noreply, rec_selected} =
        Recordings.handle_event("select_event_clip", %{"clip_id" => "rec-seg-exact"}, socket)

      assert rec_selected.assigns.timeline_play_from_us == rec_start
      assert rec_selected.assigns.timeline_play_to_us == rec_end

      # Smart detection clip retains 5s pre-roll and 10s post-roll context padding
      {:noreply, det_selected} =
        Recordings.handle_event("select_event_clip", %{"clip_id" => "evt-person-pad"}, socket)

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
        list_event_clips: fn _source_id, _params, _scope -> {:ok, %{clips: []}} end,
        list_cameras: fn _scope, _opts ->
          {:ok,
           %{
             cameras: [],
             recording_ids: MapSet.new(),
             total_count: 0,
             page: 1,
             per_page: 20,
             total_pages: 1
           }}
        end,
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
