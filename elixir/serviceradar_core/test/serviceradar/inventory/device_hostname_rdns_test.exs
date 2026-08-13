defmodule ServiceRadar.Inventory.DeviceHostnameRdnsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.DeviceHostnameRdns

  test "candidate? skips devices without an IP or with a real hostname" do
    settings = %{overwrite_existing: false, retry_after_minutes: 1_440}
    now = ~U[2026-08-13 12:00:00Z]

    refute DeviceHostnameRdns.candidate?(%{ip: nil, hostname: nil, metadata: %{}}, settings, now)

    refute DeviceHostnameRdns.candidate?(
             %{ip: "10.0.0.8", hostname: "leaf-01", metadata: %{}},
             settings,
             now
           )

    assert DeviceHostnameRdns.candidate?(
             %{ip: "10.0.0.8", hostname: nil, metadata: %{}},
             settings,
             now
           )

    assert DeviceHostnameRdns.candidate?(
             %{ip: "10.0.0.8", hostname: "10.0.0.8", metadata: %{}},
             settings,
             now
           )
  end

  test "candidate? honors overwrite_existing and retry window" do
    now = ~U[2026-08-13 12:00:00Z]

    refute DeviceHostnameRdns.candidate?(
             %{
               ip: "10.0.0.8",
               hostname: nil,
               metadata: %{"rdns" => %{"looked_up_at" => "2026-08-13T11:30:00Z"}}
             },
             %{overwrite_existing: false, retry_after_minutes: 1_440},
             now
           )

    assert DeviceHostnameRdns.candidate?(
             %{ip: "10.0.0.8", hostname: "leaf-01", metadata: %{}},
             %{overwrite_existing: true, retry_after_minutes: 1_440},
             now
           )
  end

  test "result_attrs sets hostname for a usable PTR" do
    now = ~U[2026-08-13 12:00:00Z]
    device = %{ip: "10.0.0.8", hostname: nil, metadata: %{}}

    assert {:update, attrs} =
             DeviceHostnameRdns.result_attrs(device, "core-sw.farm.lan", "ok", nil, now)

    assert attrs.hostname == "core-sw.farm.lan"
    assert attrs.metadata["rdns"]["status"] == "ok"
    assert attrs.metadata["rdns"]["hostname"] == "core-sw.farm.lan"
  end

  test "result_attrs does not overwrite on NXDOMAIN" do
    now = ~U[2026-08-13 12:00:00Z]
    device = %{ip: "10.0.0.8", hostname: nil, metadata: %{}}

    assert {:skip, attrs} =
             DeviceHostnameRdns.result_attrs(device, nil, "error", ":nxdomain", now)

    refute Map.has_key?(attrs, :hostname)
    assert attrs.metadata["rdns"]["status"] == "error"
  end

  test "run applies usable PTR results through the injected persist callback" do
    device = %{
      uid: "sr:test-device",
      ip: "10.0.0.8",
      hostname: nil,
      metadata: %{}
    }

    lookup = fn "10.0.0.8", _opts -> {"core-sw.farm.lan", "ok", nil} end

    persist = fn _device, hostname, status, _error, _now, _actor ->
      assert hostname == "core-sw.farm.lan"
      assert status == "ok"
      :updated
    end

    assert {:ok, %{looked_up: 1, updated: 1, skipped: 0, errors: 0}} =
             DeviceHostnameRdns.run(
               %{batch_size: 10, timeout_ms: 250, overwrite_existing: false},
               devices: [device],
               lookup: lookup,
               persist: persist,
               cache?: false
             )
  end
end
