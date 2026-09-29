defmodule ServiceRadarWebNG.Dashboards.ReportIndexTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Dashboards.ReportIndex

  @moduletag :db_free

  defp index(reports, version \\ 1), do: %{"version" => version, "reports" => reports}

  defp entry(overrides \\ %{}) do
    Map.merge(%{"slug" => "fleet-summary", "path" => "fleet-summary.json", "enabled_by_default" => false}, overrides)
  end

  test "parses each entry's slug, path and default-enabled flag" do
    assert {:ok, [%{slug: "fleet-summary", path: "fleet-summary.json", enabled_by_default: false}]} =
             ReportIndex.parse(index([entry()]), "index.json")
  end

  test "an entry must state whether it is enabled by default" do
    assert {:error, message} =
             ReportIndex.parse(index([Map.delete(entry(), "enabled_by_default")]), "index.json")

    assert message =~ "enabled_by_default"
  end

  test "a path that leaves the index directory is refused" do
    for path <- ["../secrets.json", "/etc/report.json", "nested/../../escape.json"] do
      assert {:error, message} = ReportIndex.parse(index([entry(%{"path" => path})]), "index.json")
      assert message =~ "path", "#{path} must be refused"
    end
  end

  test "a path must name a definition file, not the index itself" do
    assert {:error, _} = ReportIndex.parse(index([entry(%{"path" => "notes.txt"})]), "index.json")
    assert {:error, _} = ReportIndex.parse(index([entry(%{"path" => "index.json"})]), "index.json")
  end

  test "a slug listed twice is refused" do
    reports = [entry(), entry(%{"path" => "other.json"})]

    assert {:error, message} = ReportIndex.parse(index(reports), "index.json")
    assert message =~ "listed more than once"
  end

  test "an entry slug must follow the dashboard slug grammar" do
    assert {:error, message} = ReportIndex.parse(index([entry(%{"slug" => "Fleet_Summary"})]), "index.json")
    assert message =~ "slug"
  end

  test "an unknown index version is refused, not skipped" do
    assert {:error, message} = ReportIndex.parse(index([entry()], 2), "index.json")
    assert message =~ "unsupported index version 2"
  end

  test "decode names the source when the body is not JSON" do
    assert {:error, message} = ReportIndex.decode("{not json", "Release v0.0.1 index.json")
    assert message =~ "Release v0.0.1 index.json"
  end
end
