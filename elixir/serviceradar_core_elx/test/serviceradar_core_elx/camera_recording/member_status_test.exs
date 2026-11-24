defmodule ServiceRadarCoreElx.CameraRecording.MemberStatusTest do
  use ExUnit.Case, async: true

  alias ServiceRadarCoreElx.CameraRecording.MemberStatus

  test "fetch_all returns sanitized status for matching storage_id and omits unreachable or mismatched members" do
    sid_ok = "00000000-0000-4000-8000-000000000801"
    sid_mismatch = "00000000-0000-4000-8000-000000000802"
    sid_down = "00000000-0000-4000-8000-000000000803"

    targets = [
      %{member: "nvr-0", storage_id: sid_ok, client_config: :cfg_ok},
      %{member: "nvr-1", storage_id: sid_mismatch, client_config: :cfg_mismatch},
      %{member: "nvr-2", storage_id: sid_down, client_config: :cfg_down}
    ]

    status_fn = fn
      :cfg_ok, 2_500 ->
        {:ok,
         %{
           storage_id: sid_ok,
           recovery: %{state: :ready, generation: "00000000-0000-4000-8000-000000000099"},
           inventory: :ready,
           capacity: %{
             used_bytes: 1024,
             max_spool_bytes: 4096,
             available_bytes: 2048,
             reserve_bytes: 512,
             reserved_bytes: 0,
             reservations: 0,
             blocks: 4,
             max_blocks: 100
           },
           max_sessions: 8,
           archive_busy: false,
           release: "1.0.0"
         }}

      :cfg_mismatch, 2_500 ->
        {:ok, %{storage_id: "00000000-0000-4000-8000-000000000999", inventory: :ready, capacity: nil}}

      :cfg_down, 2_500 ->
        {:error, :unavailable}
    end

    result =
      MemberStatus.fetch_all(
        timeout_ms: 2_500,
        targets_loader: fn -> {:ok, targets} end,
        status_fn: status_fn
      )

    assert Map.keys(result) == [sid_ok]
    assert result[sid_ok].inventory == :ready
    assert result[sid_ok].capacity.used_bytes == 1024
  end

  test "fetch_all returns empty map when NVR client config is not configured" do
    assert MemberStatus.fetch_all(targets_loader: fn -> {:error, :nvr_client_not_configured} end) == %{}
  end
end
