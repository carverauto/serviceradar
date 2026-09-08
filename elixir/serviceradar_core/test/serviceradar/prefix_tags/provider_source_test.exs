defmodule ServiceRadar.PrefixTags.ProviderSourceTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.PrefixTags.ProviderSource
  alias ServiceRadar.PrefixTags.Store

  setup do
    on_exit(fn -> Store.clear() end)
    Store.clear()
    :ok
  end

  test "provider_for_ip extracts provider name from trie tags" do
    Store.put_rows("provider", [
      %{prefix: "10.0.0.0/8", tags: ["provider:aws"], source: "provider"},
      %{prefix: "10.1.0.0/16", tags: ["provider:aws", "provider:aws-us-east"], source: "provider"}
    ])

    # Most-specific match first → first tag on that entry
    assert ProviderSource.provider_for_ip("10.1.2.3") == "aws"
    assert ProviderSource.provider_for_ip("8.8.8.8") == nil
  end

  test "source_name is provider" do
    assert ProviderSource.source_name() == "provider"
  end

  test "query parser preserves the durable active snapshot timestamp" do
    snapshot_at = ~N[2026-07-18 10:30:00]

    parsed =
      ProviderSource.parse_query_result(%{
        rows: [
          ["snapshot-id", snapshot_at, "203.0.113.0/24", "aws"],
          ["snapshot-id", snapshot_at, "2001:db8::/32", "gcp"]
        ]
      })

    assert parsed.active_snapshot?
    assert parsed.snapshot_at == ~U[2026-07-18 10:30:00Z]
    assert Enum.map(parsed.rows, & &1.tags) == [["provider:aws"], ["provider:gcp"]]
  end

  test "snapshot_token is stable for the same durable snapshot" do
    meta = %{
      id: "45cb4ae7-d020-4708-a59c-ed5d387990a4",
      source_sha256: "abc",
      record_count: 410_063
    }

    assert ProviderSource.snapshot_token(meta) ==
             "45cb4ae7-d020-4708-a59c-ed5d387990a4:abc:410063"

    Store.put_rows("provider", [
      %{prefix: "10.0.0.0/8", tags: ["provider:aws"], source: "provider"}
    ])

    Store.put_snapshot_token("provider", ProviderSource.snapshot_token(meta))
    assert Store.loaded?("provider")
    assert Store.snapshot_token("provider") == ProviderSource.snapshot_token(meta)

    Store.clear("provider")
    assert Store.snapshot_token("provider") == nil
  end

  test "query parser distinguishes an active empty snapshot from no active snapshot" do
    snapshot_at = ~U[2026-07-18 10:30:00Z]

    assert %{
             active_snapshot?: true,
             rows: [],
             snapshot_at: ^snapshot_at
           } =
             ProviderSource.parse_query_result(%{
               rows: [["snapshot-id", snapshot_at, nil, nil]]
             })

    assert %{active_snapshot?: false, rows: [], snapshot_at: nil} =
             ProviderSource.parse_query_result(%{rows: []})
  end
end
