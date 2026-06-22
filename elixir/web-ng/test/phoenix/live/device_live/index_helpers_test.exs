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

    assert {:ok, [device]} = IndexCsvImport.parse_csv_file(path)

    assert device == %{
             hostname: "router, core",
             ip: "192.0.2.10",
             type: "network",
             tags: ["site=lab", "role=edge"]
           }
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
