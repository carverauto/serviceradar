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

    test "merges inclusive flags into an order-independent safe prefilter" do
      advisory = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

      excluding =
        advisory
        |> coord("cpe:2.3:a:openssl:openssl:*:*:*:*:*:*:*:*", "3.0.0", "3.0.14", "A")
        |> Map.merge(%{version_start_inclusive: false, version_end_inclusive: false})

      including =
        advisory
        |> coord("cpe:2.3:a:openssl:openssl:*:*:*:*:*:*:*:*", "3.0.0", "3.0.14", "B")
        |> Map.merge(%{version_start_inclusive: true, version_end_inclusive: true})

      assert [forward] = Loader.dedupe_coordinate_rows([excluding, including])
      assert [reverse] = Loader.dedupe_coordinate_rows([including, excluding])
      assert forward == reverse
      assert forward.version_start_inclusive == true
      assert forward.version_end_inclusive == true

      assert %{
               "expression_version" => 1,
               "affected_term_ids" => ["A", "B"],
               "expression" => %{
                 "kind" => "group",
                 "op" => "or",
                 "children" => alternatives
               }
             } = forward.metadata["nvd_applicability"]

      assert MapSet.new(alternatives, & &1["required_term_ids"]) ==
               MapSet.new([["A"], ["B"]])
    end

    test "metadata union is associative and keeps incompatible versions sticky" do
      advisory = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
      value = "cpe:2.3:a:openssl:openssl:*:*:*:*:*:*:*:*"

      a =
        advisory
        |> coord(value, "3.0.0", "3.0.14", "A", 1)
        |> update_in([:metadata], &Map.put(&1, "left_only", "left"))

      b = coord(advisory, value, "3.0.0", "3.0.14", "B", 2)

      c =
        advisory
        |> coord(value, "3.0.0", "3.0.14", "C", 1)
        |> update_in([:metadata], &Map.put(&1, "right_only", "right"))

      merged_rows =
        [a, b, c]
        |> permutations()
        |> Enum.map(fn rows ->
          assert [merged] = Loader.dedupe_coordinate_rows(rows)
          merged
        end)

      assert [merged] = Enum.uniq(merged_rows)

      assert %{
               "expression_versions" => [1, 2],
               "expression_version" => nil,
               "affected_term_ids" => ["A", "B", "C"],
               "expression" => %{"kind" => "group", "op" => "or", "children" => alternatives}
             } = merged.metadata["nvd_applicability"]

      assert MapSet.new(alternatives, & &1["required_term_ids"]) ==
               MapSet.new([["A"], ["B"], ["C"]])

      assert merged.metadata["left_only"] == "left"
      assert merged.metadata["right_only"] == "right"
    end

    test "metadata union is idempotent for duplicate rows and expressions" do
      advisory = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
      value = "cpe:2.3:a:openssl:openssl:*:*:*:*:*:*:*:*"
      a = coord(advisory, value, "3.0.0", "3.0.14", "A", 1)
      b = coord(advisory, value, "3.0.0", "3.0.14", "B", 1)

      assert Loader.dedupe_coordinate_rows([a, a]) == Loader.dedupe_coordinate_rows([a])
      assert Loader.dedupe_coordinate_rows([a, b, a, b]) == Loader.dedupe_coordinate_rows([a, b])

      assert [merged] = Loader.dedupe_coordinate_rows([a, b])
      assert merged.metadata["nvd_applicability"]["expression_versions"] == [1]
      assert merged.metadata["nvd_applicability"]["expression_version"] == 1
    end
  end

  describe "unchanged_advisory?/3" do
    # The bug this guards against: existing_modified_at/2 is a schemaless query
    # over a `timestamp without time zone` column, so Postgres hands back a
    # %NaiveDateTime{} while the parsed feed value is always a %DateTime{}. The
    # original guard pattern-matched %DateTime{} on both sides, so it returned
    # false for every record and the whole corpus was rewritten every run.
    #
    # A test that only ever builds `existing` with ~U[...] cannot see that, which
    # is exactly why it shipped. The NaiveDateTime case below is the regression.
    test "skips when the stored value is a NaiveDateTime, as Postgres returns it" do
      existing = state(~N[2024-01-15 12:34:56.123000])

      assert Loader.unchanged_advisory?(
               record("CVE-2024-0001", "2024-01-15T12:34:56.123"),
               existing,
               nil
             )
    end

    test "skips when the stored value is already a DateTime" do
      existing = state(~U[2024-01-15 12:34:56.123000Z])

      assert Loader.unchanged_advisory?(
               record("CVE-2024-0001", "2024-01-15T12:34:56.123"),
               existing,
               nil
             )
    end

    # compare/2, not ==. Postgres returns microsecond precision metadata while
    # the parsed input carries millisecond precision; same instant, not ==.
    test "skips across differing microsecond precision metadata" do
      existing = state(%{~U[2024-01-15 12:34:56Z] | microsecond: {0, 6}})
      incoming = record("CVE-2024-0001", "2024-01-15T12:34:56.0")

      assert Loader.unchanged_advisory?(incoming, existing, nil)
    end

    test "does not skip when modified_at actually changed" do
      existing = state(~N[2024-01-15 12:34:56.123000])

      refute Loader.unchanged_advisory?(
               record("CVE-2024-0001", "2024-02-01T00:00:00.000"),
               existing,
               nil
             )
    end

    test "does not skip an advisory the store has never seen" do
      refute Loader.unchanged_advisory?(
               record("CVE-2024-9999", "2024-01-15T12:34:56.123"),
               %{},
               nil
             )
    end

    # nil means UNKNOWN, never UNCHANGED. KEV emits no modified_at; treating a
    # nil/nil pair as equal would silently stop updating that feed forever.
    test "does not skip when either side is nil" do
      assert refute_skip(state(nil), record("CVE-2024-0001", "2024-01-15T12:34:56.123"))
      assert refute_skip(state(~N[2024-01-15 12:34:56.123000]), record("CVE-2024-0001", nil))
      assert refute_skip(state(nil), record("CVE-2024-0001", nil))
    end

    test "skips NVD only when both timestamp and normalization version match" do
      incoming = record("CVE-2024-0001", "2024-01-15T12:34:56.123")

      assert Loader.unchanged_advisory?(
               incoming,
               state(~N[2024-01-15 12:34:56.123000], 2),
               2
             )

      refute Loader.unchanged_advisory?(
               incoming,
               state(~N[2024-01-15 12:34:56.123000], 1),
               2
             )

      refute Loader.unchanged_advisory?(
               incoming,
               state(~N[2024-01-15 12:34:56.123000], nil),
               2
             )
    end

    test "does not skip a projected advisory when its normalized projection changed" do
      incoming =
        "CVE-2099-0001"
        |> record("2099-01-15T12:34:56.123")
        |> put_in([:advisory, :metadata], %{
          "normalization_version" => 2,
          "projection_digest" => String.duplicate("b", 64)
        })

      existing = %{
        "CVE-2099-0001" => %{
          modified_at: ~N[2099-01-15 12:34:56.123000],
          normalization_version: 2,
          projection_digest: String.duplicate("a", 64)
        }
      }

      matching =
        put_in(existing, ["CVE-2099-0001", :projection_digest], String.duplicate("b", 64))

      refute Loader.unchanged_advisory?(incoming, existing, 2)

      assert Loader.unchanged_advisory?(
               incoming,
               matching,
               2
             )

      missing_projection =
        record("CVE-2099-0001", "2099-01-15T12:34:56.123")

      refute Loader.unchanged_advisory?(
               missing_projection,
               matching,
               2
             )
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

    test "canonicalizes duplicate coordinate winners independently of input order" do
      assert Loader.content_hash(duplicate_coordinate_record()) ==
               Loader.content_hash(reversed_duplicate_coordinate_record())

      [forward_winner] = Loader.dedupe_coordinate_rows(duplicate_coordinate_rows())
      [reverse_winner] = Loader.dedupe_coordinate_rows(Enum.reverse(duplicate_coordinate_rows()))

      assert forward_winner == reverse_winner
      assert forward_winner.cpe_product == "alpha"
      assert forward_winner.metadata == %{"match_criteria_id" => "alternate-coordinate"}
    end

    test "hashes persisted-equivalent timestamp precision identically" do
      assert Loader.content_hash(timestamp_precision_record("2026-01-15T12:34:56.123Z")) ==
               Loader.content_hash(timestamp_precision_record("2026-01-15T12:34:56.123000Z"))
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

    test "normalizes legacy modified state when newer state options are omitted" do
      modified_at = ~U[2026-01-15 12:34:56.123Z]

      assert {:ok,
              %{
                "CVE-2026-0002" => %{
                  modified_at: ^modified_at,
                  content_hash: nil,
                  normalization_version: nil,
                  projection_digest: nil
                }
              }} =
               Loader.existing_state_from_options(
                 existing_modified: %{"CVE-2026-0002" => modified_at}
               )
    end

    test "prefers explicit state, then comparison state, then legacy modified state" do
      explicit_state = %{
        "explicit" => %{
          modified_at: ~U[2026-01-15 12:34:56.123Z],
          content_hash: String.duplicate("a", 64),
          normalization_version: 3,
          projection_digest: String.duplicate("b", 64)
        }
      }

      comparison_state = %{
        "comparison" => %{
          modified_at: ~U[2026-02-01 00:00:00Z],
          content_hash: String.duplicate("c", 64)
        }
      }

      legacy_modified = %{"legacy" => ~U[2026-03-01 00:00:00Z]}

      assert {:ok, ^explicit_state} =
               Loader.existing_state_from_options(
                 existing_state: explicit_state,
                 existing_comparison_state: comparison_state,
                 existing_modified: legacy_modified
               )

      assert {:ok,
              %{
                "comparison" => %{
                  modified_at: ~U[2026-02-01 00:00:00Z],
                  content_hash: content_hash,
                  normalization_version: nil,
                  projection_digest: nil
                }
              }} =
               Loader.existing_state_from_options(
                 existing_comparison_state: comparison_state,
                 existing_modified: legacy_modified
               )

      assert content_hash == String.duplicate("c", 64)
      assert :error = Loader.existing_state_from_options([])
    end
  end

  describe "chunk_by_serialized_size/3" do
    test "bounds chunks by both row count and serialized bytes" do
      small_a = %{id: "a", payload: String.duplicate("a", 80)}
      small_b = %{id: "b", payload: String.duplicate("b", 80)}
      large = %{id: "large", payload: String.duplicate("c", 400)}
      small_c = %{id: "c", payload: String.duplicate("d", 80)}

      byte_cap =
        byte_size(:erlang.term_to_binary(small_a)) +
          byte_size(:erlang.term_to_binary(small_b)) - 1

      assert [[^small_a], [^small_b], [^large], [^small_c]] =
               [small_a, small_b, large, small_c]
               |> Loader.chunk_by_serialized_size(2, byte_cap)
               |> Enum.to_list()
    end
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
      ],
      assertions: []
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
      },
      assertions: []
    }
  end

  describe "validate_completeness/1" do
    test "accepts an explicitly complete and validated source snapshot" do
      assert :ok = Loader.validate_completeness(valid_completeness())
    end

    test "rejects empty, partial, corrupt, errored, and structurally incomplete snapshots" do
      invalid = [
        put_in(valid_completeness(), [:source_objects_seen], 0),
        put_in(valid_completeness(), [:complete_snapshot?], false),
        put_in(valid_completeness(), [:validation, "records", "complete"], false),
        put_in(valid_completeness(), [:parse_errors], 1),
        put_in(valid_completeness(), [:read_errors], 1),
        put_in(valid_completeness(), [:required_trees], ["records", "missing"])
      ]

      for completeness <- invalid do
        assert {:error, {:incomplete_snapshot, reasons}} =
                 Loader.validate_completeness(completeness)

        assert [_ | _] = reasons
      end
    end
  end

  defp refute_skip(existing, rec), do: not Loader.unchanged_advisory?(rec, existing, nil)

  defp state(modified_at, normalization_version \\ nil, projection_digest \\ nil) do
    %{
      "CVE-2024-0001" => %{
        modified_at: modified_at,
        content_hash: nil,
        normalization_version: normalization_version,
        projection_digest: projection_digest
      }
    }
  end

  defp changed_description_record do
    put_in(kev_record(), [:advisory, :description], "A changed exploitable vulnerability.")
  end

  defp changed_coordinate_record do
    put_in(kev_record(), [:coordinates, Access.at(0), :cpe_version], "1.0.1")
  end

  defp duplicate_coordinate_record do
    put_in(kev_record(), [:coordinates], duplicate_coordinates())
  end

  defp reversed_duplicate_coordinate_record do
    put_in(kev_record(), [:coordinates], Enum.reverse(duplicate_coordinates()))
  end

  defp duplicate_coordinates do
    [
      %{
        coordinate_type: "cpe",
        value: "cpe:2.3:a:example:widget:1.0:*:*:*:*:*:*:*",
        cpe_part: "a",
        cpe_vendor: "example",
        cpe_product: "zeta",
        cpe_version: "1.0",
        version_start: "1.0",
        version_start_inclusive: true,
        version_end: "1.4",
        version_end_inclusive: false,
        metadata: %{"match_criteria_id" => "alternate-coordinate"}
      },
      %{
        coordinate_type: "cpe",
        value: "cpe:2.3:a:example:widget:1.0:*:*:*:*:*:*:*",
        cpe_part: "a",
        cpe_vendor: "example",
        cpe_product: "alpha",
        cpe_version: "1.0",
        version_start: "1.0",
        version_start_inclusive: true,
        version_end: "1.4",
        version_end_inclusive: false,
        metadata: %{"match_criteria_id" => "canonical-coordinate"}
      }
    ]
  end

  defp duplicate_coordinate_rows do
    Enum.map(
      duplicate_coordinates(),
      &Map.put(&1, :advisory_ref, "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
    )
  end

  defp timestamp_precision_record(published_at) do
    put_in(kev_record(), [:advisory, :published_at], published_at)
  end

  defp record(source_object_id, modified_at) do
    %{
      advisory: %{source_object_id: source_object_id, modified_at: modified_at},
      coordinates: [],
      assertions: []
    }
  end

  defp valid_completeness do
    %{
      complete_snapshot?: true,
      source_objects_seen: 1,
      expected_minimum: 1,
      parse_errors: 0,
      read_errors: 0,
      required_trees: ["records"],
      validation: %{"records" => %{"complete" => true, "count" => 1}}
    }
  end

  defp coord(advisory_ref, value, version_start, version_end, match_id, expression_version \\ 1) do
    %{
      advisory_ref: advisory_ref,
      coordinate_type: "cpe",
      value: value,
      version_start: version_start,
      version_start_inclusive: nil,
      version_end: version_end,
      version_end_inclusive: nil,
      metadata: %{
        "match_criteria_id" => match_id,
        "nvd_applicability" => %{
          "expression_version" => expression_version,
          "affected_term_ids" => [match_id],
          "expression" => %{
            "kind" => "group",
            "node_id" => "configuration-#{match_id}",
            "path" => "configuration-#{match_id}",
            "op" => "and",
            "negate" => false,
            "children" => [
              %{
                "kind" => "cpe",
                "term_id" => match_id,
                "path" => "term-#{match_id}",
                "role" => "affected",
                "vulnerable" => true,
                "criteria" => value,
                "bounds" => %{
                  "version_start" => version_start,
                  "version_start_inclusive" => false,
                  "version_end" => version_end,
                  "version_end_inclusive" => false
                }
              }
            ],
            "required_term_ids" => [match_id]
          }
        }
      }
    }
  end

  defp permutations([]), do: [[]]

  defp permutations(values) do
    for value <- values,
        rest <- permutations(List.delete(values, value)) do
      [value | rest]
    end
  end
end
