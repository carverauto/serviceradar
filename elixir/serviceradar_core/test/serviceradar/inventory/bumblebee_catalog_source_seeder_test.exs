defmodule ServiceRadar.Inventory.BumblebeeCatalogSourceSeederTest do
  @moduledoc """
  DB-backed coverage for advancing the seeded upstream Bumblebee catalog pin.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.BumblebeeCatalogSource
  alias ServiceRadar.Inventory.BumblebeeCatalogSourceSeeder
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  @source_name "upstream-bumblebee-threat-intel"
  @upstream_repo "https://github.com/perplexityai/bumblebee"
  @old_pinned_revision "v0.1.1+c24089804ee66ece4bec6f14638cb98985389cdb"
  @current_pinned_revision "v0.1.2+cc57710eeaf685e7b89924a36c8583cad0a378fe"

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:bumblebee_catalog_source_seeder_test)

    on_exit(fn ->
      # Leave the singleton seeded row at the current pin for other tests
      # sharing this lane clone.
      BumblebeeCatalogSourceSeeder.seed_defaults()
    end)

    {:ok, actor: actor}
  end

  test "advances a seeded source to the current pin and preserves operator fields",
       %{actor: actor} do
    source =
      seed_shaped_source!(actor, %{
        url:
          "https://api.github.com/repos/perplexityai/bumblebee/contents/threat_intel?ref=v0.1.1",
        pinned_revision: @old_pinned_revision,
        refresh_cron: "17 4 * * *",
        enabled: false,
        metadata: %{
          "catalog_version" => "perplexityai-bumblebee-v0.1.1",
          "source_revision" => @old_pinned_revision,
          "upstream_repo" => @upstream_repo,
          "upstream_tag" => "v0.1.1",
          "upstream_commit" => "c24089804ee66ece4bec6f14638cb98985389cdb",
          "upstream_path" => "threat_intel",
          "catalog_urls" => ["https://example.invalid/old-catalog.json"],
          "operator_note" => "keep-me"
        }
      })

    assert :ok = BumblebeeCatalogSourceSeeder.seed_defaults()

    assert {:ok, advanced} =
             BumblebeeCatalogSource
             |> Ash.Query.filter(id == ^source.id)
             |> Ash.read_one(actor: actor)

    assert advanced.pinned_revision == @current_pinned_revision
    assert advanced.url =~ "ref=v0.1.2"
    assert advanced.metadata["catalog_version"] == "perplexityai-bumblebee-v0.1.2"
    assert advanced.metadata["source_revision"] == @current_pinned_revision
    assert advanced.metadata["upstream_tag"] == "v0.1.2"
    assert length(advanced.metadata["catalog_urls"]) == 11
    assert Enum.all?(advanced.metadata["catalog_urls"], &String.contains?(&1, "/v0.1.2/"))

    # Operator-owned state is not the seeder's to move.
    assert advanced.enabled == false
    assert advanced.refresh_cron == "17 4 * * *"
    assert advanced.metadata["operator_note"] == "keep-me"

    # Advancing is idempotent.
    assert :ok = BumblebeeCatalogSourceSeeder.seed_defaults()

    assert {:ok, again} =
             BumblebeeCatalogSource
             |> Ash.Query.filter(id == ^source.id)
             |> Ash.read_one(actor: actor)

    assert again.pinned_revision == @current_pinned_revision
    assert again.updated_at == advanced.updated_at
  end

  test "leaves a same-named source without the seed marker alone", %{actor: actor} do
    source =
      seed_shaped_source!(actor, %{
        url: "https://example.invalid/operator-catalog",
        pinned_revision: "operator-pinned-rev",
        refresh_cron: "0 3 * * *",
        enabled: true,
        metadata: %{"catalog_version" => "operator-catalog"}
      })

    assert :ok = BumblebeeCatalogSourceSeeder.seed_defaults()

    assert {:ok, reloaded} =
             BumblebeeCatalogSource
             |> Ash.Query.filter(id == ^source.id)
             |> Ash.read_one(actor: actor)

    assert reloaded.pinned_revision == "operator-pinned-rev"
    assert reloaded.url == "https://example.invalid/operator-catalog"
    assert reloaded.metadata["catalog_version"] == "operator-catalog"
  end

  # The seeded source is a singleton by name and the app may already have
  # seeded it; drive the existing row to the requested shape instead of
  # assuming a blank database.
  defp seed_shaped_source!(actor, attrs) do
    query =
      BumblebeeCatalogSource
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(name == ^@source_name)

    case Ash.read_one(query, actor: actor) do
      {:ok, %BumblebeeCatalogSource{} = existing} ->
        existing
        |> Ash.Changeset.for_update(:update, attrs, actor: actor)
        |> Ash.update!(actor: actor)

      {:ok, nil} ->
        BumblebeeCatalogSource
        |> Ash.Changeset.for_create(:create, Map.put(attrs, :name, @source_name), actor: actor)
        |> Ash.create!(actor: actor)
    end
  end
end
