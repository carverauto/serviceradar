defmodule ServiceRadar.Catalog.CatalogSyncWorker do
  @moduledoc """
  Oban background worker (`3.4`) iterating enabled `CatalogRepository` sources
  with strict per-repository fault isolation.

  - For `:release_catalog` sources: refreshes remote `serviceradar-pack-index.json`
    pack inventory and compares versions against `InstalledSolutionPack` rows.
  - For `:gitops_tree` sources: inspects remote `<base_path>/*` pack trees on
    the configured branch; when `auto_reconcile: true`, applies non-diverged
    managed updates automatically, and otherwise records `"updates_available"`
    in `last_sync_summary` for operator confirmation in the Catalog Gallery.
  """

  use Oban.Worker,
    queue: :integrations,
    max_attempts: 3,
    unique: [period: 300]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Catalog.CatalogRepository
  alias ServiceRadar.Catalog.GitOpsTreeClient
  alias ServiceRadar.Catalog.InstalledSolutionPack
  alias ServiceRadar.Catalog.ReleaseCatalogClient

  require Logger

  @worker_actor SystemActor.system(:catalog_sync_worker)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    _ = args
    {:ok, _summary} = sync_all_enabled()
    :ok
  end

  @doc """
  Synchronizes all enabled `CatalogRepository` rows with per-repository fault
  isolation so a failing source never aborts remaining sources.

  Accepts injectable `:repositories`, `:installed_packs`, `:release_client_opts`,
  `:gitops_client_opts`, and `:status_recorder` options for DB-free unit testing.
  """
  @spec sync_all_enabled(keyword()) :: {:ok, [map()]}
  def sync_all_enabled(opts \\ []) when is_list(opts) do
    repos = load_enabled_repositories(opts)
    installed_by_id = load_installed_packs_by_id(opts)

    outcomes =
      Enum.map(repos, fn repo ->
        sync_one_isolated(repo, installed_by_id, opts)
      end)

    {:ok, outcomes}
  end

  @doc """
  Synchronizes a single `CatalogRepository` with `try/rescue/catch` isolation.
  """
  @spec sync_one_isolated(CatalogRepository.t() | map(), map(), keyword()) :: map()
  def sync_one_isolated(repo, installed_by_id, opts \\ []) do
    result =
      try do
        do_sync_repository(repo, installed_by_id, opts)
      rescue
        err -> {:error, Exception.message(err)}
      catch
        kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
      end

    case result do
      {:ok, summary} ->
        record_success(repo, summary, opts)
        %{repository_id: repo.id, status: :ok, summary: summary}

      {:error, reason} ->
        error_text = format_error(reason)

        Logger.warning("Catalog repository sync failed",
          repository_id: repo.id,
          repo_url: repo.repo_url,
          reason: error_text
        )

        record_failure(repo, error_text, opts)
        %{repository_id: repo.id, status: :error, error: error_text}
    end
  end

  defp do_sync_repository(%{mode: :release_catalog} = repo, installed_by_id, opts) do
    client_opts = Keyword.get(opts, :release_client_opts, [])

    with {:ok, index_data} <- ReleaseCatalogClient.fetch_index(repo, client_opts) do
      updates =
        index_data.entries
        |> Enum.filter(fn entry ->
          pack_id = entry["id"] || entry["pack_id"]
          remote_ver = entry["version"]

          case Map.get(installed_by_id, pack_id) do
            nil -> false
            installed -> newer_semver?(remote_ver, installed.pack_version)
          end
        end)
        |> Enum.map(fn e ->
          %{"pack_id" => e["id"] || e["pack_id"], "available_version" => e["version"]}
        end)

      {:ok,
       %{
         "mode" => "release_catalog",
         "release_tag" => index_data.release_tag,
         "pack_count" => length(index_data.entries),
         "updates_available" => updates
       }}
    end
  end

  defp do_sync_repository(%{mode: :gitops_tree} = repo, installed_by_id, opts) do
    client_opts =
      opts
      |> Keyword.get(:gitops_client_opts, [])
      |> Keyword.put_new(:actor, @worker_actor)

    with {:ok, remote_listing} <- GitOpsTreeClient.list_remote_packs(repo, client_opts) do
      {updates, reconciled} =
        Enum.reduce(remote_listing.packs, {[], []}, fn remote_pack, {upd_acc, rec_acc} ->
          pack_id = remote_pack["id"]
          slug = remote_pack["slug"]
          remote_ver = remote_pack["version"]
          installed = Map.get(installed_by_id, pack_id)

          needs_sync? =
            not is_nil(installed) and
              (newer_semver?(remote_ver, installed.pack_version) or
                 installed.source_commit_sha != remote_listing.commit_sha)

          cond do
            not needs_sync? ->
              {upd_acc, rec_acc}

            Map.get(repo, :auto_reconcile, false) == true ->
              case GitOpsTreeClient.apply_pull(repo, slug, client_opts) do
                {:ok, _applied} ->
                  {upd_acc, [pack_id | rec_acc]}

                {:error, _} ->
                  {[
                     %{
                       "pack_id" => pack_id,
                       "slug" => slug,
                       "available_version" => remote_ver,
                       "commit_sha" => remote_listing.commit_sha
                     }
                     | upd_acc
                   ], rec_acc}
              end

            true ->
              {[
                 %{
                   "pack_id" => pack_id,
                   "slug" => slug,
                   "available_version" => remote_ver,
                   "commit_sha" => remote_listing.commit_sha
                 }
                 | upd_acc
               ], rec_acc}
          end
        end)

      {:ok,
       %{
         "mode" => "gitops_tree",
         "branch" => repo.branch,
         "commit_sha" => remote_listing.commit_sha,
         "pack_count" => length(remote_listing.packs),
         "updates_available" => Enum.reverse(updates),
         "auto_reconciled" => Enum.reverse(reconciled)
       }}
    end
  end

  defp load_enabled_repositories(opts) do
    case Keyword.get(opts, :repositories) do
      list when is_list(list) ->
        Enum.filter(list, &(&1.enabled != false))

      nil ->
        case CatalogRepository.list_enabled(actor: @worker_actor) do
          {:ok, rows} -> rows
          _ -> []
        end
    end
  end

  defp load_installed_packs_by_id(opts) do
    list =
      case Keyword.get(opts, :installed_packs) do
        packs when is_list(packs) ->
          packs

        nil ->
          case InstalledSolutionPack.list(actor: @worker_actor) do
            {:ok, rows} -> rows
            _ -> []
          end
      end

    Map.new(list, &{&1.pack_id, &1})
  end

  defp record_success(repo, summary, opts) do
    case Keyword.get(opts, :status_recorder) do
      fun when is_function(fun, 3) ->
        fun.(repo, :ok, summary)

      _ ->
        if is_struct(repo, CatalogRepository) and is_pid(Process.whereis(ServiceRadar.Repo)) do
          _ =
            repo
            |> Ash.Changeset.for_update(:record_sync_success, %{last_sync_summary: summary},
              actor: @worker_actor
            )
            |> Ash.update(actor: @worker_actor)
        end

        :ok
    end
  end

  defp record_failure(repo, error_text, opts) do
    case Keyword.get(opts, :status_recorder) do
      fun when is_function(fun, 3) ->
        fun.(repo, :error, error_text)

      _ ->
        if is_struct(repo, CatalogRepository) and is_pid(Process.whereis(ServiceRadar.Repo)) do
          _ =
            repo
            |> Ash.Changeset.for_update(
              :record_sync_error,
              %{last_sync_error: error_text, last_sync_summary: %{"error" => error_text}},
              actor: @worker_actor
            )
            |> Ash.update(actor: @worker_actor)
        end

        :ok
    end
  end

  defp newer_semver?(remote, current) when is_binary(remote) and is_binary(current) do
    case {Version.parse(remote), Version.parse(current)} do
      {{:ok, vr}, {:ok, vc}} -> Version.compare(vr, vc) == :gt
      _ -> remote != current
    end
  end

  defp newer_semver?(_remote, _current), do: false

  defp format_error(msg) when is_binary(msg), do: String.slice(msg, 0, 500)
  defp format_error(other), do: other |> inspect() |> String.slice(0, 500)
end
