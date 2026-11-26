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

  test "run scopes the pre-filtered uids with the SRQL query in chunks, most recently seen first" do
    settings = %{
      srql_query: "partition:lab",
      batch_size: 150,
      timeout_ms: 250,
      overwrite_existing: false,
      retry_after_minutes: 1_440
    }

    # The pre-filter returns most recently seen first. A fleet larger than one
    # SRQL list filter takes three scoped queries, not a walk of every device.
    eligible = for n <- 1..450, do: "sr:dev-#{n}"

    eligible_uids = fn _settings, _now, false -> {:ok, eligible} end

    query_page = fn query, opts ->
      [scope, list] = String.split(query, " uid:(", parts: 2)
      assert scope == "in:devices partition:lab"
      assert opts[:limit] == 200

      uids =
        list
        |> String.trim_trailing(")")
        |> String.split(",")
        |> Enum.map(&String.trim(&1, "\""))

      assert length(uids) <= 200
      send(self(), {:scoped_query, length(uids)})

      # Odd devices are outside the operator's scope; sr:dev-2 is already
      # named. Rows come back in the operator's sort, newest uid last.
      rows =
        uids
        |> Enum.filter(fn "sr:dev-" <> n -> rem(String.to_integer(n), 2) == 0 end)
        |> Enum.map(fn "sr:dev-" <> n = uid ->
          hostname = if n == "2", do: "host02.example.com"

          %{
            "uid" => uid,
            "ip" => "192.0.2.#{rem(String.to_integer(n), 250) + 1}",
            "hostname" => hostname
          }
        end)
        |> Enum.reverse()

      {:ok, %{rows: rows, next_cursor: "ignored"}}
    end

    load_devices = fn candidates, _actor ->
      send(self(), {:loaded_batch, Enum.map(candidates, & &1.uid)})
      {:ok, candidates}
    end

    assert {:ok, %{cohort_rows: 225, candidates: 224, loaded: 224, looked_up: 224}} =
             DeviceHostnameRdns.run(settings,
               eligible_uids: eligible_uids,
               query_page: query_page,
               load_devices: load_devices,
               lookup: fn _ip, _opts -> {"host.example.com", "ok", nil} end,
               persist: fn _device, _hostname, _status, _error, _now, _actor -> :updated end,
               cache?: false
             )

    assert_received {:scoped_query, 200}
    assert_received {:scoped_query, 200}
    assert_received {:scoped_query, 50}
    refute_received {:scoped_query, _}

    expected = for n <- 4..450//2, do: "sr:dev-#{n}"
    {first, rest} = Enum.split(expected, 150)
    assert_received {:loaded_batch, ^first}
    assert_received {:loaded_batch, ^rest}
    refute_received {:loaded_batch, _}
  end

  test "run accepts inet-shaped SRQL IP values" do
    settings = %{
      srql_query: "in:devices",
      batch_size: 10,
      timeout_ms: 250,
      overwrite_existing: false,
      retry_after_minutes: 1_440
    }

    inet = %Postgrex.INET{address: {192, 0, 2, 8}, netmask: 32}

    query_page = fn _query, _opts ->
      {:ok, %{rows: [%{"uid" => "sr:inet", "ip" => inet, "hostname" => nil}]}}
    end

    load_devices = fn candidates, _actor ->
      assert hd(candidates).ip == "192.0.2.8"
      {:ok, candidates}
    end

    lookup = fn "192.0.2.8", _opts -> {"host08.example.com", "ok", nil} end
    persist = fn _device, _hostname, _status, _error, _now, _actor -> :updated end

    assert {:ok, %{looked_up: 1, updated: 1, candidates: 1}} =
             DeviceHostnameRdns.run(settings,
               eligible_uids: fn _settings, _now, _ignore_retry? -> {:ok, ["sr:inet"]} end,
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
               eligible_uids: fn _settings, _now, _ignore_retry? -> {:ok, ["sr:a"]} end,
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
