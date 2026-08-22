defmodule ServiceRadar.Inventory.AdvisoryFeeds.LoaderTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.AdvisoryFeeds.Loader

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

  describe "unchanged_advisory?/2" do
    # The bug this guards against: existing_modified_at/2 is a schemaless query
    # over a `timestamp without time zone` column, so Postgres hands back a
    # %NaiveDateTime{} while the parsed feed value is always a %DateTime{}. The
    # original guard pattern-matched %DateTime{} on both sides, so it returned
    # false for every record and the whole corpus was rewritten every run.
    #
    # A test that only ever builds `existing` with ~U[...] cannot see that, which
    # is exactly why it shipped. The NaiveDateTime case below is the regression.
    test "skips when the stored value is a NaiveDateTime, as Postgres returns it" do
      existing = %{"CVE-2024-0001" => ~N[2024-01-15 12:34:56.123000]}

      assert Loader.unchanged_advisory?(
               record("CVE-2024-0001", "2024-01-15T12:34:56.123"),
               existing
             )
    end

    test "skips when the stored value is already a DateTime" do
      existing = %{"CVE-2024-0001" => ~U[2024-01-15 12:34:56.123000Z]}

      assert Loader.unchanged_advisory?(
               record("CVE-2024-0001", "2024-01-15T12:34:56.123"),
               existing
             )
    end

    # compare/2, not ==. Postgres returns microsecond precision metadata while
    # the parsed input carries millisecond precision; same instant, not ==.
    test "skips across differing microsecond precision metadata" do
      existing = %{"CVE-2024-0001" => %{~U[2024-01-15 12:34:56Z] | microsecond: {0, 6}}}
      incoming = record("CVE-2024-0001", "2024-01-15T12:34:56.0")

      assert Loader.unchanged_advisory?(incoming, existing)
    end

    test "does not skip when modified_at actually changed" do
      existing = %{"CVE-2024-0001" => ~N[2024-01-15 12:34:56.123000]}

      refute Loader.unchanged_advisory?(
               record("CVE-2024-0001", "2024-02-01T00:00:00.000"),
               existing
             )
    end

    test "does not skip an advisory the store has never seen" do
      refute Loader.unchanged_advisory?(record("CVE-2024-9999", "2024-01-15T12:34:56.123"), %{})
    end

    # nil means UNKNOWN, never UNCHANGED. KEV emits no modified_at; treating a
    # nil/nil pair as equal would silently stop updating that feed forever.
    test "does not skip when either side is nil" do
      assert refute_skip(%{"CVE-1" => nil}, record("CVE-1", "2024-01-15T12:34:56.123"))
      assert refute_skip(%{"CVE-1" => ~N[2024-01-15 12:34:56.123000]}, record("CVE-1", nil))
      assert refute_skip(%{"CVE-1" => nil}, record("CVE-1", nil))
    end
  end

  defp refute_skip(existing, rec), do: not Loader.unchanged_advisory?(rec, existing)

  defp record(source_object_id, modified_at) do
    %{advisory: %{source_object_id: source_object_id, modified_at: modified_at}, coordinates: []}
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
