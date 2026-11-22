defmodule ServiceRadar.Camera.RecordingPubSubTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Camera.RecordingPubSub

  @camera_id "00000000-0000-4000-8000-000000000501"
  @other_camera_id "00000000-0000-4000-8000-000000000502"

  describe "topic/1" do
    test "formats valid camera_source_id and rejects blank or non-binary values" do
      assert RecordingPubSub.topic(@camera_id) == "camera:recordings:#{@camera_id}"
      assert RecordingPubSub.topic("") == nil
      assert RecordingPubSub.topic(nil) == nil
      assert RecordingPubSub.topic(123) == nil
    end
  end

  describe "best-effort behavior when PubSub is not running" do
    test "broadcast_updated/2 and unsubscribe/1 succeed as no-ops and subscribe/1 reports unavailable" do
      if Process.whereis(ServiceRadar.PubSub) == nil do
        assert :ok = RecordingPubSub.broadcast_updated(@camera_id, :block_cataloged)
        assert :ok = RecordingPubSub.unsubscribe(@camera_id)
        assert {:error, :pubsub_unavailable} = RecordingPubSub.subscribe(@camera_id)
      end

      assert :ok = RecordingPubSub.broadcast_updated(nil, :block_cataloged)
      assert :ok = RecordingPubSub.broadcast_updated(@camera_id, "not_an_atom")
      assert {:error, :invalid_camera_source_id} = RecordingPubSub.subscribe("")
    end
  end

  describe "subscribe/1, unsubscribe/1, and broadcast_updated/2" do
    test "delivers lightweight camera_recording_updated events to subscribers and stops after unsubscribe" do
      {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)

      if Process.whereis(ServiceRadar.PubSub) == nil do
        start_supervised!({Phoenix.PubSub, name: ServiceRadar.PubSub})
      end

      assert :ok = RecordingPubSub.subscribe(@camera_id)
      assert :ok = RecordingPubSub.broadcast_updated(@camera_id, :block_cataloged)

      assert_receive {:camera_recording_updated,
                      %{camera_source_id: @camera_id, reason: :block_cataloged}}

      assert :ok = RecordingPubSub.broadcast_updated(@other_camera_id, :archive_verified)
      refute_received {:camera_recording_updated, %{camera_source_id: @other_camera_id}}

      assert :ok = RecordingPubSub.unsubscribe(@camera_id)
      assert :ok = RecordingPubSub.broadcast_updated(@camera_id, :archive_verified)
      refute_received {:camera_recording_updated, %{camera_source_id: @camera_id}}
    end
  end
end
