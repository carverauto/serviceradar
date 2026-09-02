defmodule ServiceRadarWebNGWeb.TimestampFormatterInventoryTest do
  @moduledoc """
  Keeps every direct production timestamp formatter classified at the UI boundary.

  A direct formatter is either the shared explicit-zone presentation contract or a
  deliberate non-presentation use. Human-visible absolute timestamps are migration
  work, not permanent exceptions, so `localized_display` entries fail this test.
  """

  use ExUnit.Case, async: true

  @moduletag :db_free

  @web_ng_root Path.expand("../..", __DIR__)
  @inventory_path Path.join(@web_ng_root, "test/fixtures/timestamp_formatter_inventory.json")

  # Keep these regexes byte-for-byte aligned with the OpenSpec inventory contract.
  # The Intl matcher covers both the global object and the shared formatter's injected
  # lowercase capability seam so direct constructors cannot evade classification.
  @matchers [
    {"calendar_strftime", ~r/Calendar\.strftime\(/},
    {"datetime_iso8601", ~r/DateTime\.to_iso8601\(/},
    {"naive_datetime_iso8601", ~r/NaiveDateTime\.to_iso8601\(/},
    {"datetime_string", ~r/(?<!Naive)DateTime\.to_string\(/},
    {"naive_datetime_string", ~r/NaiveDateTime\.to_string\(/},
    {"datetime_pipe_string",
     ~r/(?:DateTime|NaiveDateTime)\.(?:truncate|shift_zone!?|from_naive!?|utc_now)\([^)]*\)\s*\|>\s*(?:Kernel\.)?to_string\(/s},
    {"js_to_iso_string", ~r/\.toISOString\(\)/},
    {"js_to_locale_time", ~r/\.toLocale(?:String|DateString|TimeString)\(/},
    {"intl_date_time_format", ~r/\b(?:Intl|intl)\.DateTimeFormat\(/}
  ]

  @expected_active_matchers MapSet.new([
                              "calendar_strftime",
                              "datetime_iso8601",
                              "datetime_string",
                              "naive_datetime_iso8601",
                              "js_to_iso_string",
                              "js_to_locale_time",
                              "intl_date_time_format"
                            ])

  @known_matchers MapSet.new(Enum.map(@matchers, &elem(&1, 0)))
  @known_classifications MapSet.new([
                           "localized_display",
                           "canonical_machine",
                           "relative",
                           "fixed_utc",
                           "infrastructure"
                         ])

  test "checked inventory exactly classifies production formatter call sites" do
    inventory = @inventory_path |> File.read!() |> Jason.decode!()
    discovered = discover_formatter_calls()

    assert is_list(inventory), "timestamp formatter inventory must be a JSON array"

    # Human-display entries intentionally disappear as they move to UserTime, so
    # keep this floor below the post-migration canonical/infrastructure corpus.
    assert length(discovered) > 100,
           "formatter scan is unexpectedly small (#{length(discovered)} matches); source inputs are missing"

    assert Enum.count(discovered, &String.starts_with?(&1.path, "lib/")) > 100,
           "formatter scan did not inspect the production Elixir tree"

    assert Enum.count(discovered, &String.starts_with?(&1.path, "assets/js/")) > 5,
           "formatter scan did not inspect the production JavaScript tree"

    present_matchers = MapSet.new(discovered, & &1.matcher)

    assert MapSet.subset?(@expected_active_matchers, present_matchers), """
    expected formatter matcher families disappeared unexpectedly

    required active families: #{inspect(@expected_active_matchers)}
    discovered families:     #{inspect(present_matchers)}

    The direct Intl constructor family includes both global and injected capability
    seams and must remain present in the checked inventory.
    """

    validation_errors = validate_inventory(inventory)

    assert validation_errors == [],
           "invalid timestamp formatter inventory:\n" <> Enum.map_join(validation_errors, "\n", &"  #{&1}")

    inventory_keys = Enum.map(inventory, &entry_key/1)
    duplicate_keys = inventory_keys -- Enum.uniq(inventory_keys)

    assert duplicate_keys == [],
           "duplicate timestamp formatter inventory keys:\n" <> format_keys(duplicate_keys)

    discovered_duplicate_keys = duplicate_discovered_keys(discovered)

    assert discovered_duplicate_keys == [], """
    duplicate discovered timestamp formatter identities:
    #{format_keys(discovered_duplicate_keys)}

    Repeated direct formatter calls must have distinct source fingerprints so each
    call site remains independently represented in the checked inventory.
    """

    discovered_by_key = Map.new(discovered, &{entry_key(&1), &1})
    inventory_key_set = MapSet.new(inventory_keys)
    discovered_key_set = MapSet.new(Map.keys(discovered_by_key))

    missing = MapSet.difference(discovered_key_set, inventory_key_set)
    stale = MapSet.difference(inventory_key_set, discovered_key_set)

    assert MapSet.size(missing) == 0 and MapSet.size(stale) == 0,
           inventory_difference_message(missing, stale, discovered_by_key)

    localized =
      inventory
      |> Enum.filter(&(&1["classification"] == "localized_display"))
      |> Enum.map(fn entry -> Map.fetch!(discovered_by_key, entry_key(entry)) end)

    assert localized == [], """
    Direct human-display timestamp formatters remain. Render each through the shared
    explicit-zone UserTime contract, then remove its inventory entry:
    #{format_discovered(localized)}
    """
  end

  test "production source discovery includes standalone HEEx and component entrypoints" do
    sources = MapSet.new(production_sources(), &Path.relative_to(&1, @web_ng_root))

    assert MapSet.member?(
             sources,
             "lib/serviceradar_web_ng_web/components/layouts/root.html.heex"
           )

    assert MapSet.member?(sources, "assets/component/index.js")
  end

  test "production JavaScript exclusions cover nonproduction component trees" do
    excluded_paths = [
      "assets/component/test/fixture.js",
      "assets/component/vendor/fixture.js",
      "assets/component/generated/fixture.js",
      "assets/component/static/fixture.js",
      "assets/component/node_modules/fixture.js"
    ]

    assert Enum.all?(excluded_paths, fn relative ->
             relative
             |> then(&Path.join(@web_ng_root, &1))
             |> excluded_javascript_source?()
           end)
  end

  test "formatter identity follows source fingerprint across replacement and reordering" do
    original = %{
      path: "assets/component/index.js",
      matcher: "js_to_iso_string",
      occurrence: 1,
      fingerprint: String.duplicate("a", 64)
    }

    replacement = %{original | fingerprint: String.duplicate("b", 64)}
    reordered = %{original | occurrence: 2}

    refute entry_key(original) == entry_key(replacement)
    assert entry_key(original) == entry_key(reordered)
  end

  test "discovered formatter identity collisions remain visible to the audit" do
    fingerprint = String.duplicate("a", 64)

    discovered = [
      %{
        path: "assets/component/index.js",
        matcher: "js_to_iso_string",
        occurrence: 1,
        fingerprint: fingerprint
      },
      %{
        path: "assets/component/index.js",
        matcher: "js_to_iso_string",
        occurrence: 2,
        fingerprint: fingerprint
      }
    ]

    assert duplicate_discovered_keys(discovered) == [
             {"assets/component/index.js", "js_to_iso_string", fingerprint}
           ]
  end

  defp discover_formatter_calls do
    production_sources()
    |> Enum.flat_map(fn path ->
      source = File.read!(path)
      relative = Path.relative_to(path, @web_ng_root)

      Enum.flat_map(@matchers, fn {matcher, regex} ->
        regex
        |> Regex.scan(source, return: :index)
        |> Enum.with_index(1)
        |> Enum.map(fn {[{offset, _length} | _captures], occurrence} ->
          %{
            path: relative,
            matcher: matcher,
            occurrence: occurrence,
            line: source_line(source, offset),
            fingerprint: source_fingerprint(source, offset)
          }
        end)
      end)
    end)
    |> Enum.sort_by(&display_key/1)
  end

  defp production_sources do
    elixir_sources =
      Enum.flat_map(["ex", "heex"], fn extension ->
        Path.wildcard(Path.join(@web_ng_root, "lib/**/*.#{extension}"))
      end)

    javascript_roots = [
      Path.join(@web_ng_root, "assets/js"),
      Path.join(@web_ng_root, "assets/component")
    ]

    javascript_sources =
      javascript_roots
      |> Enum.flat_map(fn root ->
        Enum.flat_map(["js", "jsx", "ts", "tsx"], fn extension ->
          root
          |> Path.join("**/*.#{extension}")
          |> Path.wildcard()
        end)
      end)
      |> Enum.reject(&excluded_javascript_source?/1)

    elixir_sources ++ javascript_sources
  end

  defp excluded_javascript_source?(path) do
    relative = Path.relative_to(path, @web_ng_root)

    Regex.match?(~r/\.(?:test|spec)\.(?:js|jsx|ts|tsx)\z/, relative) or
      Regex.match?(
        ~r/(?:^|\/)(?:test|__tests__|node_modules|vendor|generated|static)(?:\/|$)/,
        relative
      )
  end

  defp validate_inventory(inventory) do
    inventory
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {entry, index} -> validate_entry(entry, index) end)
  end

  defp validate_entry(entry, index) when is_map(entry) do
    path = entry["path"]
    matcher = entry["matcher"]
    occurrence = entry["occurrence"]
    fingerprint = entry["fingerprint"]
    classification = entry["classification"]
    reason = entry["reason"]

    []
    |> maybe_error(not (is_binary(path) and path != ""), "entry #{index} has an invalid path")
    |> maybe_error(
      is_binary(path) and not File.regular?(Path.join(@web_ng_root, path)),
      "entry #{index} references missing file #{inspect(path)}"
    )
    |> maybe_error(not MapSet.member?(@known_matchers, matcher), "entry #{index} has unknown matcher #{inspect(matcher)}")
    |> maybe_error(
      not (is_integer(occurrence) and occurrence > 0),
      "entry #{index} has invalid occurrence #{inspect(occurrence)}"
    )
    |> maybe_error(
      not valid_fingerprint?(fingerprint),
      "entry #{index} has invalid fingerprint #{inspect(fingerprint)}"
    )
    |> maybe_error(
      not MapSet.member?(@known_classifications, classification),
      "entry #{index} has unknown classification #{inspect(classification)}"
    )
    |> maybe_error(
      classification in ["fixed_utc", "infrastructure"] and not non_empty_string?(reason),
      "entry #{index} requires a non-empty reason for #{inspect(classification)}"
    )
  end

  defp validate_entry(_entry, index), do: ["entry #{index} must be a JSON object"]

  defp maybe_error(errors, true, message), do: [message | errors]
  defp maybe_error(errors, false, _message), do: errors

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp valid_fingerprint?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp entry_key(entry),
    do: {entry["path"] || entry.path, entry["matcher"] || entry.matcher, entry["fingerprint"] || entry.fingerprint}

  defp display_key(entry),
    do: {entry["path"] || entry.path, entry["matcher"] || entry.matcher, entry["occurrence"] || entry.occurrence}

  defp duplicate_discovered_keys(discovered) do
    discovered
    |> Enum.map(&entry_key/1)
    |> Enum.frequencies()
    |> Enum.filter(fn {_key, count} -> count > 1 end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp source_line(source, offset) do
    source
    |> binary_part(0, offset)
    |> :binary.matches("\n")
    |> length()
    |> Kernel.+(1)
  end

  defp source_fingerprint(source, offset) do
    prefix = binary_part(source, 0, offset)
    line_index = length(:binary.matches(prefix, "\n"))
    source_lines = String.split(source, "\n", trim: false)

    scope_context =
      source_lines
      |> Enum.take(line_index + 1)
      |> Enum.reverse()
      |> Enum.find("", &source_scope_line?/1)
      |> normalize_source_context()

    normalized_context =
      source_lines
      |> Enum.slice(max(line_index - 1, 0), 3)
      |> Enum.map_join("\n", &normalize_source_context/1)

    normalized_column =
      prefix
      |> String.split("\n")
      |> List.last()
      |> String.replace(~r/\s+/, "")
      |> byte_size()

    :sha256
    |> :crypto.hash("#{scope_context}\n#{normalized_column}\n#{normalized_context}")
    |> Base.encode16(case: :lower)
  end

  defp source_scope_line?(line) do
    Regex.match?(
      ~r/^\s*(?:defmodule\s+|defp?\s+|(?:export\s+)?(?:async\s+)?function\s+|(?:export\s+)?(?:const|let|var)\s+[A-Za-z_$][\w$]*\s*=)/,
      line
    )
  end

  defp normalize_source_context(line) do
    line
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
  end

  defp inventory_difference_message(missing, stale, discovered_by_key) do
    missing_entries = Enum.map(missing, &Map.fetch!(discovered_by_key, &1))

    """
    timestamp formatter inventory does not match production sources

    unclassified production formatters:
    #{format_discovered(missing_entries)}

    stale inventory keys:
    #{format_keys(stale)}
    """
  end

  defp format_discovered(entries) do
    entries
    |> Enum.sort_by(&display_key/1)
    |> Enum.take(60)
    |> Enum.map_join("\n", fn entry ->
      "  #{entry.path}:#{entry.line} #{entry.matcher}##{entry.occurrence} fingerprint=#{String.slice(entry.fingerprint, 0, 12)}"
    end)
    |> append_omitted_count(length(entries), 60)
  end

  defp format_keys(keys) do
    keys
    |> Enum.sort()
    |> Enum.take(60)
    |> Enum.map_join("\n", fn {path, matcher, fingerprint} ->
      "  #{path} #{matcher} fingerprint=#{String.slice(fingerprint || "missing", 0, 12)}"
    end)
    |> append_omitted_count(Enum.count(keys), 60)
  end

  defp append_omitted_count(text, count, limit) when count > limit, do: text <> "\n  ... and #{count - limit} more"

  defp append_omitted_count(text, _count, _limit), do: text
end
