defmodule ServiceRadar.AgentConfig.Compilers.SweepCompilerSharedTargetsTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.AgentConfig.Compilers.SweepCompiler
  alias ServiceRadar.AgentConfig.ConfigCache
  alias ServiceRadar.SweepJobs.SweepGroup

  @lab_query "in:devices tags.env:lab"

  setup do
    case start_supervised(ConfigCache) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    ConfigCache.invalidate(:sweep)
    :ok
  end

  defp group(attrs) do
    struct!(
      SweepGroup,
      Map.merge(
        %{
          description: nil,
          schedule_type: :interval,
          interval: "15m",
          cron_expression: nil,
          static_targets: [],
          target_query: nil,
          partition: nil,
          ports: nil,
          sweep_modes: nil,
          overrides: %{},
          profile_id: nil
        },
        attrs
      )
    )
  end

  # Page two repeats 198.51.100.10 under another device (first row seen
  # wins), carries a uid-less row, and rows that never become targets.
  defp fake_inventory(test_pid) do
    fn query, opts ->
      cursor = Keyword.get(opts, :cursor)
      send(test_pid, {:srql_page, query, cursor})

      case {query, cursor} do
        {@lab_query, nil} ->
          {:ok,
           %{
             rows: [
               %{"ip" => "198.51.100.11", "uid" => "sr:dev-0002"},
               %{"ip" => "198.51.100.10", "uid" => "sr:dev-0001"}
             ],
             next_cursor: "page-2"
           }}

        {@lab_query, "page-2"} ->
          {:ok,
           %{
             rows: [
               %{"ip" => "198.51.100.12", "uid" => "sr:dev-0003"},
               %{"ip" => "198.51.100.10", "uid" => "sr:dev-0099"},
               %{"ip" => "198.51.100.20"},
               %{"ip" => "not-an-ip", "uid" => "sr:dev-0004"}
             ],
             next_cursor: nil
           }}
      end
    end
  end

  defp three_profiles_one_query do
    [
      group(%{id: "sg-a", name: "lab-icmp", target_query: @lab_query}),
      group(%{
        id: "sg-b",
        name: "lab-tcp",
        target_query: @lab_query,
        sweep_modes: ["tcp"],
        ports: [443]
      }),
      # Stored without the in:devices prefix; normalizes to the same query.
      group(%{id: "sg-c", name: "lab-both", target_query: "tags.env:lab"}),
      group(%{id: "sg-static", name: "static-only", static_targets: ["192.0.2.0/30"]})
    ]
  end

  defp compile_shared(groups, extra_opts \\ []) do
    SweepCompiler.compile_groups(
      groups,
      %{},
      [format: :shared_targets_v1, query_page_fn: fake_inventory(self())] ++ extra_opts
    )
  end

  # Decision 5 rehydration, mirrored here so the equivalence test pins the
  # wire contract the Go agent will implement in section 4.
  defp rehydrate(document) do
    table = Map.new(document["device_table"], &{&1["ref"], &1})
    sets = Map.new(document["target_sets"], &{&1["key"], &1["refs"]})

    Map.new(document["groups"], fn group ->
      targets =
        case group["device_target_set"] do
          nil ->
            []

          key ->
            Enum.map(sets[key], fn ref ->
              entry = table[ref]

              %{
                "network" => entry["ip"],
                "sweep_modes" => group["modes"],
                "query_label" => group["name"],
                "source" => "srql",
                "metadata" =>
                  case entry["device_uid"] do
                    nil -> %{}
                    uid -> %{"device_uid" => uid}
                  end
              }
            end)
        end

      {group["id"], targets}
    end)
  end

  test "three profiles over one query share one target set and one table entry per device" do
    assert {:shared_targets_v1, document, _legacy} = compile_shared(three_profiles_one_query())

    assert document["format"] == "shared-targets/v1"
    assert [%{"key" => key, "refs" => refs}] = document["target_sets"]
    assert key == "q-" <> sha16(@lab_query)

    # Refs are in legacy order (sorted by IP): .10 (dev-0001 wins over the
    # page-two repeat), .11, .12, then the uid-less .20.
    assert refs == ["sr:dev-0001", "sr:dev-0002", "sr:dev-0003", "ip:198.51.100.20"]

    table = document["device_table"]
    assert Enum.map(table, & &1["ref"]) == Enum.sort(refs)

    assert %{"ref" => "ip:198.51.100.20", "ip" => "198.51.100.20"} =
             by_ref(table, "ip:198.51.100.20")

    refute Map.has_key?(by_ref(table, "ip:198.51.100.20"), "device_uid")

    # The two pages were fetched once for all three groups.
    assert_received {:srql_page, @lab_query, nil}
    assert_received {:srql_page, @lab_query, "page-2"}
    refute_received {:srql_page, _, _}

    for id <- ["sg-a", "sg-b", "sg-c"] do
      group = Enum.find(document["groups"], &(&1["id"] == id))
      assert group["device_target_set"] == key
      assert group["target_query"] == @lab_query
      refute Map.has_key?(group, "device_targets")
    end

    static = Enum.find(document["groups"], &(&1["id"] == "sg-static"))
    assert static["targets"] == ["192.0.2.0/30"]
    refute Map.has_key?(static, "device_target_set")
    refute Map.has_key?(static, "target_query")
  end

  test "rehydrating the shared document reproduces the legacy device_targets exactly" do
    groups = three_profiles_one_query()

    legacy =
      SweepCompiler.compile_groups(groups, %{}, query_page_fn: fake_inventory(self()))

    assert is_list(legacy)
    flush_pages()

    assert {:shared_targets_v1, document, _legacy} = compile_shared(groups)

    legacy_by_id =
      Map.new(legacy, fn group -> {group["id"], group["device_targets"] || []} end)

    assert rehydrate(document) == legacy_by_id
  end

  test "alias IPs become table entries carrying the owning device_uid" do
    groups = [group(%{id: "sg-a", name: "lab-icmp", target_query: @lab_query})]

    alias_fn = fn uids ->
      {:ok, Map.new(uids, &{&1, if(&1 == "sr:dev-0001", do: ["198.51.100.99"], else: [])})}
    end

    assert {:shared_targets_v1, document, _legacy} =
             compile_shared(groups, alias_ips_fn: alias_fn)

    alias_entry =
      Enum.find(document["device_table"], &(&1["ip"] == "198.51.100.99"))

    assert alias_entry["device_uid"] == "sr:dev-0001"
    assert alias_entry["ref"] in hd(document["target_sets"])["refs"]

    legacy =
      SweepCompiler.compile_groups(groups, %{},
        query_page_fn: fake_inventory(self()),
        alias_ips_fn: alias_fn
      )

    legacy_by_id =
      Map.new(legacy, fn group -> {group["id"], group["device_targets"] || []} end)

    assert rehydrate(document) == legacy_by_id
  end

  test "shared document and hash are stable under shuffled group and row order" do
    groups = three_profiles_one_query()

    assert {:shared_targets_v1, document, _} = compile_shared(groups)
    flush_pages()

    assert {:shared_targets_v1, shuffled, _} = compile_shared(Enum.reverse(groups))

    assert shuffled == document

    assert SweepCompiler.shared_config_hash(document) ==
             SweepCompiler.shared_config_hash(shuffled)
  end

  test "an unknown format is an error, not a silent legacy compile" do
    assert {:error, {:unsupported_sweep_format, :yaml}} =
             SweepCompiler.compile_groups(three_profiles_one_query(), %{},
               format: :yaml,
               query_page_fn: fake_inventory(self())
             )
  end

  defp single_page(rows_by_query) do
    fn query, _opts -> {:ok, %{rows: Map.fetch!(rows_by_query, query), next_cursor: nil}} end
  end

  @db_query "in:devices tags.role:db"

  test "partial overlap: a device matched by two queries is one entry referenced by both sets" do
    rows = %{
      @lab_query => [
        %{"ip" => "198.51.100.10", "uid" => "sr:dev-0001"},
        %{"ip" => "198.51.100.11", "uid" => "sr:dev-0002"}
      ],
      @db_query => [
        %{"ip" => "198.51.100.11", "uid" => "sr:dev-0002"},
        %{"ip" => "198.51.100.12", "uid" => "sr:dev-0003"}
      ]
    }

    groups = [
      group(%{id: "sg-lab", name: "lab", target_query: @lab_query}),
      group(%{id: "sg-db", name: "db", target_query: @db_query})
    ]

    assert {:shared_targets_v1, document, _} =
             SweepCompiler.compile_groups(groups, %{},
               format: :shared_targets_v1,
               query_page_fn: single_page(rows)
             )

    assert length(document["target_sets"]) == 2

    assert Enum.map(document["device_table"], & &1["ref"]) == [
             "sr:dev-0001",
             "sr:dev-0002",
             "sr:dev-0003"
           ]

    for set <- document["target_sets"] do
      assert "sr:dev-0002" in set["refs"]
    end

    legacy =
      SweepCompiler.compile_groups(groups, %{}, query_page_fn: single_page(rows))

    legacy_by_id =
      Map.new(legacy, fn group -> {group["id"], group["device_targets"] || []} end)

    assert rehydrate(document) == legacy_by_id
  end

  test "two devices sharing an IP under different queries stay two table entries" do
    rows = %{
      @lab_query => [%{"ip" => "198.51.100.10", "uid" => "sr:dev-0001"}],
      @db_query => [%{"ip" => "198.51.100.10", "uid" => "sr:dev-0002"}]
    }

    groups = [
      group(%{id: "sg-lab", name: "lab", target_query: @lab_query}),
      group(%{id: "sg-db", name: "db", target_query: @db_query})
    ]

    assert {:shared_targets_v1, document, _} =
             SweepCompiler.compile_groups(groups, %{},
               format: :shared_targets_v1,
               query_page_fn: single_page(rows)
             )

    assert document["device_table"] == [
             %{"ref" => "sr:dev-0001", "ip" => "198.51.100.10", "device_uid" => "sr:dev-0001"},
             %{"ref" => "sr:dev-0002", "ip" => "198.51.100.10", "device_uid" => "sr:dev-0002"}
           ]

    refs_by_query =
      Map.new(document["target_sets"], fn set -> {set["target_query"], set["refs"]} end)

    assert refs_by_query[@lab_query] == ["sr:dev-0001"]
    assert refs_by_query[@db_query] == ["sr:dev-0002"]

    legacy =
      SweepCompiler.compile_groups(groups, %{}, query_page_fn: single_page(rows))

    legacy_by_id =
      Map.new(legacy, fn group -> {group["id"], group["device_targets"] || []} end)

    assert rehydrate(document) == legacy_by_id
  end

  test "document is stable under shuffled row order when no IP is shared" do
    groups = [group(%{id: "sg-a", name: "lab-icmp", target_query: @lab_query})]

    rows = [
      %{"ip" => "198.51.100.10", "uid" => "sr:dev-0001"},
      %{"ip" => "198.51.100.11", "uid" => "sr:dev-0002"},
      %{"ip" => "198.51.100.12", "uid" => "sr:dev-0003"}
    ]

    assert {:shared_targets_v1, document, _} =
             SweepCompiler.compile_groups(groups, %{},
               format: :shared_targets_v1,
               query_page_fn: single_page(%{@lab_query => rows})
             )

    ConfigCache.invalidate(:sweep)

    assert {:shared_targets_v1, shuffled, _} =
             SweepCompiler.compile_groups(groups, %{},
               format: :shared_targets_v1,
               query_page_fn: single_page(%{@lab_query => Enum.reverse(rows)})
             )

    assert shuffled == document
  end

  defp by_ref(table, ref), do: Enum.find(table, &(&1["ref"] == ref))

  defp sha16(string) do
    :sha256 |> :crypto.hash(string) |> Base.encode16(case: :lower) |> String.slice(0, 16)
  end

  defp flush_pages do
    receive do
      {:srql_page, _, _} -> flush_pages()
    after
      0 -> :ok
    end
  end
end
