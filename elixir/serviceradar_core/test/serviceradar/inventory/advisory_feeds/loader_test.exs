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

  describe "KEV content comparison" do
    test "hashes normalized advisory content deterministically" do
      assert Loader.content_hash(kev_record()) =~ ~r/^[0-9a-f]{64}$/
      assert Loader.content_hash(kev_record()) == Loader.content_hash(reordered_kev_record())

      refute Loader.content_hash(kev_record()) ==
               Loader.content_hash(changed_description_record())

      refute Loader.content_hash(kev_record()) ==
               Loader.content_hash(changed_coordinate_record())
    end

    test "skips only a KEV record whose stored content hash matches" do
      record = kev_record()

      state = %{
        "CVE-2026-0001" => %{modified_at: nil, content_hash: Loader.content_hash(record)}
      }

      assert Loader.unchanged_advisory?(record, state, comparison: :content_hash)

      refute Loader.unchanged_advisory?(changed_description_record(), state,
               comparison: :content_hash
             )

      refute Loader.unchanged_advisory?(
               record,
               %{"CVE-2026-0001" => %{modified_at: nil, content_hash: nil}},
               comparison: :content_hash
             )
    end

    test "timestamp comparison remains unsafe when either timestamp is nil" do
      record = kev_record()
      matching_hash = Loader.content_hash(record)

      refute Loader.unchanged_advisory?(
               record,
               %{"CVE-2026-0001" => %{modified_at: nil, content_hash: matching_hash}},
               comparison: :modified_at
             )

      refute Loader.unchanged_advisory?(
               record,
               %{
                 "CVE-2026-0001" => %{
                   modified_at: ~U[2026-01-15 12:34:56Z],
                   content_hash: matching_hash
                 }
               },
               comparison: :modified_at
             )
    end

    test "counts only state comparable by the feed's selected guard" do
      state = %{
        "content-only" => %{modified_at: nil, content_hash: String.duplicate("a", 64)},
        "timestamp-only" => %{modified_at: ~U[2026-01-15 12:34:56Z], content_hash: nil},
        "legacy" => %{modified_at: nil, content_hash: nil}
      }

      assert Loader.comparable_count("cisa-kev", state) == 1
      assert Loader.comparable_count("vulncheck-kev", state) == 1
      assert Loader.comparable_count("nist-nvd2", state) == 1
    end
  end

  defp refute_skip(existing, rec), do: not Loader.unchanged_advisory?(rec, existing)

  defp record(source_object_id, modified_at) do
    %{advisory: %{source_object_id: source_object_id, modified_at: modified_at}, coordinates: []}
  end

  defp kev_record do
    %{
      advisory: %{
        source_object_id: "CVE-2026-0001",
        advisory_id: "CVE-2026-0001",
        cve_id: "CVE-2026-0001",
        title: "Example KEV advisory",
        description: "An exploitable vulnerability.",
        severity: "critical",
        cvss_score: 9.8,
        cvss_vector: "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H",
        published_at: "2026-01-15T12:34:56Z",
        modified_at: nil,
        kev: true,
        exploit_available: true,
        references: ["https://www.cisa.gov/known-exploited-vulnerabilities-catalog"],
        raw: %{"vendorProject" => "Example", "product" => "Widget"},
        metadata: %{"catalogVersion" => "2026.01.15"}
      },
      coordinates: [
        %{
          coordinate_type: "cpe",
          value: "cpe:2.3:a:example:widget:1.0:*:*:*:*:*:*:*",
          cpe_part: "a",
          cpe_vendor: "example",
          cpe_product: "widget",
          cpe_version: "1.0",
          version_start: "1.0",
          version_start_inclusive: true,
          version_end: "1.4",
          version_end_inclusive: false,
          metadata: %{"match_criteria_id" => "coordinate-a"}
        },
        %{
          coordinate_type: "cpe",
          value: "cpe:2.3:a:example:widget:2.0:*:*:*:*:*:*:*",
          cpe_part: "a",
          cpe_vendor: "example",
          cpe_product: "widget",
          cpe_version: "2.0",
          version_start: "2.0",
          version_start_inclusive: true,
          version_end: nil,
          version_end_inclusive: nil,
          metadata: %{"match_criteria_id" => "coordinate-b"}
        }
      ]
    }
  end

  # Deliberately rebuilt rather than derived from kev_record/0 so this verifies
  # map insertion order and coordinate order cannot change the persisted hash.
  defp reordered_kev_record do
    %{
      coordinates: [
        %{
          metadata: %{"match_criteria_id" => "coordinate-b"},
          version_end_inclusive: nil,
          version_end: nil,
          version_start_inclusive: true,
          version_start: "2.0",
          cpe_version: "2.0",
          cpe_product: "widget",
          cpe_vendor: "example",
          cpe_part: "a",
          value: "cpe:2.3:a:example:widget:2.0:*:*:*:*:*:*:*",
          coordinate_type: "cpe"
        },
        %{
          metadata: %{"match_criteria_id" => "coordinate-a"},
          version_end_inclusive: false,
          version_end: "1.4",
          version_start_inclusive: true,
          version_start: "1.0",
          cpe_version: "1.0",
          cpe_product: "widget",
          cpe_vendor: "example",
          cpe_part: "a",
          value: "cpe:2.3:a:example:widget:1.0:*:*:*:*:*:*:*",
          coordinate_type: "cpe"
        }
      ],
      advisory: %{
        metadata: %{"catalogVersion" => "2026.01.15"},
        raw: %{"product" => "Widget", "vendorProject" => "Example"},
        references: ["https://www.cisa.gov/known-exploited-vulnerabilities-catalog"],
        exploit_available: true,
        kev: true,
        modified_at: nil,
        published_at: "2026-01-15T12:34:56Z",
        cvss_vector: "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H",
        cvss_score: 9.8,
        severity: "critical",
        description: "An exploitable vulnerability.",
        title: "Example KEV advisory",
        cve_id: "CVE-2026-0001",
        advisory_id: "CVE-2026-0001",
        source_object_id: "CVE-2026-0001"
      }
    }
  end

  defp changed_description_record do
    put_in(kev_record(), [:advisory, :description], "A changed exploitable vulnerability.")
  end

  defp changed_coordinate_record do
    put_in(kev_record(), [:coordinates, Access.at(0), :cpe_version], "1.0.1")
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
