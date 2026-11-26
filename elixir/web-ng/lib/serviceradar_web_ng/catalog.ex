defmodule ServiceRadarWebNG.Catalog do
  @moduledoc """
  Web-facing context operations for Solution Packs, Signed Release Catalogs, and
  Two-Way Private GitOps Synchronization (`4.1`-`4.5`).

  Wraps `ServiceRadar.Catalog`, `Reconciler`, `DependencyChecker`, `PackArchive`,
  `PackExporter`, `ReleaseCatalogClient`, `GitOpsTreeClient`, and
  `CatalogSyncWorker` with authenticated `ServiceRadarWebNG.Accounts.Scope`
  propagation and JSON-ready map serialization.
  """

  use Boundary,
    top_level?: true,
    deps: [ServiceRadar, ServiceRadarWebNG, ServiceRadarWebNG.Plugins],
    exports: :all

  alias ServiceRadar.Camera.VantagePipeline
  alias ServiceRadar.Catalog, as: CoreCatalog
  alias ServiceRadar.Catalog.CatalogRepository
  alias ServiceRadar.Catalog.CatalogSyncWorker
  alias ServiceRadar.Catalog.GitOpsTreeClient
  alias ServiceRadar.Catalog.InstalledSolutionPack
  alias ServiceRadar.Catalog.PackArchive
  alias ServiceRadar.Catalog.PackExporter
  alias ServiceRadar.Catalog.PackManifest
  alias ServiceRadar.Catalog.ReleaseCatalogClient
  alias ServiceRadar.Catalog.SvgSanitizer
  alias ServiceRadar.Dashboards.DashboardPackage
  alias ServiceRadar.DeclarativeChecks.CanonicalJSON
  alias ServiceRadarWebNG.DeclarativeChecks
  alias ServiceRadarWebNG.Plugins.Storage

  @public_developer_portal_url "https://developer.serviceradar.cloud/packs"

  @categories [
    "Camera & Vantage",
    "Storage & NVR",
    "Network & WAN",
    "Synthetic HTTP",
    "Security & Posture",
    "Infrastructure"
  ]

  @spec categories() :: [String.t()]
  def categories, do: @categories

  @spec developer_portal_url() :: String.t()
  def developer_portal_url, do: @public_developer_portal_url

  @doc """
  Lists all Solution Packs available to the gallery, merging shipped offline
  built-in packs, installed packs, and remote catalog repository sync summaries.
  """
  @spec list_packs(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_packs(opts \\ []) when is_list(opts) do
    c_opts = core_opts(opts)

    with {:ok, builtins} <- CoreCatalog.list_builtin_packs(),
         {:ok, installed} <- safe_list_installed(c_opts),
         {:ok, repos} <- safe_list_repositories(c_opts) do
      installed_by_id = Map.new(installed, &{&1.pack_id, &1})
      repo_updates = extract_repo_updates(repos)

      builtin_cards =
        Enum.map(builtins, fn validated ->
          pack_id = validated.manifest["id"]
          inst = Map.get(installed_by_id, pack_id)
          remote_update = Map.get(repo_updates, pack_id)
          serialize_validated_pack(validated, inst, remote_update, source_type: "builtin")
        end)

      builtin_ids = MapSet.new(builtin_cards, & &1["id"])

      extra_installed_cards =
        installed
        |> Enum.reject(&MapSet.member?(builtin_ids, &1.pack_id))
        |> Enum.map(fn inst ->
          remote_update = Map.get(repo_updates, inst.pack_id)
          serialize_installed_only_pack(inst, remote_update)
        end)

      packs =
        Enum.sort_by(builtin_cards ++ extra_installed_cards, fn p ->
          {not p["installed"], String.downcase(p["name"] || "")}
        end)

      {:ok, packs}
    end
  end

  @doc """
  Fetches a single Solution Pack by `pack_id` or `slug`, including its full
  manifest, sanitized README, assets, check documents, rules, dashboards, and
  installed state if present.
  """
  @spec get_pack(String.t(), keyword()) :: {:ok, map()} | {:error, :not_found | term()}
  def get_pack(id_or_slug, opts \\ []) when is_binary(id_or_slug) and is_list(opts) do
    c_opts = core_opts(opts)
    installed = safe_get_installed(id_or_slug, c_opts)

    case CoreCatalog.get_builtin_pack(id_or_slug) do
      {:ok, validated} ->
        {:ok, serialize_validated_pack(validated, installed, nil, source_type: "builtin", detail?: true)}

      {:error, :not_found} ->
        case installed do
          %InstalledSolutionPack{} = inst ->
            {:ok, serialize_installed_only_pack(inst, nil, detail?: true)}

          nil ->
            {:error, :not_found}
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Lists `InstalledSolutionPack` records serialized for UI/API consumption.
  """
  @spec list_installed_packs(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_installed_packs(opts \\ []) when is_list(opts) do
    case CoreCatalog.list_installed_packs(core_opts(opts)) do
      {:ok, packs} -> {:ok, Enum.map(packs, &serialize_installed_record/1)}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Validates a `.srpack`/`.zip` binary or file map via `ServiceRadar.Catalog.validate_pack/2`.
  """
  @spec validate_pack(binary() | map(), keyword()) :: {:ok, map()} | {:error, term()}
  def validate_pack(pack_or_bytes, opts \\ []) do
    CoreCatalog.validate_pack(pack_or_bytes, Keyword.put_new(core_opts(opts), :skip_srql_nif?, true))
  end

  @doc """
  Checks Wasm `plugin_dependencies` readiness via `ServiceRadar.Catalog.check_dependencies/2`.
  """
  @spec check_dependencies(map() | [map()], keyword()) :: {:ok, map()} | {:error, term()}
  def check_dependencies(manifest_or_deps, opts \\ []) do
    CoreCatalog.check_dependencies(manifest_or_deps, core_opts(opts))
  end

  @doc """
  Computes a dry-run installation or upgrade preview for a pack slug, file map,
  validated pack, or `.srpack` binary.
  """
  @spec preview_install(String.t() | map() | binary(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def preview_install(pack_ref, params \\ %{}, opts \\ []) do
    c_opts = Keyword.put_new(core_opts(opts), :skip_srql_nif?, true)

    with {:ok, pack_input} <- resolve_pack_input(pack_ref, c_opts) do
      CoreCatalog.preview_install(pack_input, params, c_opts)
    end
  end

  @doc """
  Atomically installs or upgrades a Solution Pack via `ServiceRadar.Catalog.Reconciler`.
  """
  @spec install_pack(String.t() | map() | binary(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def install_pack(pack_ref, params \\ %{}, opts \\ []) do
    c_opts = Keyword.put_new(core_opts(opts), :skip_srql_nif?, true)

    with {:ok, pack_input} <- resolve_pack_input(pack_ref, c_opts) do
      CoreCatalog.install_pack(pack_input, params, c_opts)
    end
  end

  @doc """
  Uninstalls an installed Solution Pack by `pack_id` or `slug`, preserving
  any operator-detached (`managed: false`) resources.
  """
  @spec uninstall_pack(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def uninstall_pack(id_or_slug, opts \\ []) when is_binary(id_or_slug) and is_list(opts) do
    CoreCatalog.uninstall_pack(id_or_slug, core_opts(opts))
  end

  @doc """
  Detaches an installed Solution Pack by `pack_id` or `slug`, setting `managed: false`
  on its managed resources and removing the installed pack record.
  """
  @spec detach_pack(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def detach_pack(id_or_slug, opts \\ []) when is_binary(id_or_slug) and is_list(opts) do
    CoreCatalog.detach_pack(id_or_slug, core_opts(opts))
  end

  @doc """
  Exports a built-in or installed pack by `id_or_slug` as `:srpack` (`tar.zst` bytes)
  or `:json` (pretty-printed canonical bundle JSON).
  """
  @spec export_pack(String.t(), :srpack | :json, keyword()) ::
          {:ok, binary(), String.t()} | {:error, term()}
  def export_pack(id_or_slug, format \\ :srpack, opts \\ [])
      when is_binary(id_or_slug) and format in [:srpack, :json] and is_list(opts) do
    c_opts = Keyword.put_new(core_opts(opts), :skip_srql_nif?, true)

    with {:ok, validated} <- resolve_validated_pack(id_or_slug, c_opts) do
      slug = validated.manifest["slug"] || id_or_slug
      pack_format_version = Map.get(validated.manifest, "pack_format_version", 1)

      case format do
        :srpack ->
          with {:ok, archive_bytes} <- PackArchive.build(validated.files, c_opts) do
            {:ok, archive_bytes, "#{slug}.srpack"}
          end

        :json ->
          bundle = %{
            "pack_format_version" => pack_format_version,
            "manifest" => validated.manifest,
            "files" => validated.files
          }

          {:ok, CanonicalJSON.encode_pretty(bundle), "#{slug}.srpack.json"}
      end
    end
  end

  @doc """
  Exports a custom pack specification (live checks, rules, dashboards, pipelines,
  schemas, dashboard packages) into a secret-free `.srpack` archive or file tree JSON
  via `ServiceRadar.Catalog`.
  """
  @spec export_custom_pack(map(), :srpack | :json, keyword()) ::
          {:ok, binary(), String.t()} | {:error, term()}
  def export_custom_pack(spec, format \\ :srpack, opts \\ [])
      when is_map(spec) and format in [:srpack, :json] and is_list(opts) do
    c_opts = Keyword.put_new(core_opts(opts), :skip_srql_nif?, true)
    slug = Map.get(spec, "slug") || Map.get(spec, :slug) || "custom-pack"

    case format do
      :srpack ->
        with {:ok, bytes} <- CoreCatalog.export_pack_archive(spec, c_opts) do
          {:ok, bytes, "#{slug}.srpack"}
        end

      :json ->
        with {:ok, file_map} <- CoreCatalog.export_pack_tree(spec, c_opts) do
          pack_format_version =
            case Jason.decode(Map.get(file_map, "manifest.json", "{}")) do
              {:ok, %{"pack_format_version" => v}} when v in [1, 2] -> v
              _ -> 1
            end

          {:ok,
           CanonicalJSON.encode_pretty(%{
             "pack_format_version" => pack_format_version,
             "files" => file_map
           }), "#{slug}.srpack.json"}
        end
    end
  end

  @doc """
  Lists configured `CatalogRepository` rows serialized for UI/API.
  """
  @spec list_repositories(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_repositories(opts \\ []) when is_list(opts) do
    case CoreCatalog.list_repositories(core_opts(opts)) do
      {:ok, repos} -> {:ok, Enum.map(repos, &serialize_repository/1)}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Fetches a single `CatalogRepository` by ID.
  """
  @spec get_repository(String.t(), keyword()) :: {:ok, map()} | {:error, :not_found | term()}
  def get_repository(id, opts \\ []) when is_binary(id) and is_list(opts) do
    case CoreCatalog.get_repository(id, core_opts(opts)) do
      {:ok, repo} -> {:ok, serialize_repository(repo)}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Creates a `CatalogRepository` (`:release_catalog` or `:gitops_tree`).
  """
  @spec create_repository(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_repository(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    case CoreCatalog.create_repository(normalize_repo_attrs(attrs), core_opts(opts)) do
      {:ok, repo} -> {:ok, serialize_repository(repo)}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Updates a non-built-in `CatalogRepository`.
  """
  @spec update_repository(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_repository(id, attrs, opts \\ []) when is_binary(id) and is_map(attrs) and is_list(opts) do
    c_opts = core_opts(opts)

    with {:ok, repo} <- CoreCatalog.get_repository(id, c_opts),
         {:ok, updated} <- CoreCatalog.update_repository(repo, normalize_repo_attrs(attrs), c_opts) do
      {:ok, serialize_repository(updated)}
    end
  end

  @doc """
  Enables or disables a `CatalogRepository` (including the seeded built-in row).
  """
  @spec set_repository_enabled(String.t(), boolean(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def set_repository_enabled(id, enabled?, opts \\ []) when is_binary(id) and is_boolean(enabled?) and is_list(opts) do
    c_opts = core_opts(opts)

    with {:ok, repo} <- CoreCatalog.get_repository(id, c_opts) do
      result =
        if enabled? do
          CoreCatalog.enable_repository(repo, c_opts)
        else
          CoreCatalog.disable_repository(repo, c_opts)
        end

      case result do
        {:ok, updated} -> {:ok, serialize_repository(updated)}
        {:error, _reason} = error -> error
      end
    end
  end

  @doc """
  Deletes a non-built-in `CatalogRepository`.
  """
  @spec delete_repository(String.t(), keyword()) :: :ok | {:error, term()}
  def delete_repository(id, opts \\ []) when is_binary(id) and is_list(opts) do
    c_opts = core_opts(opts)

    with {:ok, repo} <- CoreCatalog.get_repository(id, c_opts) do
      CoreCatalog.delete_repository(repo, c_opts)
    end
  end

  @doc """
  Tests connectivity to a `CatalogRepository` without mutating CNPG.
  """
  @spec test_repository(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def test_repository(id, opts \\ []) when is_binary(id) and is_list(opts) do
    c_opts = core_opts(opts)

    with {:ok, repo} <- CoreCatalog.get_repository(id, c_opts) do
      case repo.mode do
        :release_catalog ->
          with {:ok, index_data} <- ReleaseCatalogClient.fetch_index(repo, c_opts) do
            {:ok,
             %{
               "mode" => "release_catalog",
               "release_tag" => index_data.release_tag,
               "pack_count" => length(index_data.entries),
               "index_url" => index_data.index_url
             }}
          end

        :gitops_tree ->
          with {:ok, listing} <- GitOpsTreeClient.list_remote_packs(repo, c_opts) do
            {:ok,
             %{
               "mode" => "gitops_tree",
               "branch" => repo.branch,
               "commit_sha" => listing.commit_sha,
               "pack_count" => length(listing.packs),
               "packs" => listing.packs
             }}
          end
      end
    end
  end

  @doc """
  Triggers an immediate isolated sync of a single `CatalogRepository`.
  """
  @spec sync_repository(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def sync_repository(id, opts \\ []) when is_binary(id) and is_list(opts) do
    c_opts = core_opts(opts)

    with {:ok, repo} <- CoreCatalog.get_repository(id, c_opts),
         {:ok, installed} <- safe_list_installed(c_opts) do
      installed_by_id = Map.new(installed, &{&1.pack_id, &1})

      case CatalogSyncWorker.sync_one_isolated(repo, installed_by_id, c_opts) do
        %{status: :ok, summary: summary} -> {:ok, summary}
        %{status: :error, error: err} -> {:error, err}
      end
    end
  end

  @doc """
  Pushes a Solution Pack (or export spec) to a `:gitops_tree` `CatalogRepository`.
  """
  @spec push_to_gitops(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def push_to_gitops(repo_id, pack_or_spec, opts \\ [])
      when is_binary(repo_id) and is_map(pack_or_spec) and is_list(opts) do
    c_opts = core_opts(opts)

    with {:ok, repo} <- CoreCatalog.get_repository(repo_id, c_opts) do
      CoreCatalog.push_to_gitops(repo, pack_or_spec, c_opts)
    end
  end

  @doc """
  Lists remote Solution Packs on a `:gitops_tree` repository branch.
  """
  @spec list_gitops_remote_packs(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def list_gitops_remote_packs(repo_id, opts \\ []) when is_binary(repo_id) and is_list(opts) do
    c_opts = core_opts(opts)

    with {:ok, repo} <- CoreCatalog.get_repository(repo_id, c_opts) do
      GitOpsTreeClient.list_remote_packs(repo, c_opts)
    end
  end

  @doc """
  Previews or applies a GitOps pull promotion (`dev -> staging -> prod`) from a
  `:gitops_tree` repository.
  """
  @spec pull_from_gitops(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def pull_from_gitops(repo_id, slug, opts \\ []) when is_binary(repo_id) and is_binary(slug) and is_list(opts) do
    c_opts = Keyword.put_new(core_opts(opts), :skip_srql_nif?, true)
    dry_run? = Keyword.get(opts, :dry_run, true) == true

    with {:ok, repo} <- CoreCatalog.get_repository(repo_id, c_opts) do
      if dry_run? do
        GitOpsTreeClient.preview_pull(repo, slug, c_opts)
      else
        GitOpsTreeClient.apply_pull(repo, slug, c_opts)
      end
    end
  end

  @doc """
  Lists reusable `NetworkCredentialSecret` and `NetworkCredentialRule` options
  for binding `credential_slots` and repository PAT credentials.
  """
  @spec list_credential_options(keyword()) :: %{secrets: [map()], rules: [map()]}
  def list_credential_options(opts \\ []) when is_list(opts) do
    DeclarativeChecks.list_credential_options(opts)
  end

  @doc """
  Lists exportable checks, alert rules, authored dashboards, Vantage pipelines,
  and dashboard packages for the Export / Push to GitOps flow.
  """
  @spec list_exportable_resources(keyword()) :: map()
  def list_exportable_resources(opts \\ []) when is_list(opts) do
    checks =
      case DeclarativeChecks.list_checks(opts) do
        {:ok, list} -> list
        _ -> []
      end

    %{
      "checks" => checks,
      "rules" => [],
      "dashboards" => [],
      "vantage_pipelines" => safe_list_exportable_vantage_pipelines(opts),
      "dashboard_packages" => safe_list_exportable_dashboard_packages(opts)
    }
  end

  @doc """
  Builds a secret-free export spec map from a built-in/installed pack or
  selected resources for `PackExporter` / `GitOpsTreeClient.push_pack/3`.
  """
  @spec build_push_payload(String.t() | nil, map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def build_push_payload(pack_slug, spec_overrides, opts \\ []) when is_map(spec_overrides) do
    c_opts = Keyword.put_new(core_opts(opts), :skip_srql_nif?, true)

    cond do
      is_binary(pack_slug) and String.trim(pack_slug) != "" ->
        with {:ok, validated} <- resolve_validated_pack(pack_slug, c_opts) do
          {:ok, validated.files}
        end

      is_map(spec_overrides["files"]) and map_size(spec_overrides["files"]) > 0 ->
        {:ok, spec_overrides["files"]}

      true ->
        PackExporter.export_tree(spec_overrides, c_opts)
    end
  end

  ## Private helpers

  defp core_opts(opts) do
    opts
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Keyword.put_new(:dashboard_blob_store, default_dashboard_blob_store())
  end

  defp default_dashboard_blob_store do
    %{
      put: &Storage.put_blob/2,
      delete: &Storage.delete_blob/1
    }
  end

  defp safe_list_installed(c_opts) do
    if is_pid(Process.whereis(ServiceRadar.Repo)) do
      case CoreCatalog.list_installed_packs(c_opts) do
        {:ok, list} -> {:ok, list}
        {:error, _} -> {:ok, []}
      end
    else
      {:ok, []}
    end
  end

  defp safe_get_installed(id_or_slug, c_opts) do
    if is_pid(Process.whereis(ServiceRadar.Repo)) do
      case CoreCatalog.get_installed_pack(id_or_slug, c_opts) do
        {:ok, inst} -> inst
        _ -> nil
      end
    end
  end

  defp safe_list_repositories(c_opts) do
    if is_pid(Process.whereis(ServiceRadar.Repo)) do
      case CoreCatalog.list_repositories(c_opts) do
        {:ok, list} -> {:ok, list}
        {:error, _} -> {:ok, []}
      end
    else
      {:ok, []}
    end
  end

  defp safe_list_exportable_vantage_pipelines(opts) do
    if is_pid(Process.whereis(ServiceRadar.Repo)) do
      case VantagePipeline
           |> Ash.Query.for_read(:read)
           |> Ash.read(export_ash_opts(opts)) do
        {:ok, rows} ->
          Enum.map(rows, fn vp ->
            %{
              "pipeline_id" => vp.pipeline_id,
              "version" => vp.version,
              "name" => vp.name,
              "description" => vp.description,
              "enabled" => vp.enabled,
              "source_mode" => to_string(vp.source_mode),
              "trigger_kind" => to_string(vp.trigger_kind),
              "runner" => to_string(vp.runner),
              "capability" => vp.capability,
              "signal_schema_id" => vp.signal_schema_id,
              "signal_schema_version" => vp.signal_schema_version,
              "display_contract_id" => vp.display_contract_id,
              "pack_id" => vp.pack_id,
              "pack_version" => vp.pack_version,
              "managed" => vp.managed
            }
          end)

        _ ->
          []
      end
    else
      []
    end
  end

  defp safe_list_exportable_dashboard_packages(opts) do
    if is_pid(Process.whereis(ServiceRadar.Repo)) do
      case DashboardPackage
           |> Ash.Query.for_read(:read)
           |> Ash.read(export_ash_opts(opts)) do
        {:ok, rows} ->
          Enum.map(rows, fn pkg ->
            %{
              "id" => to_string(pkg.id),
              "dashboard_id" => pkg.dashboard_id,
              "name" => pkg.name,
              "version" => pkg.version,
              "description" => pkg.description,
              "status" => to_string(pkg.status),
              "pack_id" => pkg.pack_id,
              "pack_version" => pkg.pack_version,
              "managed" => pkg.managed
            }
          end)

        _ ->
          []
      end
    else
      []
    end
  end

  defp export_ash_opts(opts) do
    Enum.filter(opts, fn {k, v} -> k in [:scope, :actor] and not is_nil(v) end)
  end

  defp extract_repo_updates(repos) do
    Enum.reduce(repos, %{}, fn repo, acc ->
      updates =
        repo.last_sync_summary
        |> Map.get("updates_available", [])
        |> List.wrap()

      Enum.reduce(updates, acc, fn item, inner ->
        pack_id = item["pack_id"]
        avail = item["available_version"]

        if is_binary(pack_id) and is_binary(avail) do
          Map.put(inner, pack_id, %{
            "available_version" => avail,
            "repository_id" => to_string(repo.id),
            "repository_name" => repo.name
          })
        else
          inner
        end
      end)
    end)
  end

  defp serialize_validated_pack(validated, installed, remote_update, opts) do
    manifest = validated.manifest
    resources = manifest["resources"] || %{}
    checks = List.wrap(resources["checks"])
    rules = List.wrap(resources["rules"])
    dashboards = List.wrap(resources["dashboards"])
    vantage_pipelines = List.wrap(resources["vantage_pipelines"])
    signal_schemas = List.wrap(resources["signal_schemas"])
    dashboard_packages = List.wrap(resources["dashboard_packages"])
    detail? = Keyword.get(opts, :detail?, false)
    source_type = Keyword.get(opts, :source_type, "builtin")

    sanitized_icon =
      case SvgSanitizer.sanitize_icon(manifest["icon"]) do
        {:ok, uri} -> uri
        _ -> nil
      end

    installed_version = installed && installed.pack_version
    available_version = (remote_update && remote_update["available_version"]) || manifest["version"]

    update_available? =
      not is_nil(installed_version) and newer_semver?(available_version, installed_version)

    base = %{
      "pack_format_version" => Map.get(manifest, "pack_format_version", 1),
      "id" => manifest["id"],
      "slug" => manifest["slug"],
      "name" => manifest["name"],
      "version" => manifest["version"],
      "author" => manifest["author"],
      "license" => manifest["license"],
      "description" => manifest["description"],
      "min_serviceradar_version" => manifest["min_serviceradar_version"],
      "categories" => List.wrap(manifest["categories"]),
      "icon" => sanitized_icon,
      "source_type" => if(installed, do: to_string(installed.source_type), else: source_type),
      "installed" => not is_nil(installed),
      "installed_version" => installed_version,
      "available_version" => available_version,
      "update_available" => update_available?,
      "counts" => %{
        "checks" => length(checks),
        "rules" => length(rules),
        "dashboards" => length(dashboards),
        "vantage_pipelines" => length(vantage_pipelines),
        "signal_schemas" => length(signal_schemas),
        "dashboard_packages" => length(dashboard_packages)
      },
      "config" => List.wrap(manifest["config"]),
      "credential_slots" => List.wrap(manifest["credential_slots"]),
      "plugin_dependencies" => List.wrap(manifest["plugin_dependencies"]),
      "worker_dependencies" => List.wrap(manifest["worker_dependencies"]),
      "dashboard_package_dependencies" => List.wrap(manifest["dashboard_package_dependencies"])
    }

    if detail? do
      readme =
        case SvgSanitizer.sanitize_markdown(Map.get(validated.files, "README.md", "")) do
          {:ok, clean} -> clean
          _ -> ""
        end

      svg_assets =
        validated.files
        |> Enum.filter(fn {path, _} ->
          String.starts_with?(path, "assets/") and String.ends_with?(path, ".svg")
        end)
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.flat_map(fn {path, content} ->
          case SvgSanitizer.sanitize_icon(content) do
            {:ok, data_uri} -> [%{"path" => path, "data_uri" => data_uri}]
            _ -> []
          end
        end)

      Map.merge(base, %{
        "manifest" => manifest,
        "readme" => readme,
        "assets" => svg_assets,
        "checks" =>
          Enum.map(
            validated.checks,
            &%{
              "slug" => &1.entry["slug"],
              "file" => &1.entry["file"],
              "document" => &1.raw
            }
          ),
        "rules" =>
          Enum.map(
            validated.rules,
            &%{
              "name" => &1.entry["name"],
              "kind" => &1.entry["kind"],
              "install_state" => &1.entry["install_state"] || "enabled",
              "file" => &1.entry["file"],
              "document" => &1.raw
            }
          ),
        "dashboards" =>
          Enum.map(
            validated.dashboards,
            &%{
              "slug" => &1.entry["slug"],
              "file" => &1.entry["file"],
              "document" => &1.raw
            }
          ),
        "vantage_pipelines" =>
          Enum.map(
            Map.get(validated, :vantage_pipelines, []),
            &%{
              "pipeline_id" => &1.normalized["pipeline_id"],
              "version" => &1.normalized["version"],
              "name" => &1.normalized["name"],
              "file" => &1.entry["file"],
              "install_state" => &1.entry["install_state"] || "enabled",
              "document" => &1.raw
            }
          ),
        "signal_schemas" =>
          Enum.map(
            Map.get(validated, :signal_schemas, []),
            &%{
              "schema_id" => &1.schema_id,
              "version" => &1.version,
              "display_contract_id" => &1.display_contract_id,
              "signal_schema" => &1.signal_schema,
              "display_contract" => &1.display_contract,
              "file" => &1.entry["file"] || &1.entry["schema_file"]
            }
          ),
        "dashboard_packages" =>
          Enum.map(
            Map.get(validated, :dashboard_packages, []),
            &%{
              "slug" => &1.slug,
              "dashboard_id" => &1.dashboard_id,
              "version" => &1.version,
              "route_slug" => &1.entry["route_slug"] || &1.slug,
              "name" => &1.dashboard_manifest.name,
              "interface_version" => &1.dashboard_manifest.renderer["interface_version"],
              "renderer_sha256" => &1.renderer_sha256,
              "renderer_bytes" => byte_size(&1.renderer_bytes)
            }
          ),
        "installed_record" => installed && serialize_installed_record(installed)
      })
    else
      base
    end
  end

  defp serialize_installed_only_pack(%InstalledSolutionPack{} = inst, remote_update, opts \\ []) do
    manifest = inst.manifest_snapshot || %{}
    resources = manifest["resources"] || %{}
    detail? = Keyword.get(opts, :detail?, false)
    available_version = (remote_update && remote_update["available_version"]) || inst.pack_version

    sanitized_icon =
      case SvgSanitizer.sanitize_icon(inst.icon || manifest["icon"]) do
        {:ok, uri} -> uri
        _ -> nil
      end

    base = %{
      "pack_format_version" => Map.get(manifest, "pack_format_version", 1),
      "id" => inst.pack_id,
      "slug" => inst.slug,
      "name" => inst.name,
      "version" => inst.pack_version,
      "author" => manifest["author"] || "Custom",
      "license" => manifest["license"],
      "description" => inst.description || manifest["description"],
      "min_serviceradar_version" => manifest["min_serviceradar_version"],
      "categories" => List.wrap(inst.categories),
      "icon" => sanitized_icon,
      "source_type" => to_string(inst.source_type),
      "installed" => true,
      "installed_version" => inst.pack_version,
      "available_version" => available_version,
      "update_available" => newer_semver?(available_version, inst.pack_version),
      "counts" => %{
        "checks" => length(List.wrap(resources["checks"])),
        "rules" => length(List.wrap(resources["rules"])),
        "dashboards" => length(List.wrap(resources["dashboards"])),
        "vantage_pipelines" => length(List.wrap(resources["vantage_pipelines"])),
        "signal_schemas" => length(List.wrap(resources["signal_schemas"])),
        "dashboard_packages" => length(List.wrap(resources["dashboard_packages"]))
      },
      "config" => List.wrap(manifest["config"]),
      "credential_slots" => List.wrap(manifest["credential_slots"]),
      "plugin_dependencies" => List.wrap(manifest["plugin_dependencies"]),
      "worker_dependencies" => List.wrap(manifest["worker_dependencies"]),
      "dashboard_package_dependencies" => List.wrap(manifest["dashboard_package_dependencies"])
    }

    if detail? do
      Map.merge(base, %{
        "manifest" => manifest,
        "readme" => "",
        "assets" => [],
        "checks" => [],
        "rules" => [],
        "dashboards" => [],
        "vantage_pipelines" => List.wrap(resources["vantage_pipelines"]),
        "signal_schemas" => List.wrap(resources["signal_schemas"]),
        "dashboard_packages" => List.wrap(resources["dashboard_packages"]),
        "installed_record" => serialize_installed_record(inst)
      })
    else
      base
    end
  end

  defp serialize_installed_record(%InstalledSolutionPack{} = inst) do
    %{
      "id" => to_string(inst.id),
      "pack_id" => inst.pack_id,
      "slug" => inst.slug,
      "name" => inst.name,
      "pack_version" => inst.pack_version,
      "source_type" => to_string(inst.source_type),
      "catalog_repository_id" => inst.catalog_repository_id && to_string(inst.catalog_repository_id),
      "source_commit_sha" => inst.source_commit_sha,
      "source_release_tag" => inst.source_release_tag,
      "source_branch" => inst.source_branch,
      "source_pr_url" => inst.source_pr_url,
      "config_values" => inst.config_values || %{},
      "resource_manifest" => inst.resource_manifest || %{},
      "installed_at" => inst.installed_at,
      "upgraded_at" => inst.upgraded_at,
      "last_synced_at" => inst.last_synced_at
    }
  end

  defp serialize_repository(%CatalogRepository{} = repo) do
    %{
      "id" => to_string(repo.id),
      "name" => repo.name,
      "mode" => to_string(repo.mode),
      "provider_type" => to_string(repo.provider_type),
      "repo_url" => repo.repo_url,
      "branch" => repo.branch,
      "base_path" => repo.base_path,
      "push_strategy" => to_string(repo.push_strategy),
      "index_asset_name" => repo.index_asset_name,
      "signing_key_id" => repo.signing_key_id,
      "signing_public_key" => repo.signing_public_key,
      "credential_secret_id" => repo.credential_secret_id && to_string(repo.credential_secret_id),
      "builtin" => repo.builtin,
      "is_default" => repo.is_default,
      "enabled" => repo.enabled,
      "auto_reconcile" => repo.auto_reconcile,
      "last_sync_at" => repo.last_sync_at,
      "last_sync_error" => repo.last_sync_error,
      "last_sync_summary" => repo.last_sync_summary || %{}
    }
  end

  defp normalize_repo_attrs(attrs) when is_map(attrs) do
    Enum.reduce(attrs, %{}, fn {k, v}, acc ->
      key = if is_atom(k), do: Atom.to_string(k), else: to_string(k)

      case key do
        "mode" -> Map.put(acc, :mode, normalize_atom(v, ~w(release_catalog gitops_tree)))
        "provider_type" -> Map.put(acc, :provider_type, normalize_atom(v, ~w(github gitlab gitea portal)))
        "push_strategy" -> Map.put(acc, :push_strategy, normalize_atom(v, ~w(pull_request direct_commit)))
        "enabled" -> Map.put(acc, :enabled, truthy?(v))
        "auto_reconcile" -> Map.put(acc, :auto_reconcile, truthy?(v))
        "credential_secret_id" -> Map.put(acc, :credential_secret_id, blank_to_nil(v))
        "signing_key_id" -> Map.put(acc, :signing_key_id, blank_to_nil(v))
        "signing_public_key" -> Map.put(acc, :signing_public_key, blank_to_nil(v))
        "name" -> Map.put(acc, :name, v)
        "repo_url" -> Map.put(acc, :repo_url, v)
        "branch" -> Map.put(acc, :branch, v)
        "base_path" -> Map.put(acc, :base_path, v)
        "index_asset_name" -> Map.put(acc, :index_asset_name, v)
        _ -> acc
      end
    end)
  end

  defp normalize_atom(v, _allowed) when is_atom(v), do: v

  defp normalize_atom(v, allowed) when is_binary(v) do
    trimmed = String.trim(v)
    if trimmed in allowed, do: String.to_existing_atom(trimmed), else: trimmed
  end

  defp normalize_atom(v, _allowed), do: v

  defp truthy?(v), do: v in [true, "true", "1", 1, "on"]

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(v), do: v

  defp resolve_pack_input(slug, _c_opts) when is_binary(slug) do
    if String.starts_with?(slug, <<0x28, 0xB5, 0x2F, 0xFD>>) or String.starts_with?(slug, "PK") do
      {:ok, slug}
    else
      case CoreCatalog.get_builtin_pack(slug) do
        {:ok, validated} -> {:ok, validated.files}
        {:error, _} = err -> err
      end
    end
  end

  defp resolve_pack_input(%{files: files}, _c_opts) when is_map(files), do: {:ok, files}
  defp resolve_pack_input(%{"files" => files}, _c_opts) when is_map(files), do: {:ok, files}
  defp resolve_pack_input(file_map, _c_opts) when is_map(file_map), do: {:ok, file_map}

  defp resolve_validated_pack(id_or_slug, c_opts) do
    case CoreCatalog.get_builtin_pack(id_or_slug) do
      {:ok, validated} ->
        {:ok, validated}

      {:error, :not_found} ->
        case safe_get_installed(id_or_slug, c_opts) do
          %InstalledSolutionPack{manifest_snapshot: snapshot} when is_map(snapshot) ->
            PackManifest.validate_pack_tree(%{"manifest.json" => Jason.encode!(snapshot)}, c_opts)

          _ ->
            {:error, :not_found}
        end

      err ->
        err
    end
  end

  defp newer_semver?(candidate, current) when is_binary(candidate) and is_binary(current) do
    with {:ok, v1} <- Version.parse(candidate),
         {:ok, v2} <- Version.parse(current) do
      Version.compare(v1, v2) == :gt
    else
      _ -> false
    end
  end

  defp newer_semver?(_, _), do: false
end
