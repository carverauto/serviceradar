defmodule ServiceRadar.EventWriter.ExposureFactPayload do
  @moduledoc "Canonical cleared payload; fact identity, lifecycle and publication markers survive."

  @cleared %{
    "pkgver_ord" => 0,
    "source_scope" => nil,
    "severity_rank" => nil,
    "cvss_score" => nil,
    "kev" => nil,
    "exploit_available" => nil,
    "fix_available" => nil,
    "first_exposed_at" => nil
  }

  def compact(%{"state" => state} = row) when state in [0, 2] do
    row |> Map.merge(@cleared) |> Map.put("payload_compacted", true)
  end

  def compacted?(row) do
    row["payload_compacted"] in [true, 1] and row["state"] in [0, 2] and
      Enum.all?(@cleared, fn {key, value} -> Map.fetch(row, key) == {:ok, value} end)
  end
end
