defmodule ServiceRadarWebNG.Dashboards.SystemReportsDbTest do
  use ServiceRadarWebNG.DataCase, async: false

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Dashboards.AuthoredDashboard
  alias ServiceRadar.Dashboards.DashboardPanel
  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.Dashboards.SystemReports
  alias ServiceRadarWebNG.SRQL

  require Ash.Query

  # TEST-NET-1. Two hops at one address sent 100 and 1 probes, so a mean of
  # per-hop loss percentages is 50 while the ratio of sums is 100/101.
  @analytics_target "192.0.2.203"
  @shared_hop "192.0.2.185"
  @silent_hop "192.0.2.186"
  @ratio_of_sums 100 / 101
  @mean_of_ratios 50.0

  @moduletag :web_ng_shared_fixture_db
  @moduletag sandbox: :unboxed

  setup do
    marker = "sr-import-#{System.unique_integer([:positive])}"
    on_exit(fn -> cleanup!(marker) end)
    actor = SystemActor.system(:system_reports_db_test)
    %{actor: actor, marker: marker}
  end

  @tag :web_ng_shared_fixture_db
  test "creates both built-in dashboards when absent", %{actor: actor} do
    assert {:ok, dashboards} = SystemReports.seed_all(actor: actor)

    slugs = Enum.map(dashboards, & &1.slug)
    assert SystemReports.new_devices_slug() in slugs
    assert SystemReports.mtr_path_analytics_slug() in slugs

    for spec <- SystemReports.dashboard_specs() do
      dashboard = Enum.find(dashboards, &(&1.slug == spec.slug))
      assert dashboard, "seed_all must return a dashboard for slug #{spec.slug}"

      {:ok, loaded} =
        AuthoredDashboard
        |> Ash.Query.for_read(:by_slug, %{slug: spec.slug})
        |> Ash.Query.load([:panels])
        |> Ash.read_one(actor: actor)

      assert loaded, "slug #{spec.slug} must exist in the database after seed_all"

      assert length(loaded.panels) == length(spec.panels),
             "#{spec.slug} must have #{length(spec.panels)} panel(s), got #{length(loaded.panels)}"

      assert MapSet.new(loaded.panels, & &1.title) == MapSet.new(spec.panels, & &1.title),
             "#{spec.slug} must render every shipped panel title"
    end
  end

  @tag :web_ng_shared_fixture_db
  test "does not overwrite an existing dashboard on reseed", %{actor: actor, marker: marker} do
    assert {:ok, _} = SystemReports.seed_all(actor: actor)

    mtr_slug = SystemReports.mtr_path_analytics_slug()

    {:ok, mtr} =
      AuthoredDashboard
      |> Ash.Query.for_read(:by_slug, %{slug: mtr_slug})
      |> Ash.Query.load([:panels])
      |> Ash.read_one(actor: actor)

    assert [panel | _] = mtr.panels, "precondition: mtr dashboard must have at least one panel"
    edited_query = "in:mtr_hops addr:#{marker} limit:5"

    Repo.update_all(
      from(p in "authored_dashboard_panels",
        prefix: "platform",
        where: p.id == type(^panel.id, Ecto.UUID)
      ),
      set: [srql_query: edited_query]
    )

    assert {:ok, _} = SystemReports.seed_all(actor: actor)

    {:ok, after_reseed} =
      AuthoredDashboard
      |> Ash.Query.for_read(:by_slug, %{slug: mtr_slug})
      |> Ash.Query.load([:panels])
      |> Ash.read_one(actor: actor)

    saved = Enum.find(after_reseed.panels, &(&1.id == panel.id))
    assert saved, "reseed deleted the panel entirely"

    assert saved.srql_query == edited_query,
           "reseed must not overwrite an operator-edited panel query"
  end

  @tag :web_ng_shared_fixture_db
  test "does not remove an operator-added panel on reseed", %{actor: actor} do
    assert {:ok, _} = SystemReports.seed_all(actor: actor)

    mtr_slug = SystemReports.mtr_path_analytics_slug()

    {:ok, mtr} =
      AuthoredDashboard
      |> Ash.Query.for_read(:by_slug, %{slug: mtr_slug})
      |> Ash.Query.load([:panels])
      |> Ash.read_one(actor: actor)

    {:ok, added} =
      DashboardPanel
      |> Ash.Changeset.for_create(:create, %{
        dashboard_id: mtr.id,
        title: "Operator panel",
        srql_query: "in:mtr_hops limit:1",
        visual_type: :table,
        data_binding: %{},
        layout: %{"x" => 0, "y" => 20, "w" => 12, "h" => 4},
        position: 99
      })
      |> Ash.create(actor: actor)

    assert {:ok, _} = SystemReports.seed_all(actor: actor)

    {:ok, after_reseed} =
      AuthoredDashboard
      |> Ash.Query.for_read(:by_slug, %{slug: mtr_slug})
      |> Ash.Query.load([:panels])
      |> Ash.read_one(actor: actor)

    panel_ids = Enum.map(after_reseed.panels, & &1.id)
    assert added.id in panel_ids, "reseed must not remove a panel the operator added"
  end

  @tag :web_ng_shared_fixture_db
  test "completes a dashboard that exists with no panels", %{actor: actor} do
    new_devices_slug = SystemReports.new_devices_slug()

    {:ok, empty_dashboard} =
      AuthoredDashboard
      |> Ash.Changeset.for_create(:create, %{
        dashboard_ref: synthetic_dashboard_ref(),
        title: "New devices",
        slug: new_devices_slug,
        visibility: :public,
        status: :active
      })
      |> Ash.create(actor: actor)

    {:ok, loaded_empty} =
      AuthoredDashboard
      |> Ash.Query.for_read(:by_slug, %{slug: new_devices_slug})
      |> Ash.Query.load([:panels])
      |> Ash.read_one(actor: actor)

    assert loaded_empty.panels == [], "precondition: dashboard exists with no panels"

    assert {:ok, _} = SystemReports.seed_all(actor: actor)

    {:ok, after_seed} =
      AuthoredDashboard
      |> Ash.Query.for_read(:by_slug, %{slug: new_devices_slug})
      |> Ash.Query.load([:panels])
      |> Ash.read_one(actor: actor)

    expected_spec = Enum.find(SystemReports.dashboard_specs(), &(&1.slug == new_devices_slug))

    assert length(after_seed.panels) == length(expected_spec.panels),
           "seed_all must complete a dashboard that exists with no panels"

    assert after_seed.id == empty_dashboard.id, "same dashboard record, not a duplicate"
  end

  @tag :web_ng_shared_fixture_db
  test "leaves an unrelated dashboard untouched after seed_all", %{actor: actor, marker: marker} do
    {:ok, unrelated} =
      AuthoredDashboard
      |> Ash.Changeset.for_create(:create, %{
        dashboard_ref: synthetic_dashboard_ref(),
        title: "#{marker}-unrelated",
        slug: "#{marker}-unrelated-slug",
        visibility: :private,
        status: :active
      })
      |> Ash.create(actor: actor)

    assert {:ok, _} = SystemReports.seed_all(actor: actor)

    {:ok, after_seed} =
      AuthoredDashboard
      |> Ash.Query.for_read(:by_slug, %{slug: "#{marker}-unrelated-slug"})
      |> Ash.Query.load([:panels])
      |> Ash.read_one(actor: actor)

    assert after_seed, "unrelated dashboard must still exist after seed_all"
    assert after_seed.id == unrelated.id
    assert after_seed.title == "#{marker}-unrelated"
    assert after_seed.panels == [], "unrelated dashboard must have no panels added to it"
  end

  @tag :web_ng_shared_fixture_db
  test "records first-party provenance on the reports it creates at startup", %{
    actor: actor,
    marker: marker
  } do
    # Start from absent so this asserts what creation writes, not what a row
    # carried over from an earlier seed happens to hold.
    cleanup!(marker)

    assert {:ok, _} = SystemReports.seed_all(actor: actor)

    for spec <- SystemReports.dashboard_specs(), spec.enabled_by_default do
      {:ok, loaded} =
        AuthoredDashboard
        |> Ash.Query.for_read(:by_slug, %{slug: spec.slug})
        |> Ash.read_one(actor: actor)

      assert loaded.source_type == :first_party
      assert loaded.source_path == "elixir/web-ng/priv/dashboards/#{spec.source_path}"
      assert loaded.content_hash == spec.content_hash
      assert loaded.source_repo_url == "https://github.com/carverauto/serviceradar"
    end
  end

  @tag :web_ng_shared_fixture_db
  test "concurrent startup seeding creates each dashboard once and every seeder succeeds", %{
    actor: actor,
    marker: marker
  } do
    # Each web-ng replica seeds at startup. The ones that lose the race for a slug
    # must keep the winner's dashboard, not fail, and must not add panels to it.
    cleanup!(marker)

    results =
      1..3
      |> Enum.map(fn _ -> Task.async(fn -> SystemReports.seed_all(actor: actor) end) end)
      |> Task.await_many(60_000)

    for result <- results do
      assert {:ok, dashboards} = result

      assert length(dashboards) ==
               length(Enum.filter(SystemReports.dashboard_specs(), & &1.enabled_by_default))
    end

    for spec <- SystemReports.dashboard_specs(), spec.enabled_by_default do
      assert [dashboard] =
               AuthoredDashboard
               |> Ash.Query.filter(slug == ^spec.slug)
               |> Ash.Query.load([:panels])
               |> Ash.read!(actor: actor)

      assert length(dashboard.panels) == length(spec.panels)
    end
  end

  @tag :web_ng_shared_fixture_db
  test "mtr path analytics panel queries aggregate synthetic hops" do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    delete_analytics_rows!()
    on_exit(fn -> delete_analytics_rows!() end)

    reached = Ecto.UUID.generate()
    missed = Ecto.UUID.generate()

    insert_trace!(reached, now, true, 1)
    insert_trace!(missed, now, false, 2)

    insert_hop!(reached, now, 1, @shared_hop, 100, 100, 0.0, 1_000)
    insert_hop!(missed, now, 1, @shared_hop, 1, 0, 100.0, 9_000)
    insert_hop!(missed, now, 2, @silent_hop, 0, 0, 0.0, 100)

    panels =
      SystemReports.dashboard_specs()
      |> Enum.find(&(&1.slug == SystemReports.mtr_path_analytics_slug()))
      |> Map.fetch!(:panels)
      |> Map.new(&{&1.title, with_target(&1.srql_query)})

    by_position = rows!(panels["Loss by hop position (does it persist?)"])
    assert_ratio(field(find_row!(by_position, "hop_number", 1), "loss"))
    assert field(find_row!(by_position, "hop_number", 2), "loss") == nil

    by_addr = rows!(panels["Shared hops by loss (with trace count)"])
    assert_ratio(field(find_row!(by_addr, "addr", @shared_hop), "loss"))
    assert field(find_row!(by_addr, "addr", @silent_hop), "loss") == nil

    [reach] = rows!(panels["Reach rate per target (endpoint health)"])
    assert field(reach, "target_ip") == @analytics_target
    assert number(field(reach, "traces")) == 2
    assert_close(field(reach, "reach_rate"), 0.5)

    by_latency = rows!(panels["Hop latency, weighted by samples"])
    assert_close(field(find_row!(by_latency, "addr", @shared_hop), "latency"), 1_000.0)
    assert field(find_row!(by_latency, "addr", @silent_hop), "latency") == nil

    [trend] = rows!(panels["Loss trend"])
    assert_ratio(field(trend, "loss"))
  end

  # The shipped panel text has no device filter. Scope it the way an operator
  # does, by placing target_ip immediately after the entity token, so rows from
  # other tests cannot enter the aggregate.
  defp with_target(query) do
    case String.split(query, " ", parts: 2) do
      [entity, rest] -> "#{entity} target_ip:#{@analytics_target} #{rest}"
      [entity] -> "#{entity} target_ip:#{@analytics_target}"
    end
  end

  # mode nil is the CNPG compiler. SRQL.query/2 would follow the warehouse
  # switch and miss these inserts when StarRocks is enabled. The StarRocks
  # formula is the same CASE, asserted as SQL text in the srql crate.
  defp rows!(query) do
    {:ok, json} = SRQL.Native.translate(query, nil, nil, nil, nil)
    {:ok, %{"sql" => sql, "params" => params}} = Jason.decode(json)

    decoded =
      Enum.map(params, fn param ->
        {:ok, value} = SRQL.decode_param(param)
        value
      end)

    %{columns: columns, rows: rows} = Repo.query!(sql, decoded)

    Enum.map(rows, fn row ->
      columns
      |> Enum.zip(row)
      |> Map.new(fn {column, value} -> {String.downcase(to_string(column)), value} end)
      |> row_fields()
    end)
  end

  defp row_fields(%{"payload" => payload}) when is_map(payload), do: string_keys(payload)

  defp row_fields(%{"payload" => payload}) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, decoded} when is_map(decoded) -> string_keys(decoded)
      _ -> %{"payload" => payload}
    end
  end

  defp row_fields(row), do: row

  defp string_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp find_row!(rows, key, expected) do
    Enum.find(rows, fn row -> same_value?(field(row, key), expected) end) ||
      flunk("no #{key}=#{inspect(expected)} row in #{inspect(rows)}")
  end

  defp field(row, key), do: Map.get(row, key)

  defp same_value?(left, right) do
    cond do
      left == right -> true
      numeric?(left) and numeric?(right) -> number(left) == number(right)
      to_string(left) == to_string(right) -> true
      true -> false
    end
  end

  defp numeric?(%Decimal{}), do: true
  defp numeric?(value) when is_number(value), do: true
  defp numeric?(_value), do: false

  defp number(%Decimal{} = value), do: Decimal.to_float(value)
  defp number(value) when is_integer(value), do: value * 1.0
  defp number(value) when is_float(value), do: value

  defp number(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> parsed
      _ -> flunk("expected a number, got #{inspect(value)}")
    end
  end

  defp number(value), do: flunk("expected a number, got #{inspect(value)}")

  defp assert_ratio(value) do
    actual = number(value)
    assert_in_delta actual, @ratio_of_sums, 0.001
    refute_in_delta actual, @mean_of_ratios, 1.0
  end

  defp assert_close(value, expected) do
    assert_in_delta number(value), expected * 1.0, 0.001
  end

  defp insert_trace!(id, timestamp, target_reached, total_hops) do
    Repo.insert_all(
      "mtr_traces",
      [
        %{
          id: dump_uuid!(id),
          time: timestamp,
          agent_id: "agent-mtr-analytics",
          gateway_id: "gateway-test",
          check_id: "check-#{id}",
          check_name: "MTR #{@analytics_target}",
          device_id: nil,
          target: @analytics_target,
          target_ip: @analytics_target,
          target_reached: target_reached,
          total_hops: total_hops,
          last_responding_hop: nil,
          protocol: "icmp",
          ip_version: 4,
          packet_size: 64,
          partition: "default",
          error: nil,
          created_at: timestamp
        }
      ],
      prefix: "platform"
    )
  end

  defp insert_hop!(trace_id, timestamp, hop_number, addr, sent, received, loss_pct, avg_us) do
    Repo.insert_all(
      "mtr_hops",
      [
        %{
          id: dump_uuid!(Ecto.UUID.generate()),
          time: timestamp,
          trace_id: dump_uuid!(trace_id),
          hop_number: hop_number,
          addr: addr,
          hostname: nil,
          ecmp_addrs: [],
          asn: nil,
          asn_org: nil,
          mpls_labels: %{},
          sent: sent,
          received: received,
          loss_pct: loss_pct,
          last_us: avg_us,
          avg_us: avg_us,
          min_us: avg_us,
          max_us: avg_us,
          stddev_us: 0,
          jitter_us: 0,
          jitter_worst_us: 0,
          jitter_interarrival_us: 0,
          target_ip: @analytics_target,
          device_id: nil,
          created_at: timestamp
        }
      ],
      prefix: "platform"
    )
  end

  defp delete_analytics_rows! do
    Repo.delete_all(
      from(h in "mtr_hops", prefix: "platform", where: h.target_ip == ^@analytics_target)
    )

    Repo.delete_all(
      from(t in "mtr_traces", prefix: "platform", where: t.target_ip == ^@analytics_target)
    )
  end

  defp dump_uuid!(uuid) do
    case Ecto.UUID.dump(uuid) do
      {:ok, dumped} -> dumped
      :error -> flunk("invalid fixture uuid #{inspect(uuid)}")
    end
  end

  defp synthetic_dashboard_ref do
    1_000_000 + :erlang.phash2(Ecto.UUID.generate(), 9_000_000)
  end

  defp cleanup!(marker) do
    slug_pattern = "#{marker}-%"

    Repo.delete_all(
      from(d in "authored_dashboards",
        prefix: "platform",
        where: like(d.slug, ^slug_pattern)
      )
    )

    builtin_slugs = [SystemReports.new_devices_slug(), SystemReports.mtr_path_analytics_slug()]

    Repo.delete_all(
      from(d in "authored_dashboards",
        prefix: "platform",
        where: d.slug in ^builtin_slugs
      )
    )
  end
end
