defmodule ServiceRadar.AgentConfig.Compilers.SweepCompilerTargetsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.AgentConfig.Compilers.SweepCompiler
  alias ServiceRadar.AgentConfig.ConfigCache
  alias ServiceRadar.SweepJobs.SweepGroup

  @lab_query "in:devices tags.env:lab"
  @edge_query "in:devices tags.env:edge"

  @static_id "sg-static"
  @lab_icmp_id "sg-lab-icmp"
  @lab_tcp_id "sg-lab-icmp-tcp"
  @edge_id "sg-edge-tcp"

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
          ports: nil,
          sweep_modes: nil,
          overrides: %{},
          profile_id: nil
        },
        attrs
      )
    )
  end

  defp pinned_groups do
    [
      group(%{id: @static_id, name: "static-only", static_targets: ["192.0.2.0/30"]}),
      group(%{id: @lab_icmp_id, name: "lab-icmp", target_query: @lab_query}),
      group(%{
        id: @lab_tcp_id,
        name: "lab-icmp-tcp",
        target_query: @lab_query,
        sweep_modes: ["icmp", "tcp"],
        ports: [80, 443]
      }),
      # Stored without the in:devices prefix; the compiler normalizes it.
      group(%{
        id: @edge_id,
        name: "edge-tcp",
        target_query: "tags.env:edge",
        sweep_modes: ["tcp"],
        ports: [22]
      })
    ]
  end

  # Two pages for the lab query. Page two repeats 198.51.100.10 under another
  # device (the first row seen for an IP wins) and carries rows with an
  # unusable IP, which never become targets.
  defp fake_inventory(test_pid) do
    fn query, opts ->
      cursor = Keyword.get(opts, :cursor)
      send(test_pid, {:srql_page, query, cursor})

      case {query, cursor} do
        {@lab_query, nil} ->
          {:ok,
           %{
             rows: [
               %{
                 "ip" => "198.51.100.11",
                 "uid" => "sr:dev-0002",
                 "hostname" => "host02.example.com"
               },
               %{
                 "ip" => "198.51.100.10",
                 "uid" => "sr:dev-0001",
                 "hostname" => "host01.example.com",
                 "discovery_sources" => ["sweep", "mapper", "sweep", ""]
               }
             ],
             next_cursor: "page-2"
           }}

        {@lab_query, "page-2"} ->
          {:ok,
           %{
             rows: [
               %{"ip" => " 198.51.100.12 ", "uid" => "sr:dev-0003"},
               %{
                 "ip" => "198.51.100.10",
                 "uid" => "sr:dev-0099",
                 "hostname" => "stale.example.com"
               },
               %{"ip" => "not-an-ip", "uid" => "sr:dev-0004"},
               %{"ip" => nil, "uid" => "sr:dev-0005"},
               %{"uid" => "sr:dev-0006"}
             ],
             next_cursor: nil
           }}

        {@edge_query, nil} ->
          {:ok,
           %{
             rows: [
               %{
                 "ip" => "203.0.113.5",
                 "uid" => "sr:dev-0010",
                 "hostname" => "host10.example.com",
                 "discovery_sources" => "netbox"
               }
             ],
             next_cursor: nil
           }}

        {_other, nil} ->
          {:ok, %{rows: [%{"ip" => "198.51.100.200", "uid" => "sr:dev-0200"}], next_cursor: nil}}
      end
    end
  end

  defp failing_for(failing_query, failure, test_pid) do
    inventory = fake_inventory(test_pid)

    fn query, opts ->
      if query == failing_query do
        send(test_pid, {:srql_page, query, Keyword.get(opts, :cursor)})
        failure.(opts)
      else
        inventory.(query, opts)
      end
    end
  end

  defp compile_by_id(groups, opts) do
    groups
    |> SweepCompiler.compile_groups(%{}, opts)
    |> Map.new(&{&1["id"], &1})
  end

  # First-page requests made so far, one per query execution.
  defp query_executions do
    receive do
      {:srql_page, query, nil} -> [query | query_executions()]
      {:srql_page, _query, _cursor} -> query_executions()
    after
      0 -> []
    end
  end

  defp networks(compiled_group),
    do: Enum.map(compiled_group["device_targets"] || [], & &1["network"])

  describe "compiled target output" do
    test "static targets, shared and distinct target queries compile to the pinned shape" do
      compiled = compile_by_id(pinned_groups(), query_page_fn: fake_inventory(self()))

      static = Map.fetch!(compiled, @static_id)
      assert static["targets"] == ["192.0.2.0/30"]
      refute Map.has_key?(static, "device_targets")

      assert Map.fetch!(compiled, @lab_icmp_id)["device_targets"] == [
               %{
                 "network" => "198.51.100.10",
                 "sweep_modes" => ["icmp"],
                 "query_label" => "lab-icmp",
                 "source" => "srql",
                 "metadata" => %{"device_uid" => "sr:dev-0001"}
               },
               %{
                 "network" => "198.51.100.11",
                 "sweep_modes" => ["icmp"],
                 "query_label" => "lab-icmp",
                 "source" => "srql",
                 "metadata" => %{"device_uid" => "sr:dev-0002"}
               },
               %{
                 "network" => "198.51.100.12",
                 "sweep_modes" => ["icmp"],
                 "query_label" => "lab-icmp",
                 "source" => "srql",
                 "metadata" => %{"device_uid" => "sr:dev-0003"}
               }
             ]

      lab_tcp = Map.fetch!(compiled, @lab_tcp_id)
      assert lab_tcp["modes"] == ["icmp", "tcp"]
      assert lab_tcp["ports"] == [80, 443]

      assert lab_tcp["device_targets"] ==
               Enum.map(
                 [
                   {"198.51.100.10", "sr:dev-0001"},
                   {"198.51.100.11", "sr:dev-0002"},
                   {"198.51.100.12", "sr:dev-0003"}
                 ],
                 fn {network, uid} ->
                   %{
                     "network" => network,
                     "sweep_modes" => ["icmp", "tcp"],
                     "query_label" => "lab-icmp-tcp",
                     "source" => "srql",
                     "metadata" => %{"device_uid" => uid}
                   }
                 end
               )

      assert Map.fetch!(compiled, @edge_id)["device_targets"] == [
               %{
                 "network" => "203.0.113.5",
                 "sweep_modes" => ["tcp"],
                 "query_label" => "edge-tcp",
                 "source" => "srql",
                 "metadata" => %{"device_uid" => "sr:dev-0010"}
               }
             ]
    end

    test "a row without a device uid compiles with empty metadata" do
      query_page_fn = fn _query, _opts ->
        {:ok, %{rows: [%{"ip" => "198.51.100.30"}], next_cursor: nil}}
      end

      [compiled] =
        SweepCompiler.compile_groups(
          [group(%{id: "sg-no-uid", name: "no-uid", target_query: @lab_query})],
          %{},
          query_page_fn: query_page_fn
        )

      assert [%{"network" => "198.51.100.30", "metadata" => %{}}] = compiled["device_targets"]
    end

    test "groups are emitted sorted by id whatever order they are loaded in" do
      groups = pinned_groups()

      compiled = SweepCompiler.compile_groups(groups, %{}, query_page_fn: fake_inventory(self()))

      reversed =
        SweepCompiler.compile_groups(Enum.reverse(groups), %{},
          query_page_fn: fake_inventory(self())
        )

      assert Enum.map(compiled, & &1["id"]) ==
               Enum.sort([@static_id, @lab_icmp_id, @lab_tcp_id, @edge_id])

      assert compiled == reversed
    end

    test "config_hash ignores group order but not content" do
      groups =
        SweepCompiler.compile_groups(pinned_groups(), %{}, query_page_fn: fake_inventory(self()))

      assert SweepCompiler.config_hash(groups) == SweepCompiler.config_hash(Enum.reverse(groups))

      changed = List.update_at(groups, 0, &Map.put(&1, "ports", [8443]))
      refute SweepCompiler.config_hash(changed) == SweepCompiler.config_hash(groups)
    end
  end

  describe "target query evaluation" do
    test "a query shared by several groups runs once per compile" do
      SweepCompiler.compile_groups(pinned_groups(), %{}, query_page_fn: fake_inventory(self()))

      assert Enum.sort(query_executions()) == [@edge_query, @lab_query]
    end

    test "queries equal after normalization share one evaluation; other text does not" do
      groups = [
        group(%{id: "sg-a", name: "a", target_query: "  in:devices tags.env:lab  "}),
        group(%{id: "sg-b", name: "b", target_query: @lab_query}),
        group(%{id: "sg-c", name: "c", target_query: "tags.env:lab"}),
        group(%{id: "sg-d", name: "d", target_query: "in:devices  tags.env:lab"})
      ]

      compiled = compile_by_id(groups, query_page_fn: fake_inventory(self()))

      assert Enum.sort(query_executions()) == Enum.sort([@lab_query, "in:devices  tags.env:lab"])
      assert networks(compiled["sg-a"]) == networks(compiled["sg-b"])
      assert networks(compiled["sg-c"]) == networks(compiled["sg-b"])
      assert networks(compiled["sg-d"]) == ["198.51.100.200"]
    end

    test "query results are shared across compiles until the sweep config is invalidated" do
      query_page_fn = fake_inventory(self())
      groups = pinned_groups()

      first = SweepCompiler.compile_groups(groups, %{}, query_page_fn: query_page_fn)
      assert Enum.sort(query_executions()) == [@edge_query, @lab_query]

      second = SweepCompiler.compile_groups(groups, %{}, query_page_fn: query_page_fn)
      assert query_executions() == []
      assert second == first

      ConfigCache.invalidate(:sweep)

      SweepCompiler.compile_groups(groups, %{}, query_page_fn: query_page_fn)
      assert Enum.sort(query_executions()) == [@edge_query, @lab_query]
    end

    test "shared query results expire after the configured TTL" do
      previous = Application.fetch_env(:serviceradar_core, :sweep_query_cache_ttl_ms)
      Application.put_env(:serviceradar_core, :sweep_query_cache_ttl_ms, 50)

      on_exit(fn ->
        case previous do
          {:ok, value} ->
            Application.put_env(:serviceradar_core, :sweep_query_cache_ttl_ms, value)

          :error ->
            Application.delete_env(:serviceradar_core, :sweep_query_cache_ttl_ms)
        end
      end)

      query_page_fn = fake_inventory(self())
      lab = group(%{id: "sg-expiring", name: "expiring", target_query: @lab_query})

      SweepCompiler.compile_groups([lab], %{}, query_page_fn: query_page_fn)
      SweepCompiler.compile_groups([lab], %{}, query_page_fn: query_page_fn)
      assert query_executions() == [@lab_query]

      Process.sleep(200)

      SweepCompiler.compile_groups([lab], %{}, query_page_fn: query_page_fn)
      assert query_executions() == [@lab_query]
    end

    test "changing a group's query takes effect on the next compile" do
      query_page_fn = fake_inventory(self())
      lab = group(%{id: "sg-moving", name: "moving", target_query: @lab_query})

      [before] = SweepCompiler.compile_groups([lab], %{}, query_page_fn: query_page_fn)
      assert networks(before) == ["198.51.100.10", "198.51.100.11", "198.51.100.12"]
      assert query_executions() == [@lab_query]

      [after_edit] =
        SweepCompiler.compile_groups([%{lab | target_query: "tags.env:edge"}], %{},
          query_page_fn: query_page_fn
        )

      assert query_executions() == [@edge_query]
      assert networks(after_edit) == ["203.0.113.5"]
    end
  end

  describe "failing target queries" do
    test "an erroring query leaves only its groups without device targets and is retried later" do
      query_page_fn = failing_for(@lab_query, fn _opts -> {:error, :srql_unavailable} end, self())

      log =
        capture_log(fn ->
          compiled = compile_by_id(pinned_groups(), query_page_fn: query_page_fn)

          refute Map.has_key?(compiled[@lab_icmp_id], "device_targets")
          refute Map.has_key?(compiled[@lab_tcp_id], "device_targets")
          assert networks(compiled[@edge_id]) == ["203.0.113.5"]
        end)

      assert log =~ "SRQL query failed for group #{inspect(@lab_icmp_id)}"
      assert log =~ "SRQL query failed for group #{inspect(@lab_tcp_id)}"
      assert Enum.sort(query_executions()) == [@edge_query, @lab_query]

      capture_log(fn ->
        SweepCompiler.compile_groups(pinned_groups(), %{}, query_page_fn: query_page_fn)
      end)

      assert query_executions() == [@lab_query]
    end

    test "a query that fails on a later page keeps the rows already read, uncached" do
      inventory = fake_inventory(self())

      query_page_fn = fn query, opts ->
        if query == @lab_query and Keyword.get(opts, :cursor) == "page-2" do
          {:error, :timeout}
        else
          inventory.(query, opts)
        end
      end

      lab = group(%{id: "sg-partial", name: "partial", target_query: @lab_query})

      log =
        capture_log(fn ->
          [compiled] = SweepCompiler.compile_groups([lab], %{}, query_page_fn: query_page_fn)
          assert networks(compiled) == ["198.51.100.10", "198.51.100.11"]
        end)

      assert log =~ "SRQL query failed for group \"sg-partial\""
      assert query_executions() == [@lab_query]

      capture_log(fn ->
        SweepCompiler.compile_groups([lab], %{}, query_page_fn: query_page_fn)
      end)

      assert query_executions() == [@lab_query]
    end

    test "a raising query is logged per group and does not fail the compile" do
      query_page_fn =
        failing_for(@lab_query, fn _opts -> raise "driver encoding failure" end, self())

      log =
        capture_log(fn ->
          compiled = compile_by_id(pinned_groups(), query_page_fn: query_page_fn)

          refute Map.has_key?(compiled[@lab_icmp_id], "device_targets")
          refute Map.has_key?(compiled[@lab_tcp_id], "device_targets")
          assert networks(compiled[@edge_id]) == ["203.0.113.5"]
        end)

      for group_id <- [@lab_icmp_id, @lab_tcp_id] do
        assert log =~
                 "SRQL target query raised for group #{inspect(group_id)} " <>
                   "(#{inspect(@lab_query)}): driver encoding failure"
      end

      assert Enum.sort(query_executions()) == [@edge_query, @lab_query]
    end
  end
end
