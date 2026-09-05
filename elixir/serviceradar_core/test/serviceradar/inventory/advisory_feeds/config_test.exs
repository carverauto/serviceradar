defmodule ServiceRadar.Inventory.AdvisoryFeeds.ConfigTest do
  @moduledoc """
  The VulnCheck credential is DB-only.

  These run without a repo, so `definition_credential_ref/0` finds no row --
  which is exactly the "no credential_ref" state the fallback used to paper
  over. `async: false` because they mutate the process environment.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Inventory.AdvisoryFeeds.Config

  @default_url "https://security-metadata.canonical.com/osv/osv-all.tar.xz"
  @default_vex_url "https://security-metadata.canonical.com/vex/vex-all.tar.xz"

  setup do
    previous = Application.get_env(:serviceradar_core, :advisory_feeds)

    on_exit(fn ->
      System.delete_env("VULNCHECK_API_TOKEN")
      System.delete_env("SERVICERADAR_VULNCHECK_TOKEN")

      if previous do
        Application.put_env(:serviceradar_core, :advisory_feeds, previous)
      else
        Application.delete_env(:serviceradar_core, :advisory_feeds)
      end
    end)

    :ok
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

  test "a feed with no credential_ref fails with the credential the operator must create" do
    assert {:error, {:missing_vulncheck_credential, message}} = Config.vulncheck_token()

    assert message =~ "/settings/networks/credentials"
    assert message =~ "/settings/security/vulnerability-feeds"
    assert message =~ "vulncheck-kev"
  end

  test "an environment token does not stand in for a credential rule" do
    System.put_env("VULNCHECK_API_TOKEN", "env-token")
    System.put_env("SERVICERADAR_VULNCHECK_TOKEN", "legacy-env-token")

    assert {:error, {:missing_vulncheck_credential, _message}} = Config.vulncheck_token()
  end

  test "an application-config token does not stand in for a credential rule" do
    Application.put_env(:serviceradar_core, :advisory_feeds, vulncheck_token: "app-config-token")

    assert {:error, {:missing_vulncheck_credential, _message}} = Config.vulncheck_token()
  end
end
