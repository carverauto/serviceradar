defmodule ServiceRadar.Inventory.AdvisoryFeeds.FeedRegistryTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.AdvisoryFeeds.FeedRegistry
  alias ServiceRadar.Inventory.AdvisoryFeeds.FeedWorker

  test "registry covers every FeedWorker feed key" do
    registry_feeds = MapSet.new(FeedRegistry.all(), & &1.feed)
    worker_feeds = MapSet.new(FeedWorker.feeds())

    assert MapSet.equal?(registry_feeds, worker_feeds),
           "registry feeds #{inspect(MapSet.to_list(registry_feeds))} must match worker feeds #{inspect(MapSet.to_list(worker_feeds))}"
  end

  test "fetch/1 returns an entry with the canonical identity columns" do
    assert {:ok, entry} = FeedRegistry.fetch("cisa-kev")
    assert entry.provider == "cisa"
    assert entry.feed_key == "cisa-kev"
    assert is_binary(entry.display_name)
    assert is_binary(entry.feed_type)
    assert entry.refresh_interval_seconds > 0
  end

  test "registers the credential-free atomic Ubuntu OSV and OpenVEX feed" do
    assert {:ok, entry} = FeedRegistry.fetch("ubuntu-osv-vex")

    assert entry == %{
             feed: "ubuntu-osv-vex",
             provider: "ubuntu",
             feed_key: "ubuntu-osv-vex",
             display_name: "Ubuntu OSV + OpenVEX",
             feed_type: "addon_normalized_advisory_feed",
             requires_credential: false,
             refresh_interval_seconds: 21_600
           }

    assert {:ok, "ubuntu-osv-vex"} =
             FeedRegistry.feed_for("ubuntu", "ubuntu-osv-vex")
  end

  test "fetch/1 is :error for an unknown feed" do
    assert :error = FeedRegistry.fetch("does-not-exist")
    assert :error = FeedRegistry.fetch(nil)
  end

  test "feed_for/2 maps provider/feed_key back to the FeedWorker feed key" do
    assert {:ok, "vulncheck-kev"} = FeedRegistry.feed_for("vulncheck", "vulncheck-kev")
    assert {:ok, "nist-nvd2"} = FeedRegistry.feed_for("nvd", "nist-nvd2")
  end

  test "feed_for/2 is :error for an unknown provider/feed_key pair" do
    assert :error = FeedRegistry.feed_for("nvd", "vulncheck-kev")
    assert :error = FeedRegistry.feed_for("unknown", "unknown")
  end
end
