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

    recently_looked_up = %{
      ip: "10.0.0.8",
      hostname: nil,
      metadata: %{"rdns" => %{"looked_up_at" => "2026-08-13T11:30:00Z"}}
    }

    refute DeviceHostnameRdns.candidate?(
             recently_looked_up,
             %{overwrite_existing: false, retry_after_minutes: 1_440},
             now
           )

    assert DeviceHostnameRdns.candidate?(
             recently_looked_up,
             %{overwrite_existing: false, retry_after_minutes: 1_440},
             now,
             ignore_retry?: true
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
    # A PATCH, not the whole metadata map: the write merges in the database so it
    # cannot carry another writer's keys back with it.
    assert attrs.metadata_patch == %{
             "rdns" => %{
               "looked_up_at" => DateTime.to_iso8601(now),
               "status" => "ok",
               "hostname" => "core-sw.farm.lan",
               "error" => nil
             }
           }
  end

  test "result_attrs does not overwrite on NXDOMAIN" do
    now = ~U[2026-08-13 12:00:00Z]
    device = %{ip: "10.0.0.8", hostname: nil, metadata: %{}}

    assert {:skip, attrs} =
             DeviceHostnameRdns.result_attrs(device, nil, "error", ":nxdomain", now)

    refute Map.has_key?(attrs, :hostname)
    assert attrs.metadata_patch["rdns"]["status"] == "error"
    assert Map.keys(attrs.metadata_patch) == ["rdns"]
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

    assert {:ok, %{looked_up: 1, updated: 1, skipped: 0, errors: 0, loaded: 1}} =
             DeviceHostnameRdns.run(
               %{batch_size: 10, timeout_ms: 250, overwrite_existing: false},
               devices: [device],
               lookup: lookup,
               persist: persist,
               cache?: false
             )
  end

  test "run unwraps an Ash keyset page of devices" do
    device = %{
      uid: "sr:test-device",
      ip: "10.0.0.8",
      hostname: nil,
      metadata: %{}
    }

    page = %Ash.Page.Keyset{results: [device], more?: false, limit: 1}
    lookup = fn "10.0.0.8", _opts -> {"core-sw.farm.lan", "ok", nil} end
    persist = fn _device, _hostname, _status, _error, _now, _actor -> :updated end

    assert {:ok, %{looked_up: 1, updated: 1, skipped: 0, errors: 0, loaded: 1}} =
             DeviceHostnameRdns.run(
               %{batch_size: 10, timeout_ms: 250, overwrite_existing: false},
               devices: page,
               lookup: lookup,
               persist: persist,
               cache?: false
             )
  end

  test "run selects the cohort from SRQL then loads matching devices" do
    settings = %{
      srql_query: "in:devices ip:10.0.0.0/8",
      batch_size: 10,
      timeout_ms: 250,
      overwrite_existing: false,
      retry_after_minutes: 1_440
    }

    device = %{
      uid: "sr:test-device",
      ip: "10.0.0.8",
      hostname: nil,
      metadata: %{}
    }

    query_page = fn query, opts ->
      assert query == "in:devices ip:10.0.0.0/8"
      assert opts[:limit] == 500
      assert opts[:direction] == "next"

      {:ok,
       %{
         rows: [
           %{"uid" => "sr:test-device", "ip" => "10.0.0.8", "hostname" => nil},
           %{"uid" => "sr:named", "ip" => "10.0.0.9", "hostname" => "leaf-01"}
         ]
       }}
    end

    load_devices = fn candidates, _actor ->
      assert Enum.map(candidates, & &1.uid) == ["sr:test-device"]
      {:ok, [device]}
    end

    lookup = fn "10.0.0.8", _opts -> {"core-sw.farm.lan", "ok", nil} end
    persist = fn _device, _hostname, _status, _error, _now, _actor -> :updated end

    assert {:ok,
            %{
              looked_up: 1,
              updated: 1,
              skipped: 0,
              errors: 0,
              cohort_rows: 2,
              candidates: 1,
              loaded: 1
            }} =
             DeviceHostnameRdns.run(settings,
               query_page: query_page,
               load_devices: load_devices,
               lookup: lookup,
               persist: persist,
               cache?: false
             )
  end

  test "run exhausts the SRQL cohort and processes every device in bounded batches" do
    settings = %{
      srql_query: "in:devices",
      batch_size: 2,
      timeout_ms: 250,
      overwrite_existing: false,
      retry_after_minutes: 1_440
    }

    query_page = fn "in:devices", opts ->
      case opts[:cursor] do
        nil ->
          {:ok,
           %{
             rows: [
               %{"uid" => "sr:a", "ip" => "10.0.0.1", "hostname" => nil},
               %{"uid" => "sr:b", "ip" => "10.0.0.2", "hostname" => nil},
               %{"uid" => "sr:c", "ip" => "10.0.0.3", "hostname" => nil}
             ],
             next_cursor: "page-2"
           }}

        "page-2" ->
          assert_received {:loaded_batch, ["sr:a", "sr:b"]}

          {:ok,
           %{
             rows: [
               %{"uid" => "sr:d", "ip" => "10.0.0.4", "hostname" => nil},
               %{"uid" => "sr:e", "ip" => "10.0.0.5", "hostname" => nil}
             ],
             next_cursor: nil
           }}
      end
    end

    load_devices = fn candidates, _actor ->
      send(self(), {:loaded_batch, Enum.map(candidates, & &1.uid)})
      {:ok, candidates}
    end

    lookup = fn _ip, _opts -> {"host.lan", "ok", nil} end
    persist = fn _device, _hostname, _status, _error, _now, _actor -> :updated end

    assert {:ok, %{looked_up: 5, updated: 5, cohort_rows: 5, candidates: 5, loaded: 5}} =
             DeviceHostnameRdns.run(settings,
               query_page: query_page,
               load_devices: load_devices,
               lookup: lookup,
               persist: persist,
               cache?: false
             )

    assert_received {:loaded_batch, ["sr:c", "sr:d"]}
    assert_received {:loaded_batch, ["sr:e"]}
    refute_received {:loaded_batch, _batch}
  end

  test "run stops with a clear error when SRQL pagination exceeds its safety limit" do
    query_page = fn _query, opts ->
      page = opts[:cursor] || "page-1"

      {:ok,
       %{
         rows: [%{"uid" => "sr:#{page}", "ip" => "10.0.0.1", "hostname" => nil}],
         next_cursor: "#{page}-next"
       }}
    end

    assert {:error, {:srql_page_limit_exceeded, %{max_pages: 2, scanned_rows: 2}}} =
             DeviceHostnameRdns.run(
               %{
                 srql_query: "in:devices",
                 batch_size: 1,
                 timeout_ms: 250,
                 overwrite_existing: false,
                 retry_after_minutes: 1_440
               },
               query_page: query_page,
               load_devices: fn candidates, _actor -> {:ok, candidates} end,
               lookup: fn _ip, _opts -> {"host.lan", "ok", nil} end,
               persist: fn _device, _hostname, _status, _error, _now, _actor -> :updated end,
               max_srql_pages: 2,
               cache?: false
             )
  end

  test "run fails instead of silently returning a partial cohort when pagination stalls" do
    query_page = fn _query, _opts ->
      {:ok,
       %{
         rows: [%{"uid" => "sr:a", "ip" => "10.0.0.1", "hostname" => nil}],
         next_cursor: "same-cursor"
       }}
    end

    assert {:error, {:srql_pagination_stalled, "same-cursor"}} =
             DeviceHostnameRdns.run(
               %{
                 srql_query: "in:devices",
                 batch_size: 2,
                 timeout_ms: 250,
                 overwrite_existing: false,
                 retry_after_minutes: 1_440
               },
               query_page: query_page,
               cache?: false
             )
  end

  test "run accepts inet-shaped SRQL IP values" do
    settings = %{
      srql_query: "in:devices",
      batch_size: 10,
      timeout_ms: 250,
      overwrite_existing: false,
      retry_after_minutes: 1_440
    }

    inet = %Postgrex.INET{address: {10, 0, 0, 8}, netmask: 32}

    query_page = fn _query, _opts ->
      {:ok, %{rows: [%{"uid" => "sr:inet", "ip" => inet, "hostname" => nil}]}}
    end

    load_devices = fn candidates, _actor ->
      assert hd(candidates).ip == "10.0.0.8"
      {:ok, candidates}
    end

    lookup = fn "10.0.0.8", _opts -> {"core-sw.farm.lan", "ok", nil} end
    persist = fn _device, _hostname, _status, _error, _now, _actor -> :updated end

    assert {:ok, %{looked_up: 1, updated: 1, candidates: 1}} =
             DeviceHostnameRdns.run(settings,
               query_page: query_page,
               load_devices: load_devices,
               lookup: lookup,
               persist: persist,
               cache?: false
             )
  end

  test "run returns an error when the SRQL cohort cannot be queried" do
    query_page = fn _query, _opts -> {:error, :translate_failed} end

    assert {:error, {:srql_query_failed, :translate_failed}} =
             DeviceHostnameRdns.run(
               %{srql_query: "in:devices", batch_size: 10, timeout_ms: 250},
               query_page: query_page,
               cache?: false
             )
  end

  test "preview returns a sample of the SRQL cohort" do
    query_page = fn query, opts ->
      assert query == "in:devices"
      assert opts[:limit] == 10

      {:ok, %{rows: [%{"uid" => "sr:1", "ip" => "10.0.0.8", "hostname" => nil}]}}
    end

    assert {:ok, preview} =
             DeviceHostnameRdns.preview("in:devices", query_page: query_page, limit: 10)

    assert preview.query == "in:devices"
    assert preview.rows == [%{uid: "sr:1", ip: "10.0.0.8", hostname: nil}]
  end
end
