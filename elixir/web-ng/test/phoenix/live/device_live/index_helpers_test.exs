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
             tags: ["site=lab", "role=edge"]
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
end
