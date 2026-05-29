defmodule ServiceRadar.Inventory.BumblebeeCatalogSourceSeeder do
  @moduledoc """
  Seeds the pinned upstream Bumblebee threat-intel catalog source.
  """

  use ServiceRadar.DelayedSeeder, callback: :seed_defaults

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.BumblebeeCatalogSource

  require Ash.Query
  require Logger

  @source_name "upstream-bumblebee-threat-intel"
  @upstream_repo "https://github.com/perplexityai/bumblebee"
  @upstream_tag "v0.1.1"
  @upstream_commit "c24089804ee66ece4bec6f14638cb98985389cdb"
  @upstream_path "threat_intel"
  @source_url "https://api.github.com/repos/perplexityai/bumblebee/contents/threat_intel?ref=v0.1.1"
  @pinned_revision "#{@upstream_tag}+#{@upstream_commit}"
  @catalog_version "perplexityai-bumblebee-#{@upstream_tag}"

  @catalog_files [
    "antv-mini-shai-hulud.json",
    "gemstuffer.json",
    "mini-shai-hulud.json",
    "node-ipc-credential-stealer.json",
    "nx-console-vscode-2026-05-18.json",
    "shopsprint-decimal-typosquat.json"
  ]

  @spec seed_defaults() :: :ok | {:error, term()}
  def seed_defaults do
    if repo_enabled?() do
      actor = SystemActor.system(:bumblebee_catalog_source_seeder)
      opts = [actor: actor]

      ensure_source(opts)
    else
      :ok
    end
  end

  defp ensure_source(opts) do
    query =
      BumblebeeCatalogSource
      |> Ash.Query.for_read(:read, %{}, opts)
      |> Ash.Query.filter(name == ^@source_name)

    case Ash.read_one(query, opts) do
      {:ok, nil} ->
        create_source(opts)

      {:ok, %BumblebeeCatalogSource{}} ->
        Logger.debug("Bumblebee catalog source already exists")
        :ok

      {:error, reason} ->
        Logger.warning("Failed to check Bumblebee catalog source: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp create_source(opts) do
    attrs = %{
      name: @source_name,
      url: @source_url,
      pinned_revision: @pinned_revision,
      refresh_cron: "0 3 * * *",
      enabled: true,
      metadata: %{
        "catalog_version" => @catalog_version,
        "source_revision" => @pinned_revision,
        "upstream_repo" => @upstream_repo,
        "upstream_tag" => @upstream_tag,
        "upstream_commit" => @upstream_commit,
        "upstream_path" => @upstream_path,
        "catalog_urls" => catalog_urls()
      }
    }

    changeset = Ash.Changeset.for_create(BumblebeeCatalogSource, :create, attrs, opts)

    case Ash.create(changeset, opts) do
      {:ok, _source} ->
        Logger.info("Created pinned Bumblebee catalog source", source: @source_name)
        :ok

      {:error, reason} ->
        Logger.warning("Failed to seed Bumblebee catalog source: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp catalog_urls do
    Enum.map(@catalog_files, fn file ->
      "https://raw.githubusercontent.com/perplexityai/bumblebee/#{@upstream_tag}/#{@upstream_path}/#{file}"
    end)
  end
end
