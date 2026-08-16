defmodule ServiceRadar.Inventory.AdvisoryFeeds.LoaderTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.AdvisoryFeeds.Loader

  describe "unchanged_advisory?/2" do
    test "skips a CVE whose modified_at already matches" do
      record = %{
        advisory: %{
          source_object_id: "CVE-2024-0001",
          modified_at: "2024-01-02T00:00:00.000000Z"
        },
        coordinates: []
      }

      existing = %{"CVE-2024-0001" => ~U[2024-01-02 00:00:00.000000Z]}

      assert Loader.unchanged_advisory?(record, existing)
      refute Loader.unchanged_advisory?(record, %{})
    end
  end

  describe "dedupe_coordinate_rows/1" do
    test "keeps one row per advisory + type + value + version window" do
      advisory = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

      rows = [
        coord(advisory, "cpe:2.3:a:openssl:openssl:*:*:*:*:*:*:*:*", "3.0.0", "3.0.14", "A"),
        coord(advisory, "cpe:2.3:a:openssl:openssl:*:*:*:*:*:*:*:*", "3.0.0", "3.0.14", "B"),
        coord(advisory, "cpe:2.3:a:openssl:openssl:3.0.13:*:*:*:*:*:*:*", nil, nil, "C")
      ]

      deduped = Loader.dedupe_coordinate_rows(rows)

      assert length(deduped) == 2

      identities =
        MapSet.new(deduped, &{&1.value, &1.version_start, &1.version_end})

      assert identities ==
               MapSet.new([
                 {"cpe:2.3:a:openssl:openssl:*:*:*:*:*:*:*:*", "3.0.0", "3.0.14"},
                 {"cpe:2.3:a:openssl:openssl:3.0.13:*:*:*:*:*:*:*", nil, nil}
               ])
    end
  end

  defp coord(advisory_ref, value, version_start, version_end, match_id) do
    %{
      advisory_ref: advisory_ref,
      coordinate_type: "cpe",
      value: value,
      version_start: version_start,
      version_end: version_end,
      metadata: %{"match_criteria_id" => match_id}
    }
  end
end
