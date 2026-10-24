defmodule ServiceRadar.Observability.ThreatIntelInvestigationDBTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.IpThreatIntelCache
  alias ServiceRadar.Observability.ThreatIntelEvidence
  alias ServiceRadar.Observability.ThreatIntelIndicator
  alias ServiceRadar.Observability.ThreatIntelInvestigation
  alias ServiceRadar.Observability.ThreatIntelInvestigation.Telemetry, as: ThreatIntelTelemetry
  alias ServiceRadar.Observability.ThreatIntelSourceObject

  setup do
    %{actor: SystemActor.system(:threat_intel_investigation_db_test)}
  end

  test "reads the indicator that contains an address", %{actor: actor} do
    source = unique_source("contain")
    {ip, cidr} = unique_host()
    other_ip = "203.0.113.10"
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    insert_indicator!(actor, %{
      indicator: cidr,
      source: source,
      label: "Synthetic pulse #{source}",
      severity: 100,
      expires_at: DateTime.shift(now, hour: 1),
      first_seen_at: now,
      last_seen_at: now
    })

    insert_indicator!(actor, %{
      indicator: "#{other_ip}/32",
      source: source <> "-expired",
      label: "Expired pulse #{source}",
      severity: 100,
      expires_at: DateTime.shift(now, hour: -1),
      first_seen_at: now,
      last_seen_at: now
    })

    assert {:ok, rows} = ThreatIntelInvestigation.indicators_for_ip(%{actor: actor}, ip)
    assert Enum.any?(rows, &(&1.source == source and &1.label == "Synthetic pulse #{source}"))

    assert {:ok, other_rows} =
             ThreatIntelInvestigation.indicators_for_ip(%{actor: actor}, other_ip)

    refute Enum.any?(other_rows, &(&1.source == source <> "-expired"))
    refute Enum.any?(other_rows, &(&1.source == source))
  end

  test "default matches omit an expired cache row and the stale view labels it", %{actor: actor} do
    source = unique_source("stale")
    {ip, _cidr} = unique_host()
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    scope = %{actor: actor}

    insert_cache!(actor, %{
      ip: ip,
      matched: true,
      match_count: 1,
      max_severity: 4,
      sources: [source],
      looked_up_at: now,
      expires_at: DateTime.shift(now, minute: -1)
    })

    assert {:ok, %{rows: []}} =
             ThreatIntelInvestigation.list_current_matches(scope, source: source)

    assert {:ok, %{rows: [stale]}} =
             ThreatIntelInvestigation.list_current_matches(scope, source: source, stale: true)

    assert stale.observed_ip == ip
    assert stale.stale
  end

  test "endpoint summaries return live matched endpoints only", %{actor: actor} do
    source = unique_source("summary")
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    scope = %{actor: actor}
    {live_ip, _} = unique_host()
    expired_ip = "198.51.100.#{rem(System.unique_integer([:positive]), 200) + 20}"
    unmatched_ip = "203.0.113.#{rem(System.unique_integer([:positive]), 200) + 20}"

    for {ip, matched, expires_at} <- [
          {live_ip, true, DateTime.shift(now, hour: 1)},
          {expired_ip, true, DateTime.shift(now, minute: -1)},
          {unmatched_ip, false, DateTime.shift(now, hour: 1)}
        ] do
      insert_cache!(actor, %{
        ip: ip,
        matched: matched,
        match_count: if(matched, do: 2, else: 0),
        max_severity: 5,
        sources: [source],
        looked_up_at: now,
        expires_at: expires_at
      })
    end

    assert {:ok, summaries} =
             ThreatIntelInvestigation.endpoint_summaries(scope, [
               live_ip,
               expired_ip,
               unmatched_ip,
               live_ip,
               "not-an-ip"
             ])

    assert Map.keys(summaries) == [live_ip]
    assert %{match_count: 2, max_severity: 5, sources: [^source]} = summaries[live_ip]
  end

  test "current matches page by keyset without duplicating or skipping rows", %{actor: actor} do
    source = unique_source("page")
    scope = %{actor: actor}
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    # Two rows share an evaluation time, so the IP tie-breaker decides the order.
    rows = [
      {"192.0.2.250", now, 9},
      {"192.0.2.251", now, nil},
      {"192.0.2.252", DateTime.shift(now, second: -5), 3}
    ]

    for {ip, at, severity} <- rows do
      insert_cache!(actor, %{
        ip: ip,
        matched: true,
        match_count: 1,
        max_severity: severity,
        sources: [source],
        looked_up_at: at,
        expires_at: DateTime.shift(now, hour: 1)
      })
    end

    assert {:ok, %{rows: first, next_cursor: cursor}} =
             ThreatIntelInvestigation.list_current_matches(scope, source: source, limit: 2)

    assert Enum.map(first, & &1.observed_ip) == ["192.0.2.250", "192.0.2.251"]
    assert is_binary(cursor)

    assert {:ok, %{rows: second, next_cursor: nil}} =
             ThreatIntelInvestigation.list_current_matches(scope,
               source: source,
               limit: 2,
               cursor: cursor
             )

    assert Enum.map(second, & &1.observed_ip) == ["192.0.2.252"]

    # Severity order puts unknown severity last and pages the same way.
    assert {:ok, %{rows: by_severity, next_cursor: severity_cursor}} =
             ThreatIntelInvestigation.list_current_matches(scope,
               source: source,
               sort: "severity",
               limit: 2
             )

    assert Enum.map(by_severity, & &1.observed_ip) == ["192.0.2.250", "192.0.2.252"]

    assert {:ok, %{rows: [%{observed_ip: "192.0.2.251"}]}} =
             ThreatIntelInvestigation.list_current_matches(scope,
               source: source,
               sort: "severity",
               limit: 2,
               cursor: severity_cursor
             )

    assert {:ok, %{rows: [%{observed_ip: "192.0.2.250"}]}} =
             ThreatIntelInvestigation.list_current_matches(scope,
               source: source,
               min_severity: "5"
             )

    assert {:error, :invalid_cursor} =
             ThreatIntelInvestigation.list_current_matches(scope,
               source: source,
               cursor: "not-a-cursor"
             )
  end

  test "indicator detail carries provider context only when one object matches", %{actor: actor} do
    source = unique_source("context")
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    {ip, cidr} = unique_host()
    other_ip = "203.0.113.#{rem(System.unique_integer([:positive]), 200) + 20}"

    for indicator <- [cidr, "#{other_ip}/32"] do
      insert_indicator!(actor, %{
        indicator: indicator,
        source: source,
        label: "Synthetic #{indicator}",
        severity: 50,
        expires_at: DateTime.shift(now, hour: 1),
        first_seen_at: now,
        last_seen_at: now
      })
    end

    insert_source_object!(actor, source, "pulse-a", ip)
    insert_source_object!(actor, source, "pulse-b", other_ip)
    insert_source_object!(actor, source, "pulse-c", other_ip)

    scope = %{actor: actor}

    assert {:ok, rows} = ThreatIntelInvestigation.indicators_for_ip(scope, ip)
    assert [unique] = Enum.filter(rows, &(&1.source == source))

    assert %{source_object_id: "pulse-a", source_label: "Synthetic pulse pulse-a"} =
             unique.source_context

    assert {:ok, other_rows} = ThreatIntelInvestigation.indicators_for_ip(scope, other_ip)
    assert [ambiguous] = Enum.filter(other_rows, &(&1.source == source))
    assert is_nil(ambiguous.source_context)
  end

  test "versions of one provider object count as one object for indicator context",
       %{actor: actor} do
    source = unique_source("object-versions")
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    {ip, cidr} = unique_host()

    insert_indicator!(actor, %{
      indicator: cidr,
      source: source,
      label: "Synthetic #{cidr}",
      severity: 50,
      expires_at: DateTime.shift(now, hour: 1),
      first_seen_at: now,
      last_seen_at: now
    })

    insert_source_object!(actor, source, "pulse-versioned", ip, %{
      object_version: "v1",
      modified_at: DateTime.shift(now, day: -1),
      label: "Older pulse title"
    })

    insert_source_object!(actor, source, "pulse-versioned", ip, %{
      object_version: "v2",
      modified_at: now,
      label: "Current pulse title"
    })

    assert {:ok, rows} = ThreatIntelInvestigation.indicators_for_ip(%{actor: actor}, ip)
    assert [row] = Enum.filter(rows, &(&1.source == source))

    assert %{source_object_id: "pulse-versioned", source_label: "Current pulse title"} =
             row.source_context
  end

  test "a network indicator keeps its own provider object beside a pulse for its base address",
       %{actor: actor} do
    source = unique_source("network-context")
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    scope = %{actor: actor}

    for indicator <- ["198.51.100.0/24", "198.51.100.0/32"] do
      insert_indicator!(actor, %{
        indicator: indicator,
        source: source,
        label: "Synthetic #{indicator}",
        severity: 50,
        expires_at: DateTime.shift(now, hour: 1),
        first_seen_at: now,
        last_seen_at: now
      })
    end

    insert_source_object!(actor, source, "pulse-network", "198.51.100.0/24")
    insert_source_object!(actor, source, "pulse-base-host", "198.51.100.0")

    assert {:ok, rows} = ThreatIntelInvestigation.indicators_for_ip(scope, "198.51.100.50")
    assert [network] = Enum.filter(rows, &(&1.source == source))
    assert %{source_object_id: "pulse-network"} = network.source_context

    assert {:ok, base_rows} = ThreatIntelInvestigation.indicators_for_ip(scope, "198.51.100.0")

    contexts =
      base_rows
      |> Enum.filter(&(&1.source == source))
      |> Map.new(&{&1.indicator, &1.source_context.source_object_id})

    assert contexts == %{
             "198.51.100.0/24" => "pulse-network",
             "198.51.100.0/32" => "pulse-base-host"
           }
  end

  test "evidence pages separate inventory and retrohunt findings", %{actor: actor} do
    source = unique_source("evidence")
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    scope = %{actor: actor}

    for {cidr, offset} <- [
          {"198.51.100.0/25", 0},
          {"198.51.100.128/25", -10},
          {"203.0.113.0/24", -20}
        ] do
      insert_indicator!(actor, %{
        indicator: cidr,
        source: source,
        label: "Inventory #{cidr}",
        severity: 10,
        expires_at: DateTime.shift(now, hour: 1),
        first_seen_at: now,
        last_seen_at: DateTime.shift(now, second: offset)
      })
    end

    assert {:ok, %{rows: [first], next_cursor: cursor}} =
             ThreatIntelEvidence.page_indicators(scope, source: source, limit: 1)

    assert first.indicator =~ "198.51.100.0"

    assert {:ok, %{rows: rest, next_cursor: nil}} =
             ThreatIntelEvidence.page_indicators(scope, source: source, limit: 5, cursor: cursor)

    assert length(rest) == 2

    assert {:ok, %{rows: [contained]}} =
             ThreatIntelEvidence.page_indicators(scope,
               source: source,
               indicator: "198.51.100.200"
             )

    assert contained.indicator =~ "198.51.100.128"

    assert {:error, :invalid_cidr} =
             ThreatIntelEvidence.page_indicators(scope, source: source, indicator: "not-an-ip")

    assert {:ok, %{rows: []}} = ThreatIntelEvidence.page_retrohunt_findings(scope, source: source)
  end

  test "object filter matches a masked host to its bare address but not a network to its base",
       %{actor: actor} do
    source = unique_source("object-filter")
    scope = %{actor: actor}

    insert_source_object!(actor, source, "pulse-host", "198.51.100.10")
    insert_source_object!(actor, source, "pulse-base-host", "198.51.100.0")
    insert_source_object!(actor, source, "pulse-network", "198.51.100.0/24")

    object_ids = fn indicator ->
      assert {:ok, %{rows: rows}} =
               ThreatIntelEvidence.page_source_objects(scope,
                 source: source,
                 indicator: indicator
               )

      rows |> Enum.map(& &1.object_id) |> Enum.sort()
    end

    assert object_ids.("198.51.100.10/32") == ["pulse-host"]
    assert object_ids.("198.51.100.10") == ["pulse-host"]
    assert object_ids.("198.51.100.0/24") == ["pulse-network"]
    assert object_ids.("198.51.100.0/32") == ["pulse-base-host"]
  end

  test "match list and detail cost a fixed number of queries, not one per row", %{actor: actor} do
    source = unique_source("query-count")
    scope = %{actor: actor}
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    {single_ip, single_cidr} = unique_host()
    overlapped_ip = "198.51.100.#{rem(System.unique_integer([:positive]), 200) + 20}"

    # One indicator contains `single_ip`; three nested ones contain `overlapped_ip`.
    for cidr <- [single_cidr, "#{overlapped_ip}/32", "198.51.100.0/24", "198.51.100.0/23"] do
      insert_indicator!(actor, %{
        indicator: cidr,
        source: source,
        label: "Count #{cidr}",
        severity: 1,
        expires_at: DateTime.shift(now, hour: 1),
        first_seen_at: now,
        last_seen_at: now
      })
    end

    for n <- 1..6 do
      insert_cache!(actor, %{
        ip: "203.0.113.#{n}",
        matched: true,
        match_count: 1,
        max_severity: 1,
        sources: [source],
        looked_up_at: DateTime.shift(now, second: -n),
        expires_at: DateTime.shift(now, hour: 1)
      })
    end

    assert count_queries(fn -> ThreatIntelInvestigation.indicators_for_ip(scope, single_ip) end) ==
             count_queries(fn ->
               ThreatIntelInvestigation.indicators_for_ip(scope, overlapped_ip)
             end)

    assert count_queries(fn ->
             ThreatIntelInvestigation.list_current_matches(scope, source: source, limit: 1)
           end) ==
             count_queries(fn ->
               ThreatIntelInvestigation.list_current_matches(scope, source: source, limit: 6)
             end)
  end

  test "investigation reads report entity, filter names and outcome without filter values", %{
    actor: actor
  } do
    handler = "threat-intel-telemetry-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler,
      ThreatIntelTelemetry.event() ++ [:stop],
      # Handlers run in the emitting process; only count this test's own reads.
      fn _event, measurements, metadata, _ ->
        if self() == test_pid, do: send(test_pid, {:investigation_query, measurements, metadata})
      end,
      nil
    )

    try do
      scope = %{actor: actor}

      ThreatIntelInvestigation.list_current_matches(scope,
        source: "telemetry-source",
        ip: "192.0.2.77"
      )

      assert_receive {:investigation_query, %{duration: _}, metadata}

      assert %{entity: :current_matches, filters: [:ip, :source], result: :ok, result_count: 0} =
               metadata

      refute inspect(metadata) =~ "192.0.2.77"
      refute inspect(metadata) =~ "telemetry-source"

      ThreatIntelInvestigation.list_current_matches(scope, ip: "not-an-ip")

      assert_receive {:investigation_query, _measurements,
                      %{result: :error, error: :invalid_input}}
    after
      :telemetry.detach(handler)
    end
  end

  defp count_queries(fun) do
    handler = "threat-intel-query-count-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:service_radar, :repo, :query],
      fn _, _, _, _ -> if self() == test_pid, do: send(test_pid, :repo_query) end,
      nil
    )

    try do
      assert {:ok, _} = fun.()
    after
      :telemetry.detach(handler)
    end

    drain_query_messages(0)
  end

  defp drain_query_messages(count) do
    receive do
      :repo_query -> drain_query_messages(count + 1)
    after
      0 -> count
    end
  end

  defp insert_source_object!(actor, source, object_id, indicator, attrs \\ %{}) do
    {label, attrs} = Map.pop(attrs, :label, "Synthetic pulse #{object_id}")

    ThreatIntelSourceObject
    |> Ash.Changeset.for_create(
      :upsert,
      Map.merge(
        %{
          provider: "alienvault_otx",
          source: source,
          collection_id: "synthetic",
          object_id: object_id,
          object_version: "1",
          object_type: "otx-pulse",
          metadata: %{"label" => label, "indicator" => indicator}
        },
        attrs
      )
    )
    |> Ash.create!(actor: actor)
  end

  defp insert_indicator!(actor, attrs) do
    ThreatIntelIndicator
    |> Ash.Changeset.for_create(:upsert, Map.put_new(attrs, :indicator_type, "cidr"))
    |> Ash.create!(actor: actor)
  end

  defp insert_cache!(actor, attrs) do
    IpThreatIntelCache
    |> Ash.Changeset.for_create(:upsert, attrs)
    |> Ash.create!(actor: actor)
  end

  defp unique_source(kind) do
    "investigation-#{kind}-#{System.unique_integer([:positive])}"
  end

  defp unique_host do
    octet = rem(System.unique_integer([:positive]), 200) + 20
    ip = "192.0.2.#{octet}"
    {ip, "#{ip}/32"}
  end
end
