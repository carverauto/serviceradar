defmodule ServiceRadar.Observability.NetflowInterfaceCacheRefreshDbTest do
  use ServiceRadar.DataCase, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Observability.NetflowInterfaceCacheRefreshWorker, as: Worker
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    now = DateTime.utc_now()
    uid = "sr:" <> Ecto.UUID.generate()
    ip = "192.0.2.87"

    Repo.insert_all(
      "ocsf_devices",
      [
        %{uid: uid, ip: ip, type_id: 0, first_seen_time: now, last_seen_time: now}
      ],
      prefix: "platform"
    )

    Repo.insert_all(
      "discovered_interfaces",
      [
        %{
          device_id: uid,
          interface_uid: "name:uplink-test",
          timestamp: now,
          if_index: 17,
          if_name: "uplink-test",
          speed_bps: 25_000_000_000
        }
      ],
      prefix: "platform"
    )

    assert {:ok, 1} =
             Worker.record_observed_interface_pairs([
               %{sampler_address: ip, ocsf_payload: %{"connection_info" => %{"input_snmp" => 17}}}
             ])

    # Isolate the self-rescheduling chain inside this test's rollback-only sandbox.
    Repo.query!("DELETE FROM platform.oban_jobs WHERE worker = $1", [
      Oban.Worker.to_string(Worker)
    ])

    {:ok, ip: ip}
  end

  test "refresh persists a high-speed interface and schedules its next cycle", %{ip: ip} do
    assert :ok = Worker.perform(executing_job(1))

    assert %{rows: [[25_000_000_000, "uplink-test"]]} =
             Repo.query!(
               "SELECT if_speed_bps, if_name FROM platform.netflow_interface_cache WHERE sampler_address = $1 AND if_index = 17",
               [ip]
             )

    assert scheduled_count() == 1
  end

  test "a rejected refresh reports failure without scheduling a competing retry", %{ip: ip} do
    reject_speed_writes()

    log =
      capture_log(fn ->
        assert {:error, {:interface_cache_upsert_failed, [_ | _]}} =
                 Worker.perform(executing_job(1))
      end)

    assert log =~ "upsert failed"
    refute log =~ ip
    refute log =~ "uplink-test"
    assert scheduled_count() == 0
  end

  test "the final failed attempt preserves the periodic chain without claiming success" do
    reject_speed_writes()

    assert {:error, {:interface_cache_upsert_failed, [_ | _]}} =
             Worker.perform(executing_job(3))

    assert scheduled_count() == 1
  end

  defp reject_speed_writes do
    # Recreate the old storage boundary. Encoding fails before SQL changes any row.
    Repo.query!(
      "ALTER TABLE platform.netflow_interface_cache ALTER COLUMN if_speed_bps TYPE integer"
    )
  end

  defp executing_job(attempt) do
    %{}
    |> Worker.new()
    |> Ecto.Changeset.change(
      state: "executing",
      attempt: attempt,
      attempted_at: DateTime.utc_now()
    )
    |> Repo.insert!(prefix: "platform")
  end

  defp scheduled_count do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM platform.oban_jobs WHERE worker = $1 AND state = 'scheduled'",
        [Oban.Worker.to_string(Worker)]
      )

    count
  end
end
