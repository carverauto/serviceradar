defmodule ServiceRadarWebNGWeb.DeviceLive.IndexHelpersTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.DeviceLive.IndexCsvImport
  alias ServiceRadarWebNGWeb.DeviceLive.IndexData

  @moduletag :db_free

  test "parse_csv_file handles quoted commas and pipe-separated tags" do
    path = Path.join(System.tmp_dir!(), "serviceradar-device-import-#{System.unique_integer([:positive])}.csv")
    on_exit(fn -> File.rm(path) end)

    File.write!(path, """
    hostname,ip,type,tags
    "router, core",192.0.2.10,network,"site=lab|role=edge"
    """)

    assert {:ok, [device], []} = IndexCsvImport.parse_csv_file(path)

    assert device == %{
             hostname: "router, core",
             ip: "192.0.2.10",
             type: "network",
             tags: ["site=lab", "role=edge"],
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

    assert {:error, %{created: 2, skipped: 0, errors: ["Row 3: :nxdomain"]}} =
             IndexCsvImport.import_devices(:scope, devices, create_device)

    assert_receive {:attempted, 2}
    assert_receive {:attempted, 3}
    assert_receive {:attempted, 4}
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
              skipped: 0,
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
        :continue -> {:ok, "192.0.2.#{hostname |> String.replace_prefix("host-", "") |> String.split(".") |> hd()}"}
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
              skipped: 0,
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
              skipped: 0,
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
end
