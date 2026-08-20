defmodule ServiceRadar.Inventory.AdvisoryFeeds.CwesTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.AdvisoryFeeds.Cwes

  test "extracts CWE ids from NVD 2.0 weakness descriptions" do
    cve = %{
      "weaknesses" => [
        %{
          "type" => "Primary",
          "description" => [%{"lang" => "en", "value" => "CWE-269"}]
        },
        %{
          "type" => "Secondary",
          "description" => [%{"lang" => "en", "value" => "CWE-829"}]
        }
      ]
    }

    assert Cwes.from_nvd_cve(cve) == ["CWE-269", "CWE-829"]
  end

  test "extracts CWE ids from a KEV cwes list or string" do
    assert Cwes.from_kev_entry(%{"cwes" => ["CWE-829"]}) == ["CWE-829"]
    assert Cwes.from_kev_entry(%{"cwes" => "CWE-787 CWE-22"}) == ["CWE-787", "CWE-22"]
  end

  test "reads CWE ids from stored advisory metadata or raw" do
    advisory = %{
      metadata: %{"cwes" => ["CWE-269"]},
      raw: %{"cwes" => ["CWE-829"], "cve" => %{"weaknesses" => []}}
    }

    assert Cwes.from_advisory(advisory) == ["CWE-269", "CWE-829"]
  end
end
