defmodule ServiceRadar.Inventory.AdvisoryFeeds.FeedDefinitionSeederTest do
  use ServiceRadar.DataCase, async: false
  use Oban.Testing, repo: ServiceRadar.Repo, prefix: "platform"

  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Inventory.AdvisoryFeeds.Config
  alias ServiceRadar.Inventory.AdvisoryFeeds.FeedDefinitionSeeder
  alias ServiceRadar.Inventory.AdvisoryFeeds.FeedRegistry
  alias ServiceRadar.Inventory.AdvisoryFeeds.FeedWorker
  alias ServiceRadar.Inventory.VulnerabilityFeedDefinition

  require Ash.Query

  @moduletag :integration

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    actor = %{
      id: Ash.UUID.generate(),
      email: "feed-def-test@serviceradar.local",
      role: :admin,
      permissions: MapSet.new(["settings.integrations.manage", "settings.credentials.manage"])
    }

    destroy_seeded_definitions(actor)

    {:ok, actor: actor}
  end

  test "seed_defaults/0 warns when no VulnCheck credential_ref is attached" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = FeedDefinitionSeeder.seed_defaults()
      end)

    assert log =~ "advisory_feeds:"
    assert log =~ "/settings/networks/credentials"
    assert log =~ "vulncheck-kev"
  end

  test "seed_defaults/0 does not broker the secret when a credential_ref is attached", %{
    actor: actor
  } do
    assert :ok = FeedDefinitionSeeder.seed_defaults()

    vulncheck = fetch(actor, "vulncheck", "vulncheck-kev")
    secret = create_vulncheck_secret!(actor, "boot check", "boot-check-token")

    {:ok, _edited} =
      vulncheck
      |> Ash.Changeset.for_update(:update, %{credential_ref: to_string(secret.id)}, actor: actor)
      |> Ash.update(actor: actor)

    grants_before = advisory_feed_grants(actor)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = FeedDefinitionSeeder.seed_defaults()
      end)

    refute log =~ "/settings/networks/credentials"

    assert advisory_feed_grants(actor) == grants_before
  end

  test "seed_defaults/0 creates one feed definition per FeedWorker feed", %{actor: actor} do
    assert :ok = FeedDefinitionSeeder.seed_defaults()

    definitions = read_seeded(actor)
    seeded = MapSet.new(definitions, &{&1.provider, &1.feed_key})
    expected = MapSet.new(FeedRegistry.all(), &{&1.provider, &1.feed_key})

    assert MapSet.equal?(seeded, expected)

    cisa = Enum.find(definitions, &(&1.provider == "cisa" and &1.feed_key == "cisa-kev"))
    assert cisa.display_name == "CISA Known Exploited Vulnerabilities"
    assert cisa.last_status == "never"
    assert cisa.refresh_interval_seconds == 3_600

    by_key = Map.new(definitions, &{{&1.provider, &1.feed_key}, &1})

    assert by_key[{"cisa", "cisa-kev"}].enabled == false
    assert by_key[{"ubuntu", "ubuntu-osv-vex"}].enabled == true
    assert by_key[{"vulncheck", "vulncheck-kev"}].enabled == false
    assert by_key[{"nvd", "nist-nvd2"}].enabled == false
  end

  test "seed_defaults/0 never re-enables an operator disable or a gated feed", %{
    actor: actor
  } do
    for {provider, feed_key} <- [{"ubuntu", "ubuntu-osv-vex"}, {"cisa", "cisa-kev"}] do
      {:ok, _} =
        VulnerabilityFeedDefinition
        |> Ash.Changeset.for_create(
          :upsert,
          %{
            provider: provider,
            feed_key: feed_key,
            display_name: "#{provider}/#{feed_key}",
            feed_type: "addon_normalized_advisory_feed"
          },
          actor: actor
        )
        |> Ash.create(actor: actor)
    end

    # An explicit operator disable bumps updated_at past inserted_at (two fields
    # so the edit is a real change even where the flag already reads false).
    {:ok, _} =
      actor
      |> fetch("ubuntu", "ubuntu-osv-vex")
      |> Ash.Changeset.for_update(
        :update,
        %{enabled: false, refresh_interval_seconds: 999},
        actor: actor
      )
      |> Ash.update(actor: actor)

    # ... as does a failed run attempt, which also stamps last_failure_at.
    {:ok, _} =
      actor
      |> fetch("cisa", "cisa-kev")
      |> Ash.Changeset.for_update(
        :update_status,
        %{last_status: "error", last_failure_at: DateTime.utc_now()},
        actor: actor
      )
      |> Ash.update(actor: actor)

    # A pristine credential-gated row must stay off.
    {:ok, _} =
      VulnerabilityFeedDefinition
      |> Ash.Changeset.for_create(
        :upsert,
        %{
          provider: "nvd",
          feed_key: "nist-nvd2",
          display_name: "nvd/nist-nvd2",
          feed_type: "addon_normalized_advisory_feed"
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    assert fetch(actor, "ubuntu", "ubuntu-osv-vex").enabled == false
    assert fetch(actor, "cisa", "cisa-kev").enabled == false

    assert :ok = FeedDefinitionSeeder.seed_defaults()

    assert fetch(actor, "ubuntu", "ubuntu-osv-vex").enabled == false
    assert fetch(actor, "cisa", "cisa-kev").enabled == false
    assert fetch(actor, "nvd", "nist-nvd2").enabled == false
  end

  test "seed_defaults/0 enables only the pristine Ubuntu row left by an old seed", %{
    actor: actor
  } do
    for {provider, feed_key} <- [{"ubuntu", "ubuntu-osv-vex"}, {"cisa", "cisa-kev"}] do
      {:ok, _} =
        VulnerabilityFeedDefinition
        |> Ash.Changeset.for_create(
          :upsert,
          %{
            provider: provider,
            feed_key: feed_key,
            display_name: "#{provider}/#{feed_key}",
            feed_type: "addon_normalized_advisory_feed"
          },
          actor: actor
        )
        |> Ash.create(actor: actor)
    end

    assert fetch(actor, "ubuntu", "ubuntu-osv-vex").enabled == false
    assert fetch(actor, "cisa", "cisa-kev").enabled == false

    assert :ok = FeedDefinitionSeeder.seed_defaults()

    assert fetch(actor, "ubuntu", "ubuntu-osv-vex").enabled == true
    assert fetch(actor, "cisa", "cisa-kev").enabled == false
  end

  test "seed_defaults/0 is idempotent and does not clobber operator edits", %{actor: actor} do
    assert :ok = FeedDefinitionSeeder.seed_defaults()

    cisa = fetch(actor, "cisa", "cisa-kev")

    {:ok, _edited} =
      cisa
      |> Ash.Changeset.for_update(:update, %{enabled: true, refresh_interval_seconds: 999},
        actor: actor
      )
      |> Ash.update(actor: actor)

    # Re-running the seeder must not create duplicates nor reset operator state.
    assert :ok = FeedDefinitionSeeder.seed_defaults()

    assert length(read_seeded(actor)) == length(FeedRegistry.all())

    reread = fetch(actor, "cisa", "cisa-kev")
    assert reread.enabled == true
    assert reread.refresh_interval_seconds == 999
  end

  test "mark_status writes now persist because the row exists", %{actor: actor} do
    assert :ok = FeedDefinitionSeeder.seed_defaults()

    # FeedWorker.perform short-circuits on the disabled master flag, but the
    # status row is what the seeder guarantees exists; assert update_status lands.
    cisa = fetch(actor, "cisa", "cisa-kev")

    {:ok, updated} =
      cisa
      |> Ash.Changeset.for_update(
        :update_status,
        %{last_status: "success", last_message: "loaded 5 advisories"},
        actor: actor
      )
      |> Ash.update(actor: actor)

    assert updated.last_status == "success"
    assert updated.last_message == "loaded 5 advisories"
  end

  test "mark_status merges successful generation metadata into durable definition metadata", %{
    actor: actor
  } do
    assert :ok = FeedDefinitionSeeder.seed_defaults()

    definition = fetch(actor, "vulncheck", "vulncheck-kev")

    {:ok, _with_durable_metadata} =
      definition
      |> Ash.Changeset.for_update(
        :update,
        %{
          metadata: %{
            "source" => "core-scheduled",
            "credential_storage" => "network_credential_secret",
            "generation" => 7
          }
        },
        actor: actor
      )
      |> Ash.update(actor: actor)

    assert {:ok, updated} =
             FeedWorker.mark_status(
               "vulncheck-kev",
               %{
                 last_status: "success",
                 metadata: %{"generation" => 42, "source_objects_seen" => 5}
               },
               actor
             )

    assert updated.last_status == "success"

    assert updated.metadata == %{
             "source" => "core-scheduled",
             "credential_storage" => "network_credential_secret",
             "generation" => 42,
             "source_objects_seen" => 5
           }
  end

  test "run_now enqueues the mapped FeedWorker feed and marks running", %{actor: actor} do
    assert :ok = FeedDefinitionSeeder.seed_defaults()

    definition = fetch(actor, "vulncheck", "vulncheck-kev")

    assert {:ok, ran} =
             definition
             |> Ash.Changeset.for_update(:run_now, %{}, actor: actor)
             |> Ash.update(actor: actor)

    assert ran.last_status == "running"
    assert ran.last_attempt_at

    assert_enqueued(worker: FeedWorker, args: %{feed: "vulncheck-kev"}, prefix: "platform")
  end

  test "run_now can approve one snapshot contraction for the enqueued job", %{actor: actor} do
    assert :ok = FeedDefinitionSeeder.seed_defaults()

    definition = fetch(actor, "vulncheck", "vulncheck-kev")

    assert {:ok, ran} =
             definition
             |> Ash.Changeset.for_update(
               :run_now,
               %{accept_snapshot_contraction: true},
               actor: actor
             )
             |> Ash.update(actor: actor)

    assert ran.last_status == "running"

    assert_enqueued(
      worker: FeedWorker,
      args: %{feed: "vulncheck-kev", accept_snapshot_contraction: true},
      max_attempts: 1,
      prefix: "platform"
    )
  end

  test "Config.refresh_seconds reads the feed-def row as primary source", %{actor: actor} do
    assert :ok = FeedDefinitionSeeder.seed_defaults()

    # Default seeded cadence.
    assert Config.refresh_seconds("cisa-kev") == 3_600

    cisa = fetch(actor, "cisa", "cisa-kev")

    {:ok, _edited} =
      cisa
      |> Ash.Changeset.for_update(:update, %{refresh_interval_seconds: 7_200}, actor: actor)
      |> Ash.update(actor: actor)

    assert Config.refresh_seconds("cisa-kev") == 7_200
  end

  test "Config.source reads operator URL and options from the feed definition first", %{
    actor: actor
  } do
    assert :ok = FeedDefinitionSeeder.seed_defaults()
    ubuntu = fetch(actor, "ubuntu", "ubuntu-osv-vex")

    {:ok, _edited} =
      ubuntu
      |> Ash.Changeset.for_update(
        :update,
        %{
          url: "https://mirror.example/osv.tar.xz",
          options: %{"vex_url" => "https://mirror.example/vex.tar.xz"}
        },
        actor: actor
      )
      |> Ash.update(actor: actor)

    assert Config.source("ubuntu-osv-vex") == %{
             url: "https://mirror.example/osv.tar.xz",
             options: %{"vex_url" => "https://mirror.example/vex.tar.xz"}
           }
  end

  test "Ubuntu DB source wins over app source and invalid DB options fail closed", %{actor: actor} do
    previous = Application.get_env(:serviceradar_core, :advisory_feeds)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:serviceradar_core, :advisory_feeds, previous),
        else: Application.delete_env(:serviceradar_core, :advisory_feeds)
    end)

    Application.put_env(:serviceradar_core, :advisory_feeds,
      advisory_feed_sources: %{
        "ubuntu-osv-vex" => %{
          url: "https://app.example/osv.tar.xz",
          options: %{"vex_url" => "https://app.example/vex.tar.xz"}
        }
      }
    )

    assert :ok = FeedDefinitionSeeder.seed_defaults()
    ubuntu = fetch(actor, "ubuntu", "ubuntu-osv-vex")

    {:ok, ubuntu} =
      ubuntu
      |> Ash.Changeset.for_update(
        :update,
        %{
          url: "https://db.example/osv.tar.xz",
          options: %{"vex_url" => "https://db.example/vex.tar.xz"}
        },
        actor: actor
      )
      |> Ash.update(actor: actor)

    assert %{
             url: "https://db.example/osv.tar.xz",
             options: %{"vex_url" => "https://db.example/vex.tar.xz"}
           } = Config.source("ubuntu-osv-vex")

    {:ok, ubuntu} =
      ubuntu
      |> Ash.Changeset.for_update(:update, %{options: %{"unknown" => true}}, actor: actor)
      |> Ash.update(actor: actor)

    assert {:error, :invalid_source_config} = Config.source("ubuntu-osv-vex")

    {:ok, _ubuntu} =
      ubuntu
      |> Ash.Changeset.for_update(:update, %{options: %{"vex_url" => 123}}, actor: actor)
      |> Ash.update(actor: actor)

    assert {:error, :invalid_source_config} = Config.source("ubuntu-osv-vex")
  end

  test "blank Ubuntu DB URL falls through and credential-free scheduling and run_now enqueue", %{
    actor: actor
  } do
    assert :ok = FeedDefinitionSeeder.seed_defaults()
    ubuntu = fetch(actor, "ubuntu", "ubuntu-osv-vex")

    assert ubuntu.enabled
    assert ubuntu.credential_ref in [nil, ""]

    {:ok, ubuntu} =
      ubuntu
      |> Ash.Changeset.for_update(:update, %{url: nil}, actor: actor)
      |> Ash.update(actor: actor)

    assert Config.source("ubuntu-osv-vex").url =~ "security-metadata.canonical.com"

    {:ok, ubuntu} =
      ubuntu
      |> Ash.Changeset.for_update(:update, %{url: "   "}, actor: actor)
      |> Ash.update(actor: actor)

    assert Config.source("ubuntu-osv-vex").url =~ "security-metadata.canonical.com"

    assert {:ok, :scheduled} = FeedWorker.ensure_scheduled()
    assert_enqueued(worker: FeedWorker, args: %{feed: "ubuntu-osv-vex"}, prefix: "platform")

    assert {:ok, ran} =
             ubuntu
             |> Ash.Changeset.for_update(:run_now, %{}, actor: actor)
             |> Ash.update(actor: actor)

    assert ran.last_status == "running"
    assert_enqueued(worker: FeedWorker, args: %{feed: "ubuntu-osv-vex"}, prefix: "platform")
  end

  test "Config.vulncheck_token reads the feed-def credential_ref as primary source", %{
    actor: actor
  } do
    assert :ok = FeedDefinitionSeeder.seed_defaults()

    vulncheck = fetch(actor, "vulncheck", "vulncheck-kev")
    secret = create_vulncheck_secret!(actor, "primary", "operator-set-token")

    {:ok, _edited} =
      vulncheck
      |> Ash.Changeset.for_update(:update, %{credential_ref: to_string(secret.id)}, actor: actor)
      |> Ash.update(actor: actor)

    assert {:ok, "operator-set-token"} = Config.vulncheck_token()
  end

  test "Config.vulncheck_token falls back to the nist-nvd2 credential_ref", %{
    actor: actor
  } do
    assert :ok = FeedDefinitionSeeder.seed_defaults()

    nist = fetch(actor, "nvd", "nist-nvd2")
    secret = create_vulncheck_secret!(actor, "nist fallback", "nist-row-token")

    {:ok, _edited} =
      nist
      |> Ash.Changeset.for_update(:update, %{credential_ref: to_string(secret.id)}, actor: actor)
      |> Ash.update(actor: actor)

    assert {:ok, "nist-row-token"} = Config.vulncheck_token()
  end

  test "Config.feed_enabled?/1 follows the operator feed row", %{actor: actor} do
    assert :ok = FeedDefinitionSeeder.seed_defaults()

    refute Config.feed_enabled?("cisa-kev")

    cisa = fetch(actor, "cisa", "cisa-kev")

    {:ok, _edited} =
      cisa
      |> Ash.Changeset.for_update(:update, %{enabled: true}, actor: actor)
      |> Ash.update(actor: actor)

    assert Config.feed_enabled?("cisa-kev")
  end

  defp read_seeded(actor) do
    keys = Enum.map(FeedRegistry.all(), &{&1.provider, &1.feed_key})

    {:ok, definitions} =
      VulnerabilityFeedDefinition
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.read(actor: actor)

    Enum.filter(definitions, &({&1.provider, &1.feed_key} in keys))
  end

  defp fetch(actor, provider, feed_key) do
    {:ok, definition} =
      VulnerabilityFeedDefinition
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(provider == ^provider and feed_key == ^feed_key)
      |> Ash.read_one(actor: actor)

    definition
  end

  defp destroy_seeded_definitions(actor) do
    Enum.each(FeedRegistry.all(), fn entry ->
      case fetch(actor, entry.provider, entry.feed_key) do
        %VulnerabilityFeedDefinition{} = definition -> Ash.destroy!(definition, actor: actor)
        _ -> :ok
      end
    end)
  end

  defp advisory_feed_grants(actor) do
    {:ok, grants} =
      CredentialBrokerGrant
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(grant_type == "advisory_feed_credential")
      |> Ash.read(actor: actor)

    grants |> Enum.map(& &1.id) |> Enum.sort()
  end

  defp create_vulncheck_secret!(actor, name, token) do
    NetworkCredentialSecret.create_secret!(
      %{
        name: "VulnCheck #{name}",
        provider: "vulncheck",
        credential_kind: :api_token,
        secret_payload: token
      },
      actor: actor
    )
  end
end
