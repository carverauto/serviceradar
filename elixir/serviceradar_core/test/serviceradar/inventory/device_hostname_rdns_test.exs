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

  test "run checks the default all-devices query against the pre-filter in uid chunks" do
    query = DeviceHostnameRdns.default_srql_query()

    settings = %{
      srql_query: query,
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
      assert scope == DeviceHostnameRdns.default_srql_query()
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
      srql_query: DeviceHostnameRdns.default_srql_query(),
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

  test "run returns an error when a pre-filter uid chunk cannot be queried" do
    query_page = fn query, _opts ->
      assert String.contains?(query, "uid:(")
      {:error, :translate_failed}
    end

    assert {:error, {:srql_query_failed, :translate_failed}} =
             DeviceHostnameRdns.run(
               %{
                 srql_query: DeviceHostnameRdns.default_srql_query(),
                 batch_size: 10,
                 timeout_ms: 250
               },
               eligible_uids: fn _settings, _now, _ignore_retry? -> {:ok, ["sr:a"]} end,
               query_page: query_page,
               cache?: false
             )
  end

  test "a narrow scope is paged in uid order and intersected, not chunked across the fleet" do
    settings = %{
      srql_query: "partition:lab",
      batch_size: 150,
      timeout_ms: 250,
      overwrite_existing: false,
      retry_after_minutes: 1_440
    }

    # Most recently seen first. Chunking this list would take three 200-uid queries.
    eligible = for n <- 1..450, do: "sr:dev-#{n}"

    query_page = fn query, opts ->
      refute String.contains?(query, "uid:(")
      assert query == "in:devices partition:lab sort:uid:asc"
      assert opts[:limit] == 1_000
      send(self(), {:scope_page, opts[:cursor]})

      case opts[:cursor] do
        nil ->
          {:ok, %{rows: [%{"uid" => "sr:dev-20"}, %{"uid" => "sr:other"}], next_cursor: "page-2"}}

        "page-2" ->
          {:ok, %{rows: [%{"uid" => "sr:dev-5"}]}}
      end
    end

    load_devices = fn requested, _actor ->
      send(self(), {:loaded, Enum.map(requested, & &1.uid)})

      {:ok,
       Enum.map(requested, fn %{uid: uid} ->
         hostname = if uid == "sr:dev-20", do: "host20.example.com"

         %{uid: uid, ip: "192.0.2.5", hostname: hostname, metadata: %{}}
       end)}
    end

    assert {:ok, %{cohort_rows: 2, candidates: 1, loaded: 1, looked_up: 1}} =
             DeviceHostnameRdns.run(settings,
               eligible_uids: fn _settings, _now, false -> {:ok, eligible} end,
               query_page: query_page,
               load_devices: load_devices,
               lookup: fn _ip, _opts -> {"host.example.com", "ok", nil} end,
               persist: fn _device, _hostname, _status, _error, _now, _actor -> :updated end,
               cache?: false
             )

    assert_received {:scope_page, nil}
    assert_received {:scope_page, "page-2"}
    refute_received {:scope_page, _}
    assert_received {:loaded, ["sr:dev-5", "sr:dev-20"]}
    refute_received {:loaded, _}
  end

  test "a scope walk keeps filters and drops the operator sort" do
    settings = %{
      srql_query:
        ~s(partition:lab hostname:"edge sort:decoy" Sort:last_seen:desc order:hostname:asc),
      batch_size: 10,
      timeout_ms: 250,
      overwrite_existing: false,
      retry_after_minutes: 1_440
    }

    query_page = fn query, _opts ->
      assert query ==
               ~s(in:devices partition:lab hostname:"edge sort:decoy" sort:uid:asc)

      send(self(), :scope_page)
      {:ok, %{rows: [%{"uid" => "sr:a"}]}}
    end

    assert {:ok, %{cohort_rows: 1, candidates: 1, loaded: 1, looked_up: 1}} =
             DeviceHostnameRdns.run(settings,
               eligible_uids: fn _settings, _now, _ignore_retry? -> {:ok, ["sr:a", "sr:b"]} end,
               query_page: query_page,
               load_devices: fn requested, _actor ->
                 {:ok,
                  Enum.map(requested, fn %{uid: uid} ->
                    %{uid: uid, ip: "192.0.2.8", hostname: nil, metadata: %{}}
                  end)}
               end,
               lookup: fn _ip, _opts -> {"host.example.com", "ok", nil} end,
               persist: fn _device, _hostname, _status, _error, _now, _actor -> :updated end,
               cache?: false
             )

    assert_received :scope_page
    refute_received :scope_page
  end

  test "a scope the same size as the pre-filter is intersected in pre-filter order" do
    settings = %{
      srql_query: "partition:lab",
      batch_size: 10,
      timeout_ms: 250,
      overwrite_existing: false,
      retry_after_minutes: 1_440
    }

    query_page = fn query, opts ->
      refute String.contains?(query, "uid:(")
      assert query == "in:devices partition:lab sort:uid:asc"
      refute opts[:cursor]
      send(self(), :scope_page)
      {:ok, %{rows: [%{"uid" => "sr:a"}, %{"uid" => "sr:b"}]}}
    end

    load_devices = fn requested, _actor ->
      send(self(), {:loaded, Enum.map(requested, & &1.uid)})

      {:ok,
       Enum.map(requested, fn %{uid: uid} ->
         %{uid: uid, ip: "192.0.2.8", hostname: nil, metadata: %{}}
       end)}
    end

    assert {:ok, %{cohort_rows: 2, candidates: 2, looked_up: 2}} =
             DeviceHostnameRdns.run(settings,
               eligible_uids: fn _settings, _now, _ignore_retry? -> {:ok, ["sr:b", "sr:a"]} end,
               query_page: query_page,
               load_devices: load_devices,
               lookup: fn _ip, _opts -> {"host.example.com", "ok", nil} end,
               persist: fn _device, _hostname, _status, _error, _now, _actor -> :updated end,
               cache?: false
             )

    assert_received :scope_page
    refute_received :scope_page
    assert_received {:loaded, ["sr:b", "sr:a"]}
  end

  test "a scope larger than the pre-filter falls back to uid chunks and keeps every pre-filter uid" do
    settings = %{
      srql_query: "partition:wide",
      batch_size: 10,
      timeout_ms: 250,
      overwrite_existing: false,
      retry_after_minutes: 1_440
    }

    query_page = fn query, opts ->
      send(self(), {:query, query, opts[:cursor]})

      if String.contains?(query, "uid:(") do
        [_, list] = String.split(query, "uid:(", parts: 2)

        uids =
          list
          |> String.trim_trailing(")")
          |> String.split(",")
          |> Enum.map(&String.trim(&1, "\""))

        {:ok,
         %{
           rows:
             Enum.map(uids, fn uid ->
               %{"uid" => uid, "ip" => "192.0.2.9", "hostname" => nil}
             end)
         }}
      else
        assert query == "in:devices partition:wide sort:uid:asc"
        assert opts[:limit] == 1_000
        assert opts[:cursor] == nil

        {:ok,
         %{
           rows: [%{"uid" => "sr:a"}, %{"uid" => "sr:b"}, %{"uid" => "sr:c"}],
           next_cursor: "more"
         }}
      end
    end

    load_devices = fn requested, _actor ->
      send(self(), {:loaded, Enum.map(requested, & &1.uid)})
      {:ok, requested}
    end

    assert {:ok, %{cohort_rows: 2, candidates: 2, looked_up: 2}} =
             DeviceHostnameRdns.run(settings,
               eligible_uids: fn _settings, _now, _ignore_retry? -> {:ok, ["sr:z", "sr:a"]} end,
               query_page: query_page,
               load_devices: load_devices,
               lookup: fn _ip, _opts -> {"host.example.com", "ok", nil} end,
               persist: fn _device, _hostname, _status, _error, _now, _actor -> :updated end,
               cache?: false
             )

    assert_received {:query, "in:devices partition:wide sort:uid:asc", nil}
    refute_received {:query, _, "more"}
    assert_received {:loaded, ["sr:z", "sr:a"]}
  end

  test "a full scope page without a cursor falls back to pre-filter uid chunks" do
    page_rows = for n <- 1..1_000, do: %{"uid" => "sr:page-#{n}"}
    eligible = ["sr:z" | for(n <- 1..999, do: "sr:keep-#{n}")]

    query_page = fn query, opts ->
      send(self(), {:query, query})

      if String.contains?(query, "uid:(") do
        assert String.starts_with?(
                 query,
                 "in:devices partition:lab sort:last_seen:desc order:hostname:asc uid:("
               )

        refute String.contains?(query, "sort:uid:asc")

        [_, list] = String.split(query, "uid:(", parts: 2)

        uids =
          list
          |> String.trim_trailing(")")
          |> String.split(",")
          |> Enum.map(&String.trim(&1, "\""))

        {:ok,
         %{
           rows:
             Enum.map(uids, fn uid ->
               %{"uid" => uid, "ip" => "192.0.2.9", "hostname" => nil}
             end)
         }}
      else
        assert query == "in:devices partition:lab sort:uid:asc"
        assert opts[:limit] == 1_000
        refute opts[:cursor]
        {:ok, %{rows: page_rows}}
      end
    end

    load_devices = fn requested, _actor ->
      send(self(), {:loaded, Enum.map(requested, & &1.uid)})
      {:ok, requested}
    end

    assert {:ok, %{cohort_rows: 1_000, candidates: 1_000, loaded: 1_000, looked_up: 1_000}} =
             DeviceHostnameRdns.run(
               %{
                 srql_query: "partition:lab sort:last_seen:desc order:hostname:asc",
                 batch_size: 1_000,
                 timeout_ms: 250,
                 overwrite_existing: false,
                 retry_after_minutes: 1_440
               },
               eligible_uids: fn _settings, _now, _ignore_retry? -> {:ok, eligible} end,
               query_page: query_page,
               load_devices: load_devices,
               lookup: fn _ip, _opts -> {"host.example.com", "ok", nil} end,
               persist: fn _device, _hostname, _status, _error, _now, _actor -> :updated end,
               cache?: false
             )

    queries =
      for _ <- 1..6 do
        assert_received {:query, query}
        query
      end

    refute_received {:query, _}
    assert hd(queries) == "in:devices partition:lab sort:uid:asc"

    chunks = tl(queries)
    assert length(chunks) == 5

    assert Enum.all?(
             chunks,
             &String.starts_with?(
               &1,
               "in:devices partition:lab sort:last_seen:desc order:hostname:asc uid:("
             )
           )

    assert Enum.any?(chunks, &String.contains?(&1, "\"sr:z\""))
    refute Enum.any?(chunks, &String.contains?(&1, "sr:page-"))

    assert_received {:loaded, loaded}
    assert hd(loaded) == "sr:z"
    assert length(loaded) == 1_000
    refute Enum.any?(loaded, &String.starts_with?(&1, "sr:page-"))
  end

  test "run returns an error when a narrow scope page cannot be queried" do
    query_page = fn query, opts ->
      assert query == "in:devices partition:lab sort:uid:asc"
      assert opts[:limit] == 1_000
      {:error, :translate_failed}
    end

    assert {:error, {:srql_query_failed, :translate_failed}} =
             DeviceHostnameRdns.run(
               %{srql_query: "partition:lab", batch_size: 10, timeout_ms: 250},
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
