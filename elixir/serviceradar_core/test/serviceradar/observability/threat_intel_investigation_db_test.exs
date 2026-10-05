defmodule ServiceRadar.Observability.ThreatIntelInvestigationDBTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.IpThreatIntelCache
  alias ServiceRadar.Observability.ThreatIntelIndicator
  alias ServiceRadar.Observability.ThreatIntelInvestigation

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

    assert {:ok, current} = ThreatIntelInvestigation.list_current_matches(scope, source: source)
    assert current == []

    assert {:ok, [stale]} =
             ThreatIntelInvestigation.list_current_matches(scope, source: source, stale: true)

    assert stale.observed_ip == ip
    assert stale.stale
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
