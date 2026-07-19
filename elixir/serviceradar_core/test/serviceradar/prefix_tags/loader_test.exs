defmodule ServiceRadar.PrefixTags.LoaderTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.PrefixTags.Loader
  alias ServiceRadar.PrefixTags.Store

  @pubsub ServiceRadar.PubSub
  @active_columns [
    "prefix",
    "tags",
    "vrf",
    "site",
    "role",
    "tenant",
    "status",
    "source",
    "snapshot_id",
    "promoted_at"
  ]

  setup do
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)

    case Process.whereis(@pubsub) do
      nil ->
        start_supervised!({Phoenix.PubSub, name: @pubsub})

      _pid ->
        :ok
    end

    on_exit(fn ->
      Store.clear()
    end)

    Store.clear()
    :ok
  end

  test "broadcast invalidation is delivered to subscribers" do
    Phoenix.PubSub.subscribe(@pubsub, Loader.pubsub_topic())

    assert :ok = Loader.broadcast_invalidation(%{source: "test"})
    assert_receive {:prefix_tags_snapshot_changed, %{source: "test"}}, 1_000
  end

  test "loader installs empty trie when DB is unavailable" do
    # load_on_init true will hit Repo; with no DB this should fail-open to empty.
    pid =
      start_supervised!(
        {Loader, load_on_init: true, name: :prefix_tags_loader_test},
        id: :prefix_tags_loader_test
      )

    assert is_pid(pid)

    # Wait for handle_continue to finish
    _ = GenServer.call(pid, :status)

    assert Store.lookup("10.1.2.3") == []
    status = GenServer.call(pid, :status)
    assert is_binary(status.last_error)
  end

  test "manual Store rows remain queryable independent of loader" do
    Store.put_rows([%{prefix: "10.0.0.0/8", tags: ["internal"], source: "manual"}])
    assert [%{tags: ["internal"]}] = Store.lookup("10.1.2.3")
  end

  test "single-query parser keeps populated and zero-row active snapshots consistent" do
    populated_at = ~N[2026-07-18 12:00:00]
    empty_at = ~U[2026-07-18 13:00:00Z]

    result = %{
      columns: @active_columns,
      rows: [
        [
          "10.0.0.0/8",
          ["site:lab"],
          nil,
          "lab",
          nil,
          nil,
          "active",
          "netbox",
          "snapshot-populated",
          populated_at
        ],
        [
          nil,
          nil,
          nil,
          nil,
          nil,
          nil,
          nil,
          "manual",
          "snapshot-empty",
          empty_at
        ]
      ]
    }

    assert {:ok, by_source, metadata} = Loader.parse_active_rows(result)

    assert [%{prefix: "10.0.0.0/8", source: "netbox", tags: ["site:lab"]}] =
             by_source["netbox"]

    assert by_source["manual"] == []
    assert metadata["netbox"] == ["snapshot-populated"]
    assert metadata["manual"] == ["snapshot-empty"]
    assert metadata[{:promoted_at, "netbox"}] == ~U[2026-07-18 12:00:00Z]
    assert metadata[{:promoted_at, "manual"}] == empty_at
  end

  test "single-query parser handles no active snapshots" do
    assert {:ok, %{}, %{}} =
             Loader.parse_active_rows(%{columns: @active_columns, rows: []})
  end
end
