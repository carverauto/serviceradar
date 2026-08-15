defmodule ServiceRadar.PrefixTags.ExternalSourcesIntegrationTest do
  @moduledoc """
  DB-backed coverage for the external prefix-tag source SQL contracts.

  Run against a migrated scratch database with `--include integration`.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.PrefixTags.DnsPolicySource
  alias ServiceRadar.PrefixTags.ProviderSource
  alias ServiceRadar.PrefixTags.Store
  alias ServiceRadar.PrefixTags.ThreatIntelSource
  alias ServiceRadar.Repo

  @moduletag :integration
  @moduletag timeout: 120_000

  setup do
    Store.clear()
    on_exit(&Store.clear/0)
    :ok
  end

  test "external reload queries match the migrated schema and return durable freshness" do
    {:ok, %{rows: [[provider_snapshot_id]]}} =
      Repo.query("""
      INSERT INTO platform.netflow_provider_dataset_snapshots
        (id, source_url, fetched_at, promoted_at, is_active, record_count)
      VALUES
        (gen_random_uuid(), 'https://fixture.invalid/providers.json',
         now() - interval '2 days', now() - interval '1 day', TRUE, 0)
      RETURNING id
      """)

    assert {:ok, %{row_count: 0, snapshot_at: %DateTime{}}} =
             ProviderSource.reload(broadcast?: false)

    assert Store.loaded?("provider")
    assert "provider" in Store.sources()

    Repo.query!(
      """
      INSERT INTO platform.netflow_provider_cidrs
        (snapshot_id, cidr, provider, service, region, ip_version)
      VALUES ($1, '203.0.113.0/24'::cidr, 'fixture-cloud', 'edge', 'test', 'ipv4')
      """,
      [provider_snapshot_id]
    )

    Repo.query!(
      "UPDATE platform.netflow_provider_dataset_snapshots SET record_count = 1 WHERE id = $1",
      [provider_snapshot_id]
    )

    assert {:ok, %{row_count: 1, snapshot_at: %DateTime{}}} =
             ProviderSource.reload(broadcast?: false)

    assert [%{tags: ["provider:fixture-cloud"]}] =
             Store.lookup("203.0.113.10", "provider")

    Repo.query!("""
    INSERT INTO platform.threat_intel_indicators
      (indicator, source, label, severity, expires_at, inserted_at, updated_at)
    VALUES
      ('198.51.100.0/24'::cidr, 'fixture-feed', 'fixture-c2', 4,
       now() + interval '1 day', now() - interval '3 days', now() - interval '2 days')
    """)

    assert {:ok, %{row_count: 1, snapshot_at: %DateTime{}}} =
             ThreatIntelSource.reload(broadcast?: false)

    assert [%{source: "ti", tags: ti_tags}] = Store.lookup("198.51.100.10", "ti")
    assert "ti:fixture-feed" in ti_tags

    Repo.query!("""
    INSERT INTO platform.ocsf_events
      (id, time, class_uid, category_uid, type_uid, activity_id,
       src_endpoint, raw_data)
    VALUES
      (gen_random_uuid(), now() - interval '1 hour', 4003, 4, 400301, 1,
       '{"ip":"192.0.2.44"}'::jsonb,
       '{"firewall_rule":{"name":"fixture-rpz"}}')
    """)

    assert {:ok, %{row_count: 1, snapshot_at: %DateTime{}}} =
             DnsPolicySource.reload(broadcast?: false)

    assert [%{source: "dns-policy", tags: dns_tags}] =
             Store.lookup("192.0.2.44", "dns-policy")

    assert "dns-policy:fixture-rpz" in dns_tags
  end
end
