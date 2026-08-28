defmodule ServiceRadarWebNGWeb.DeviceLive.IndexHelpersTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.DeviceLive.IndexCsvImport
  alias ServiceRadarWebNGWeb.DeviceLive.IndexData

  @moduletag :db_free

  test "parse_csv_file handles quoted commas and pipe-separated tags" do
    path =
      Path.join(
        System.tmp_dir!(),
        "serviceradar-device-import-#{System.unique_integer([:positive])}.csv"
      )

    on_exit(fn -> File.rm(path) end)

    File.write!(path, """
    hostname,ip,type,tags
    "router, core",192.0.2.10,network,"site=lab|role=edge"
    """)

    assert {:ok, [device], []} = IndexCsvImport.parse_csv_file(path)

    assert device == %{
             hostname: "router, core",
             ip: "192.0.2.10",
             partition: "",
             type: "network",
             tags: ["site=lab", "role=edge"],
             metadata: %{"site" => "lab", "role" => "edge"},
             source_line: 2
           }
  end

  test "parse_csv_file accepts a row with an ip but no hostname" do
    path =
      csv_fixture("""
      hostname,ip,type,tags
      ,192.0.2.11,rids,gate=B40
      """)

    assert {:ok, [device], []} = IndexCsvImport.parse_csv_file(path)
    assert device.hostname == ""
    assert device.ip == "192.0.2.11"
    assert device.tags == ["gate=B40"]
    assert device.metadata == %{"gate" => "B40"}
  end

  test "parse_csv_file copies key=value tags into metadata for All Metadata" do
    path =
      csv_fixture("""
      hostname,ip,type,tags
      rids-sfo-e6,10.0.4.17,rids,rids=true|site=SFO|concourse=E|gate=E6|model=DAK_VENUS1500_4LINE|config=efids|rows=4|cols=24|source=rids
      """)

    assert {:ok, [device], []} = IndexCsvImport.parse_csv_file(path)

    assert device.tags == [
             "rids=true",
             "site=SFO",
             "concourse=E",
             "gate=E6",
             "model=DAK_VENUS1500_4LINE",
             "config=efids",
             "rows=4",
             "cols=24",
             "source=rids"
           ]

    assert device.metadata == %{
             "rids" => "true",
             "site" => "SFO",
             "concourse" => "E",
             "gate" => "E6",
             "model" => "DAK_VENUS1500_4LINE",
             "config" => "efids",
             "rows" => "4",
             "cols" => "24",
             "source" => "rids"
           }
  end

  test "parse_csv_file extra columns overlay tag pairs in metadata" do
    path =
      csv_fixture("""
      hostname,ip,tags,site
      rids-den-a14,10.130.20.228,site=ZZC|gate=A14,ZZC-override
      """)

    assert {:ok, [device], []} = IndexCsvImport.parse_csv_file(path)
    assert device.tags == ["site=ZZC", "gate=A14"]
    assert device.metadata == %{"site" => "ZZC-override", "gate" => "A14"}
  end

  test "parse_csv_file accepts a hostname-only row for DNS resolution" do
    path =
      csv_fixture("""
      hostname,ip
      host-a.example,
      """)

    assert {:ok, [device], []} = IndexCsvImport.parse_csv_file(path)
    assert device.hostname == "host-a.example"
    assert device.ip == ""
  end

  # Rows used to be dropped with no trace, so a malformed file imported short
  # and looked successful.
  test "parse_csv_file reports skipped rows instead of dropping them silently" do
    path =
      csv_fixture("""
      hostname,ip
      host-a.example,192.0.2.12
      ,
      host-c.example,192.0.2.14
      """)

    assert {:ok, devices, warnings} = IndexCsvImport.parse_csv_file(path)
    assert length(devices) == 2
    assert warnings == ["Row 3 skipped: needs a hostname or an ip"]
  end

  test "parse_csv_file collapses a long run of skipped rows" do
    blank_rows = String.duplicate(",\n", 12)
    path = csv_fixture("hostname,ip\nhost-a.example,192.0.2.15\n" <> blank_rows)

    assert {:ok, [_device], warnings} = IndexCsvImport.parse_csv_file(path)
    assert length(warnings) == 11
    assert List.last(warnings) == "... and 2 more row(s) skipped"
  end

  test "parse_csv_file requires a hostname or ip column" do
    path =
      csv_fixture("""
      name,address
      host-a.example,192.0.2.16
      """)

    assert {:error, ["CSV must include a hostname or ip column"]} =
             IndexCsvImport.parse_csv_file(path)
  end

  test "parse_csv_file surfaces why every row was skipped" do
    path = csv_fixture("hostname,ip\n,\n,\n")

    assert {:error, errors} = IndexCsvImport.parse_csv_file(path)
    assert "No valid device rows found in CSV" in errors
    assert "Row 2 skipped: needs a hostname or an ip" in errors
  end

  defp csv_fixture(contents) do
    path =
      Path.join(
        System.tmp_dir!(),
        "serviceradar-device-import-#{System.unique_integer([:positive])}.csv"
      )

    on_exit(fn -> File.rm(path) end)
    File.write!(path, contents)
    path
  end

  test "include_inactive_inventory_params appends only when lifecycle is unspecified" do
    assert %{"q" => "in:devices include_inactive:true"} =
             IndexData.include_inactive_inventory_params(%{"q" => ""})

    assert %{"q" => "in:devices type:router include_inactive:true"} =
             IndexData.include_inactive_inventory_params(%{"q" => "in:devices type:router"})

    assert %{"q" => "in:devices is_active:true"} =
             IndexData.include_inactive_inventory_params(%{"q" => "in:devices is_active:true"})
  end

  test "parse_page_param defaults invalid pages to one" do
    assert IndexData.parse_page_param(%{"page" => "3"}) == 3
    assert IndexData.parse_page_param(%{"page" => "-1"}) == 1
    assert IndexData.parse_page_param(%{}) == 1
  end

  test "parse_csv_file matches headers regardless of case or padding" do
    path =
      csv_fixture("""
      HostName, IP ,Type
      host-a.example,192.0.2.20,rids
      """)

    assert {:ok, [device], []} = IndexCsvImport.parse_csv_file(path)
    assert device.hostname == "host-a.example"
    assert device.ip == "192.0.2.20"
    assert device.type == "rids"
  end

  # A quoted field may contain newlines, so the Nth record is not line N. A
  # warning naming the wrong line is worse than naming none.
  test "parse_csv_file reports physical lines across a multiline quoted field" do
    path =
      csv_fixture("""
      hostname,ip,type
      "multi
      line host",192.0.2.21,rids
      ,
      host-c.example,192.0.2.23,rids
      """)

    assert {:ok, devices, warnings} = IndexCsvImport.parse_csv_file(path)
    assert length(devices) == 2
    # The record spans lines 2-3, so the blank record sits on line 4.
    assert warnings == ["Row 4 skipped: needs a hostname or an ip"]

    assert [%{hostname: "multi\nline host", source_line: 2}, %{source_line: 5}] =
             Enum.sort_by(devices, & &1.source_line)
  end

  test "parse_csv_file tags each device with the line it came from" do
    path =
      csv_fixture("""
      hostname,ip
      ,
      host-b.example,192.0.2.24
      """)

    assert {:ok, [device], _warnings} = IndexCsvImport.parse_csv_file(path)
    assert device.source_line == 3
  end

  test "parse_csv_file strips a UTF-8 BOM from the first header" do
    two_column = csv_fixture("\uFEFFhostname,ip\nhost-a.example,192.0.2.25\n")
    hostname_only = csv_fixture("\uFEFFhostname\nhost-b.example\n")

    assert {:ok, [%{hostname: "host-a.example"}], []} =
             IndexCsvImport.parse_csv_file(two_column)

    assert {:ok, [%{hostname: "host-b.example"}], []} =
             IndexCsvImport.parse_csv_file(hostname_only)
  end

  test "parse_csv_file rejects an unterminated quoted field" do
    path = csv_fixture("hostname,ip\n\"broken,192.0.2.26\nnext.example,192.0.2.27\n")

    assert {:error, ["Row 2: unterminated quoted field"]} =
             IndexCsvImport.parse_csv_file(path)
  end

  test "parse_csv_file reports an explicit final empty quoted row" do
    path = csv_fixture("hostname\nvalid.example\n\"\"")

    assert {:ok, [%{hostname: "valid.example"}], warnings} =
             IndexCsvImport.parse_csv_file(path)

    assert warnings == ["Row 3 skipped: needs a hostname or an ip"]
  end

  test "import_devices reports persisted successes when another row fails" do
    devices = Enum.map(2..4, &%{source_line: &1})

    create_device = fn _scope, device ->
      send(self(), {:attempted, device.source_line})

      case device.source_line do
        3 -> {:error, :nxdomain}
        _ -> {:ok, %{}}
      end
    end

    assert {:error, %{created: 2, updated: 0, errors: ["Row 3: :nxdomain"]}} =
             IndexCsvImport.import_devices(:scope, devices, create_device)

    assert_receive {:attempted, 2}
    assert_receive {:attempted, 3}
    assert_receive {:attempted, 4}
  end

  test "import_devices formats a StaleRecord without dumping the Ash struct" do
    stale =
      Ash.Error.Changes.StaleRecord.exception(
        resource: ServiceRadar.Inventory.Device,
        filter: %{uid: "sr:bfb15b4f-c734-4aa4-94d5-33cd282f4afe"}
      )

    wrapped = Ash.Error.Invalid.exception(errors: [stale])

    create_device = fn _scope, _device -> {:error, wrapped} end

    assert {:error, %{created: 0, updated: 0, errors: [message]}} =
             IndexCsvImport.import_devices(:scope, [%{source_line: 391}], create_device)

    assert message ==
             "Row 391: device was updated by another writer during import; retry this row"

    refute message =~ "StaleRecord"
    refute message =~ "Splode"
  end

  test "import_devices rejects an oversized hostname-only batch before resolving or writing" do
    test_process = self()

    devices =
      Enum.map(2..102, fn line ->
        %{hostname: "host-#{line}.example", ip: "", source_line: line}
      end)

    resolver = fn hostname ->
      send(test_process, {:resolved, hostname})
      {:ok, "192.0.2.1"}
    end

    create_device = fn _scope, device ->
      send(test_process, {:created, device.source_line})
      {:ok, %{}}
    end

    assert {:error,
            %{
              created: 0,
              updated: 0,
              errors: [
                "CSV contains 101 hostname-only rows; the maximum is 100 per import"
              ]
            }} = IndexCsvImport.import_devices(:scope, devices, create_device, resolver)

    refute_receive {:resolved, _hostname}
    refute_receive {:created, _line}
  end

  test "import_devices bounds DNS concurrency and finishes resolution before writes" do
    test_process = self()

    devices =
      Enum.map(1..12, fn offset ->
        %{hostname: "host-#{offset}.example", ip: "", source_line: offset + 1}
      end)

    resolver = fn hostname ->
      send(test_process, {:resolver_started, hostname, self()})

      receive do
        :continue ->
          {:ok, "192.0.2.#{hostname |> String.replace_prefix("host-", "") |> String.split(".") |> hd()}"}
      end
    end

    create_device = fn _scope, device ->
      send(test_process, {:created, device.source_line, device.ip})
      {:ok, %{}}
    end

    import_task =
      Task.async(fn ->
        IndexCsvImport.import_devices(:scope, devices, create_device, resolver)
      end)

    first_wave =
      Enum.map(1..10, fn _ ->
        assert_receive {:resolver_started, _hostname, resolver_pid}, 500
        resolver_pid
      end)

    assert length(Enum.uniq(first_wave)) == 10
    refute_receive {:resolver_started, _hostname, _resolver_pid}, 50
    refute_receive {:created, _line, _ip}

    Enum.each(first_wave, &send(&1, :continue))

    second_wave =
      Enum.map(1..2, fn _ ->
        assert_receive {:resolver_started, _hostname, resolver_pid}, 500
        resolver_pid
      end)

    refute_receive {:created, _line, _ip}
    Enum.each(second_wave, &send(&1, :continue))

    assert {:ok, {12, 0}} = Task.await(import_task, 1_000)

    for line <- 2..13 do
      assert_receive {:created, ^line, ip}
      assert ip != ""
    end
  end

  test "import_devices reports DNS failures with source lines and imports resolved rows" do
    test_process = self()

    devices = [
      %{hostname: "good.example", ip: "", source_line: 2},
      %{hostname: "bad.example", ip: "", source_line: 3},
      %{hostname: "", ip: "192.0.2.44", source_line: 4}
    ]

    resolver = fn
      "good.example" -> {:ok, "192.0.2.42"}
      "bad.example" -> {:error, :nxdomain}
    end

    create_device = fn _scope, device ->
      send(test_process, {:created, device.source_line, device.ip})
      {:ok, %{}}
    end

    assert {:error,
            %{
              created: 2,
              updated: 0,
              errors: ["Row 3: unable to resolve hostname 'bad.example': :nxdomain"]
            }} = IndexCsvImport.import_devices(:scope, devices, create_device, resolver)

    assert_receive {:created, 2, "192.0.2.42"}
    assert_receive {:created, 4, "192.0.2.44"}
    refute_receive {:created, 3, _ip}
  end

  test "import_devices kills and reports a timed-out resolver" do
    test_process = self()
    device = %{hostname: "slow.example", ip: "", source_line: 7}

    resolver = fn _hostname ->
      send(test_process, {:resolver_waiting, self()})
      Process.sleep(:infinity)
    end

    create_device = fn _scope, _device ->
      send(test_process, :unexpected_create)
      {:ok, %{}}
    end

    assert {:error,
            %{
              created: 0,
              updated: 0,
              errors: ["Row 7: hostname resolution timed out for 'slow.example'"]
            }} =
             IndexCsvImport.import_devices(
               :scope,
               [device],
               create_device,
               resolver,
               dns_timeout: 20
             )

    assert_receive {:resolver_waiting, resolver_pid}
    refute Process.alive?(resolver_pid)
    refute_receive :unexpected_create
  end

  test "completed_csv_upload_entry matches Phoenix uploaded_entries {completed, in_progress} tuples" do
    # uploaded_entries/2 returns this tuple. preview_csv_upload/1 used to match
    # [] / [entry | _] and CaseClauseError on Preview of a finished upload.
    entry = %Phoenix.LiveView.UploadEntry{
      progress: 100,
      preflighted?: true,
      upload_config: :csv_file,
      valid?: true,
      done?: true,
      cancelled?: false,
      client_name: "rids-import.csv",
      client_type: "text/csv"
    }

    assert {:ok, ^entry} = IndexCsvImport.completed_csv_upload_entry({[entry], []})
    assert {:error, :no_file} = IndexCsvImport.completed_csv_upload_entry({[], []})
    assert {:error, :in_progress} = IndexCsvImport.completed_csv_upload_entry({[], [entry]})
  end

  test "parse_csv_file accepts a rids spreadsheet row with pipe-separated tags" do
    path =
      csv_fixture("""
      hostname,ip,type,tags
      rids-bos-b23,10.102.61.31,rids,rids=true|site=BOS|concourse=B|gate=B23
      """)

    assert {:ok, [device], []} = IndexCsvImport.parse_csv_file(path)
    assert device.hostname == "rids-bos-b23"
    assert device.ip == "10.102.61.31"
    assert device.type == "rids"
    assert device.tags == ["rids=true", "site=BOS", "concourse=B", "gate=B23"]

    assert device.metadata == %{
             "rids" => "true",
             "site" => "BOS",
             "concourse" => "B",
             "gate" => "B23"
           }
  end

  test "parse_csv_file puts extra columns into metadata" do
    path =
      csv_fixture("""
      hostname,ip,type,tags,model,site
      rids-bos-b23,10.102.61.31,rids,rids=true,DAK_VENUS1500_4LINE,BOS
      """)

    assert {:ok, [device], []} = IndexCsvImport.parse_csv_file(path)
    assert device.tags == ["rids=true"]

    assert device.metadata == %{
             "rids" => "true",
             "model" => "DAK_VENUS1500_4LINE",
             "site" => "BOS"
           }
  end

  test "import_devices counts existing-device upserts as updates" do
    devices = [
      %{ip: "192.0.2.10", source_line: 2},
      %{ip: "192.0.2.11", source_line: 3}
    ]

    persist = fn _scope, device ->
      case device.source_line do
        2 -> {:ok, :created, %{}}
        3 -> {:ok, :updated, %{}}
      end
    end

    assert {:ok, {1, 1}} = IndexCsvImport.import_devices(:scope, devices, persist)

    assert IndexCsvImport.import_success_message(1, 1) ==
             "Created 1 device(s). Updated 1 existing device(s) with imported tags and metadata."

    assert IndexCsvImport.import_success_message(0, 3) ==
             "Updated 3 existing device(s) with imported tags and metadata."
  end

  test "parse_csv_file reads a partition column and keeps it out of metadata" do
    path =
      csv_fixture("""
      hostname,ip,type,partition,tags
      rids-iah-b40,10.0.0.1,rids,rids,rids=true|site=ZZA
      """)

    assert {:ok, [device], []} = IndexCsvImport.parse_csv_file(path)
    assert device.partition == "rids"
    assert device.metadata == %{"rids" => "true", "site" => "ZZA"}
  end

  test "parse_csv_file downcases a partition slug" do
    path = csv_fixture("hostname,ip,partition\nhost-a,192.0.2.40,RIDS\n")

    assert {:ok, [device], []} = IndexCsvImport.parse_csv_file(path)
    assert device.partition == "rids"
  end

  test "parse_csv_file skips an invalid partition slug" do
    path = csv_fixture("hostname,ip,partition\nhost-a,192.0.2.41,Not A Slug\n")

    assert {:error, errors} = IndexCsvImport.parse_csv_file(path)
    assert "No valid device rows found in CSV" in errors
    assert "Row 2 skipped: invalid partition 'not a slug'" in errors
  end

  test "apply_import_partition fills blank rows from the modal default" do
    devices = [
      %{hostname: "a", ip: "192.0.2.50", partition: ""},
      %{hostname: "b", ip: "192.0.2.51", partition: "lab"}
    ]

    assert [
             %{partition: "rids", ip: "192.0.2.50"},
             %{partition: "lab", ip: "192.0.2.51"}
           ] = IndexCsvImport.apply_import_partition(devices, "rids")
  end
end
