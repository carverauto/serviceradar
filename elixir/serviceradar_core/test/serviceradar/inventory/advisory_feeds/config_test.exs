defmodule ServiceRadar.Inventory.AdvisoryFeeds.ConfigTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Inventory.AdvisoryFeeds.Config

  @default_url "https://security-metadata.canonical.com/osv/osv-all.tar.xz"
  @default_vex_url "https://security-metadata.canonical.com/vex/vex-all.tar.xz"

  setup do
    previous = Application.get_env(:serviceradar_core, :advisory_feeds)

    on_exit(fn ->
      if previous do
        Application.put_env(:serviceradar_core, :advisory_feeds, previous)
      else
        Application.delete_env(:serviceradar_core, :advisory_feeds)
      end
    end)
  end

  test "source/1 uses Canonical's compact OSV and VEX snapshots by default" do
    Application.put_env(:serviceradar_core, :advisory_feeds, repo_enabled: false)

    assert Config.source("ubuntu-osv-vex") == %{
             url: @default_url,
             options: %{"vex_url" => @default_vex_url}
           }
  end

  test "source/1 prefers the application override to the built-in default" do
    Application.put_env(:serviceradar_core, :advisory_feeds,
      advisory_feed_sources: %{
        "ubuntu-osv-vex" => %{
          url: "https://mirror.example/osv.tar.xz",
          options: %{"vex_url" => "https://mirror.example/vex.tar.xz"}
        }
      }
    )

    assert Config.source("ubuntu-osv-vex") == %{
             url: "https://mirror.example/osv.tar.xz",
             options: %{"vex_url" => "https://mirror.example/vex.tar.xz"}
           }
  end

  test "source/1 returns an explicit error for an unknown feed" do
    assert {:error, :unknown_feed} = Config.source("unknown")
  end

  test "source/1 validates option keys and values without atomizing input" do
    Application.put_env(:serviceradar_core, :advisory_feeds,
      advisory_feed_sources: %{
        "ubuntu-osv-vex" => %{"url" => @default_url, "options" => %{"unknown" => true}}
      }
    )

    assert {:error, :invalid_source_config} = Config.source("ubuntu-osv-vex")

    Application.put_env(:serviceradar_core, :advisory_feeds,
      advisory_feed_sources: %{
        "ubuntu-osv-vex" => %{"url" => @default_url, "options" => %{}}
      }
    )

    assert {:error, :invalid_source_config} = Config.source("ubuntu-osv-vex")
  end
end
