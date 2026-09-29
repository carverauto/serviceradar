defmodule ServiceRadar.AgentConfig.Compilers.SweepCompilerTargetsTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.AgentConfig.Compilers.SweepCompiler
  alias ServiceRadar.SweepJobs.SweepGroup

  @lab_query "in:devices tags.env:lab"
  @edge_query "in:devices tags.env:edge"

  @static_id "sg-static"
  @lab_icmp_id "sg-lab-icmp"
  @lab_tcp_id "sg-lab-icmp-tcp"
  @edge_id "sg-edge-tcp"

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
      end
    end
  end

  defp compile_by_id(groups, opts) do
    groups
    |> SweepCompiler.compile_groups(%{}, opts)
    |> Map.new(&{&1["id"], &1})
  end

  describe "legacy compiled output" do
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
                 "metadata" => %{
                   "sweep_group_id" => @lab_icmp_id,
                   "target_query" => @lab_query,
                   "device_uid" => "sr:dev-0001",
                   "hostname" => "host01.example.com",
                   "discovery_sources" => "sweep,mapper"
                 }
               },
               %{
                 "network" => "198.51.100.11",
                 "sweep_modes" => ["icmp"],
                 "query_label" => "lab-icmp",
                 "source" => "srql",
                 "metadata" => %{
                   "sweep_group_id" => @lab_icmp_id,
                   "target_query" => @lab_query,
                   "device_uid" => "sr:dev-0002",
                   "hostname" => "host02.example.com"
                 }
               },
               %{
                 "network" => "198.51.100.12",
                 "sweep_modes" => ["icmp"],
                 "query_label" => "lab-icmp",
                 "source" => "srql",
                 "metadata" => %{
                   "sweep_group_id" => @lab_icmp_id,
                   "target_query" => @lab_query,
                   "device_uid" => "sr:dev-0003"
                 }
               }
             ]

      lab_tcp = Map.fetch!(compiled, @lab_tcp_id)
      assert lab_tcp["modes"] == ["icmp", "tcp"]
      assert lab_tcp["ports"] == [80, 443]

      assert Enum.map(lab_tcp["device_targets"], &{&1["network"], &1["metadata"]["device_uid"]}) ==
               [
                 {"198.51.100.10", "sr:dev-0001"},
                 {"198.51.100.11", "sr:dev-0002"},
                 {"198.51.100.12", "sr:dev-0003"}
               ]

      assert Enum.all?(lab_tcp["device_targets"], fn target ->
               target["sweep_modes"] == ["icmp", "tcp"] and
                 target["query_label"] == "lab-icmp-tcp" and
                 target["metadata"]["sweep_group_id"] == @lab_tcp_id
             end)

      assert Map.fetch!(compiled, @edge_id)["device_targets"] == [
               %{
                 "network" => "203.0.113.5",
                 "sweep_modes" => ["tcp"],
                 "query_label" => "edge-tcp",
                 "source" => "srql",
                 "metadata" => %{
                   "sweep_group_id" => @edge_id,
                   "target_query" => "tags.env:edge",
                   "device_uid" => "sr:dev-0010",
                   "hostname" => "host10.example.com",
                   "discovery_sources" => "netbox"
                 }
               }
             ]
    end

    test "config_hash ignores group order but not content" do
      groups =
        SweepCompiler.compile_groups(pinned_groups(), %{}, query_page_fn: fake_inventory(self()))

      assert SweepCompiler.config_hash(groups) == SweepCompiler.config_hash(Enum.reverse(groups))

      changed = List.update_at(groups, 0, &Map.put(&1, "ports", [8443]))
      refute SweepCompiler.config_hash(changed) == SweepCompiler.config_hash(groups)
    end
  end
end
