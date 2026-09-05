defmodule ServiceRadarWebNG.Plugins.Packages do
  @moduledoc """
  Context module for plugin packages and review workflow.
  """

  alias ServiceRadar.Automation.Northbound.PluginActionSync
  alias ServiceRadar.DataService.Client, as: DataServiceClient
  alias ServiceRadar.Observability.ServiceStateRegistry
  alias ServiceRadar.Plugins.AlertRuleCatalog
  alias ServiceRadar.Plugins.Manifest
  alias ServiceRadar.Plugins.PackageAssignmentLifecycle
  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginArtifactMirror
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Plugins.ProducerScheduleCatalog
  alias ServiceRadar.Plugins.SNMPRequirementCatalog
  alias ServiceRadarWebNG.Observability.ContractRegistry
  alias ServiceRadarWebNG.Plugins.FirstPartyImporter
  alias ServiceRadarWebNG.Plugins.GitHubImporter
  alias ServiceRadarWebNG.Plugins.Repositories
  alias ServiceRadarWebNG.Plugins.Storage
  alias ServiceRadarWebNG.Plugins.UploadSignature

  require Ash.Query
  require Logger

  @default_limit 100
  @max_limit 500

  @spec list(map(), keyword()) :: [PluginPackage.t()]
  def list(filters \\ %{}, opts \\ []) do
    scope = Keyword.get(opts, :scope)
    limit = normalize_limit(Map.get(filters, :limit) || Map.get(filters, "limit"))

    query =
      PluginPackage
      |> Ash.Query.for_read(:read)
      |> maybe_filter_plugin_id(filters)
      |> maybe_filter_status(filters)
      |> maybe_filter_source_type(filters)
      |> Ash.Query.limit(limit)
      |> Ash.Query.sort(inserted_at: :desc)

    read(query, scope)
  end

  @spec get(String.t(), keyword()) ::
          {:ok, PluginPackage.t()} | {:error, :not_found} | {:error, term()}
  def get(id, opts \\ [])

  def get(id, opts) when is_binary(id) do
    scope = Keyword.get(opts, :scope)

    case read_one_by_id(id, scope) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, package} -> {:ok, package}
      {:error, error} -> {:error, error}
    end
  end

  def get(_id, _opts), do: {:error, :not_found}

  @spec create(map(), keyword()) :: {:ok, PluginPackage.t()} | {:error, term()}
  def create(attrs, opts \\ [])

  def create(attrs, opts) when is_map(attrs) do
    scope = Keyword.get(opts, :scope)
    actor = Keyword.get(opts, :actor)
    ash_opts = ash_opts(scope, actor)

    attrs =
      attrs
      |> Map.delete(:wasm_object_key)
      |> Map.delete("wasm_object_key")
      |> drop_nil_values()

    source_type =
      normalize_source_type(Map.get(attrs, :source_type) || Map.get(attrs, "source_type"))

    case source_type do
      :github ->
        create_from_github(attrs, ash_opts)

      :first_party ->
        create_from_first_party(attrs, ash_opts)

      :invalid ->
        {:error, :invalid_source_type}

      _ ->
        create_from_upload(attrs, ash_opts)
    end
  end

  def create(_attrs, _opts), do: {:error, :invalid_attributes}

  @spec approve(String.t(), map(), keyword()) :: {:ok, PluginPackage.t()} | {:error, term()}
  def approve(id, attrs, opts \\ [])

  def approve(id, attrs, opts) when is_binary(id) and is_map(attrs) do
    scope = Keyword.get(opts, :scope)
    actor = Keyword.get(opts, :actor)
    ash_opts = ash_opts(scope, actor)

    with {:ok, package} <- get(id, scope: scope),
         :ok <- enforce_verification_policy(package) do
      attrs =
        attrs
        |> apply_manifest_defaults(package.manifest || %{})
        |> maybe_put(:approved_by, Keyword.get(opts, :approved_by))

      package
      |> Ash.Changeset.for_update(:approve, attrs)
      |> update_resource_with_opts(ash_opts)
      |> sync_northbound_actions(:approved)
      |> sync_alert_rules(:approved)
      |> sync_snmp_requirements(:approved)
      |> refresh_contract_index()
    end
  end

  def approve(_id, _attrs, _opts), do: {:error, :invalid_attributes}

  @spec deny(String.t(), map(), keyword()) :: {:ok, PluginPackage.t()} | {:error, term()}
  def deny(id, attrs, opts \\ [])

  def deny(id, attrs, opts) when is_binary(id) and is_map(attrs) do
    scope = Keyword.get(opts, :scope)
    actor = Keyword.get(opts, :actor)
    ash_opts = ash_opts(scope, actor)

    with {:ok, package} <- get(id, scope: scope) do
      package
      |> Ash.Changeset.for_update(:deny, attrs)
      |> update_resource_with_opts(ash_opts)
      |> sync_northbound_actions(:disabled)
      |> sync_alert_rules(:disabled)
      |> sync_snmp_requirements(:disabled)
    end
  end

  def deny(_id, _attrs, _opts), do: {:error, :invalid_attributes}

  @spec revoke(String.t(), map(), keyword()) :: {:ok, PluginPackage.t()} | {:error, term()}
  def revoke(id, attrs, opts \\ [])

  def revoke(id, attrs, opts) when is_binary(id) and is_map(attrs) do
    scope = Keyword.get(opts, :scope)
    actor = Keyword.get(opts, :actor)
    ash_opts = ash_opts(scope, actor)

    with {:ok, package} <- get(id, scope: scope) do
      package
      |> Ash.Changeset.for_update(:revoke, attrs)
      |> update_resource_with_opts(ash_opts)
      |> case do
        {:ok, updated} ->
          with :ok <- disable_assignments_for_package(updated, ash_opts) do
            ServiceStateRegistry.deactivate_for_package(updated)
            sync_northbound_actions({:ok, updated}, :disabled)
          end

        other ->
          other
      end
      |> sync_alert_rules(:disabled)
      |> sync_snmp_requirements(:disabled)
      |> refresh_contract_index()
    end
  end

  def revoke(_id, _attrs, _opts), do: {:error, :invalid_attributes}

  # Approval and revocation are the two transitions that change what the runtime
  # display-contract index holds, so the local node picks them up immediately
  # instead of waiting out the registry's refresh interval. Other nodes in a
  # cluster converge on that interval; the index is a render cache, not a
  # correctness boundary, so a few minutes of staleness costs a package its
  # custom rendering, never its data.
  # `Map.put_new/3` is wrong for an attribute the resource declares `allow_nil?
  # false`: the API controller builds its attrs map with every key present, so a
  # caller who simply omitted the field leaves an explicit `nil` that `put_new`
  # will not replace and Ash then rejects.
  defp put_default(attrs, key, default) do
    case Map.get(attrs, key) do
      nil -> Map.put(attrs, key, default)
      _value -> attrs
    end
  end

  defp refresh_contract_index({:ok, _package} = result) do
    ContractRegistry.refresh_async()
    result
  end

  defp refresh_contract_index(result), do: result

  @spec restage(String.t(), keyword()) :: {:ok, PluginPackage.t()} | {:error, term()}
  def restage(id, opts \\ [])

  def restage(id, opts) when is_binary(id) do
    scope = Keyword.get(opts, :scope)
    actor = Keyword.get(opts, :actor)
    ash_opts = ash_opts(scope, actor)

    with {:ok, package} <- get(id, scope: scope) do
      package
      |> Ash.Changeset.for_update(:restage, %{})
      |> update_resource_with_opts(ash_opts)
      |> sync_northbound_actions(:disabled)
      |> sync_alert_rules(:disabled)
      |> sync_snmp_requirements(:disabled)
    end
  end

  def restage(_id, _opts), do: {:error, :invalid_attributes}

  @spec delete(String.t(), keyword()) :: :ok | {:ok, PluginPackage.t()} | {:error, term()}
  def delete(id, opts \\ [])

  def delete(id, opts) when is_binary(id) do
    scope = Keyword.get(opts, :scope)

    with {:ok, package} <- get(id, scope: scope) do
      result =
        package
        |> Ash.Changeset.for_destroy(:destroy)
        |> destroy_resource(scope)

      case result do
        :ok ->
          ServiceStateRegistry.deactivate_for_package(package)
          PluginActionSync.disable_package(package)
          :ok

        {:ok, _package} = ok ->
          ServiceStateRegistry.deactivate_for_package(package)
          PluginActionSync.disable_package(package)
          ok

        other ->
          other
      end
    end
  end

  def delete(_id, _opts), do: {:error, :invalid_attributes}

  @spec upload_blob(PluginPackage.t(), binary(), keyword()) ::
          {:ok, PluginPackage.t()} | {:error, term()}
  def upload_blob(package, payload, opts \\ [])

  def upload_blob(%PluginPackage{} = package, payload, opts) when is_binary(payload) do
    content_hash = Storage.sha256(payload)

    store_wasm_blob(package, payload, content_hash, opts)
  end

  def upload_blob(_package, _payload, _opts), do: {:error, :invalid_attributes}

  @spec sync_first_party_plugins(keyword()) :: {:ok, map()} | {:error, term()}
  def sync_first_party_plugins(opts \\ []) do
    repo_url = Keyword.get(opts, :repo_url)
    limit = Keyword.get(opts, :limit, 10)
    release_tag = Keyword.get(opts, :release_tag)

    # Trust material for this repository -- its access token and its signing key
    # -- rides along with every discovery and import call, so the importer never
    # has to look a repository up and its tests stay database-free.
    source_attrs =
      %{}
      |> maybe_put(:repo_url, repo_url)
      |> maybe_put(:index_asset_name, Keyword.get(opts, :index_asset_name))
      |> maybe_put(:github_token, Keyword.get(opts, :github_token))
      |> maybe_put(:trusted_upload_signing_keys, Keyword.get(opts, :trusted_upload_signing_keys))

    with {:ok, plugins, filter_tag} <-
           discover_first_party_plugins(source_attrs, limit, release_tag, opts) do
      existing = existing_import_keys(opts)

      candidates =
        plugins
        |> maybe_filter_release_tag(filter_tag)
        |> Enum.filter(&Map.get(&1, :import_ready?))
        |> dedupe_first_party_plugin_versions()

      # Idempotence: a catalog entry whose (plugin_id, version, release_tag) is
      # already imported is skipped, not re-imported (and never duplicated).
      {already_imported, to_import} =
        Enum.split_with(
          candidates,
          &MapSet.member?(existing, {&1.plugin_id, &1.version, &1.release_tag})
        )

      results =
        Enum.map(to_import, fn plugin ->
          import_attrs =
            Map.merge(source_attrs, %{
              source_type: :first_party,
              repo_url: plugin.repo_url,
              release_tag: plugin.release_tag,
              plugin_id: plugin.plugin_id,
              version: plugin.version
            })

          {plugin, create(import_attrs, opts)}
        end)

      imported =
        Enum.count(results, fn {_plugin, result} -> match?({:ok, _package}, result) end)

      failed =
        results
        |> Enum.filter(fn {_plugin, result} -> match?({:error, _reason}, result) end)
        |> Enum.map(fn {plugin, {:error, reason}} ->
          %{
            plugin_id: plugin.plugin_id,
            version: plugin.version,
            release_tag: plugin.release_tag,
            error: reason
          }
        end)

      {:ok,
       %{
         discovered: length(plugins),
         import_ready: length(results) + length(already_imported),
         imported: imported,
         skipped: length(already_imported),
         failed: failed
       }}
    end
  end

  defp discover_first_party_plugins(attrs, limit, release_tag, opts) do
    if Keyword.get(opts, :allow_release_fallback, false) do
      FirstPartyImporter.list_plugins_for_sync(attrs, limit: limit, release_tag: release_tag)
    else
      result =
        if is_binary(release_tag) and release_tag != "" do
          FirstPartyImporter.list_release_plugins(attrs, release_tag)
        else
          FirstPartyImporter.list_recent_plugins(attrs, limit)
        end

      with {:ok, plugins} <- result do
        {:ok, plugins, release_tag}
      end
    end
  end

  # (plugin_id, version, release_tag) keys of already-imported packages, read
  # with the caller's scope/actor (falling back to an unauthorized read only if
  # neither is provided).
  defp existing_import_keys(opts) do
    scope = Keyword.get(opts, :scope)
    actor = Keyword.get(opts, :actor)

    query =
      PluginPackage
      |> Ash.Query.for_read(:read)
      |> Ash.Query.limit(@max_limit)

    packages =
      cond do
        not is_nil(scope) -> Ash.read!(query, scope: scope)
        not is_nil(actor) -> Ash.read!(query, actor: actor)
        true -> Ash.read!(query)
      end

    MapSet.new(packages, &{&1.plugin_id, &1.version, &1.source_release_tag})
  rescue
    _ -> MapSet.new()
  end

  defp maybe_filter_release_tag(plugins, release_tag) when is_binary(release_tag) and release_tag != "" do
    Enum.filter(plugins, &(&1.release_tag == release_tag))
  end

  defp maybe_filter_release_tag(plugins, _release_tag), do: plugins

  defp dedupe_first_party_plugin_versions(plugins) do
    plugins
    |> Enum.reduce({MapSet.new(), []}, fn plugin, {seen, acc} ->
      key = {Map.get(plugin, :plugin_id), Map.get(plugin, :version)}

      if MapSet.member?(seen, key) do
        {seen, acc}
      else
        {MapSet.put(seen, key), [plugin | acc]}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  @spec upload_blob_file(PluginPackage.t(), String.t(), keyword()) ::
          {:ok, PluginPackage.t()} | {:error, term()}
  def upload_blob_file(package, path, opts \\ [])

  def upload_blob_file(%PluginPackage{} = package, path, opts) when is_binary(path) do
    with {:ok, content_hash} <- Storage.sha256_file(path) do
      store_wasm_blob_file(package, path, content_hash, opts)
    end
  end

  def upload_blob_file(_package, _path, _opts), do: {:error, :invalid_attributes}

  defp ensure_plugin(%Manifest{} = manifest, attrs, ash_opts) do
    plugin_id = manifest.id
    source = Map.get(manifest, :source) || %{}

    plugin_attrs = %{
      plugin_id: plugin_id,
      name: Map.get(attrs, :plugin_name) || manifest.name,
      description: Map.get(attrs, :plugin_description) || manifest.description,
      source_repo_url:
        Map.get(attrs, :source_repo_url) ||
          Map.get(source, :repo_url) ||
          Map.get(source, "repo_url"),
      homepage_url:
        Map.get(attrs, :homepage_url) ||
          Map.get(source, :homepage) ||
          Map.get(source, "homepage")
    }

    case read_plugin(plugin_id, ash_opts) do
      {:ok, nil} ->
        Plugin
        |> Ash.Changeset.for_create(:create, plugin_attrs)
        |> create_resource(ash_opts)

      {:ok, plugin} ->
        {:ok, plugin}

      {:error, error} ->
        {:error, error}
    end
  end

  defp create_from_upload(attrs, ash_opts) do
    manifest = Map.get(attrs, :manifest) || %{}

    display_contract =
      Map.get(attrs, :display_contract) ||
        Map.get(attrs, "display_contract") ||
        Map.get(manifest, "display_contract") ||
        Map.get(manifest, :display_contract) ||
        %{}

    with {:ok, manifest_struct} <- Manifest.from_map(manifest),
         {:ok, _plugin} <- ensure_plugin(manifest_struct, attrs, ash_opts) do
      signal_schemas =
        Map.get(attrs, :signal_schemas) ||
          Map.get(attrs, "signal_schemas") ||
          manifest_struct.signal_schemas ||
          []

      producer_schedules =
        Map.get(attrs, :producer_schedules) ||
          Map.get(attrs, "producer_schedules") ||
          manifest_struct.producer_schedules ||
          []

      alert_rules =
        Map.get(attrs, :alert_rules) ||
          Map.get(attrs, "alert_rules") ||
          manifest_struct.alert_rules ||
          []

      snmp_requirements =
        Map.get(attrs, :snmp_requirements) ||
          Map.get(attrs, "snmp_requirements") ||
          manifest_struct.snmp_requirements ||
          []

      display_contracts =
        Map.get(attrs, :display_contracts) ||
          Map.get(attrs, "display_contracts") ||
          %{}

      attrs =
        attrs
        |> Map.put_new(:plugin_id, manifest_struct.id)
        |> Map.put_new(:name, manifest_struct.name)
        |> Map.put_new(:version, manifest_struct.version)
        |> Map.put_new(:description, manifest_struct.description)
        |> Map.put_new(:entrypoint, manifest_struct.entrypoint)
        |> Map.put_new(:runtime, manifest_struct.runtime)
        |> Map.put_new(:outputs, manifest_struct.outputs)
        |> Map.put_new(:display_contract, display_contract)
        |> Map.put(:display_contracts, display_contracts)
        |> Map.put_new(:signal_schemas, signal_schemas)
        |> Map.put_new(:producer_schedules, producer_schedules)
        |> Map.put_new(:alert_rules, alert_rules)
        |> Map.put_new(:snmp_requirements, snmp_requirements)

      PluginPackage
      |> Ash.Changeset.for_create(:create, attrs)
      |> create_resource(ash_opts)
    else
      {:error, errors} when is_list(errors) ->
        {:error, {:invalid_manifest, errors}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp create_from_github(attrs, ash_opts) do
    with {:ok, import} <- GitHubImporter.fetch(attrs),
         {:ok, _plugin} <- ensure_plugin(import.manifest_struct, attrs, ash_opts),
         {:ok, package} <- create_github_package(import, attrs, ash_opts) do
      store_wasm_blob(package, import.wasm, import.content_hash, ash_opts)
    end
  end

  defp create_from_first_party(attrs, ash_opts) do
    with {:ok, import} <- FirstPartyImporter.import(attrs),
         {:ok, _plugin} <- ensure_plugin(import.manifest_struct, attrs, ash_opts),
         {:ok, package, store_blob?} <- create_first_party_package(import, attrs, ash_opts) do
      if store_blob? do
        store_wasm_blob(package, import.wasm, import.content_hash, ash_opts)
      else
        {:ok, package}
      end
    end
  end

  defp create_github_package(import, attrs, ash_opts) do
    attrs =
      attrs
      |> Map.drop([:repo_url, "repo_url", :release_tag, "release_tag"])
      |> Map.put(:manifest, import.manifest)
      |> Map.put_new(:config_schema, import.config_schema || %{})
      |> Map.put_new(:display_contract, import.display_contract || %{})
      |> put_default(:display_contracts, Map.get(import, :display_contracts) || %{})
      |> Map.put_new(:signal_schemas, import.manifest_struct.signal_schemas || [])
      |> Map.put_new(:producer_schedules, import.manifest_struct.producer_schedules || [])
      |> Map.put(:source_type, :github)
      |> Map.put(:source_commit, import.source_commit)
      |> Map.put(:signature, import.signature)
      |> Map.put(:gpg_verified_at, import.gpg_verified_at)
      |> Map.put(:gpg_key_id, import.gpg_key_id)
      |> Map.put(:content_hash, import.content_hash)

    attrs =
      attrs
      |> Map.put_new(:plugin_id, import.manifest_struct.id)
      |> Map.put_new(:name, import.manifest_struct.name)
      |> Map.put_new(:version, import.manifest_struct.version)
      |> Map.put_new(:description, import.manifest_struct.description)
      |> Map.put_new(:entrypoint, import.manifest_struct.entrypoint)
      |> Map.put_new(:runtime, import.manifest_struct.runtime)
      |> Map.put_new(:outputs, import.manifest_struct.outputs)

    PluginPackage
    |> Ash.Changeset.for_create(:create, attrs)
    |> create_resource(ash_opts)
  end

  defp create_first_party_package(import, attrs, ash_opts) do
    attrs =
      attrs
      |> Map.drop([
        :repo_url,
        "repo_url",
        :release_tag,
        "release_tag",
        :index_asset_name,
        "index_asset_name",
        :github_token,
        "github_token",
        :trusted_upload_signing_keys,
        "trusted_upload_signing_keys"
      ])
      |> Map.put(:manifest, import.manifest)
      |> Map.put_new(:config_schema, import.config_schema || %{})
      |> Map.put_new(:display_contract, import.display_contract || %{})
      |> put_default(:display_contracts, Map.get(import, :display_contracts) || %{})
      |> Map.put_new(:signal_schemas, import.manifest_struct.signal_schemas || [])
      |> Map.put_new(:producer_schedules, import.manifest_struct.producer_schedules || [])
      |> Map.put(:source_type, :first_party)
      |> Map.put(:source_repo_url, import.source_repo_url)
      |> Map.put(:source_release_tag, import.source_release_tag)
      |> Map.put(:source_oci_ref, import.source_oci_ref)
      |> Map.put(:source_oci_digest, import.source_oci_digest)
      |> Map.put(:source_bundle_digest, import.source_bundle_digest)
      |> Map.put(:source_metadata, import.source_metadata || %{})
      |> Map.put(:signature, import.signature)
      |> Map.put(:gpg_verified_at, import.imported_at)
      |> Map.put(:gpg_key_id, signer_from_signature(import.signature))
      |> Map.put(:imported_at, import.imported_at)
      |> Map.put(:verification_status, import.verification_status)
      |> Map.put(:verification_error, nil)
      |> Map.put(:content_hash, import.content_hash)

    attrs =
      attrs
      |> Map.put_new(:plugin_id, import.manifest_struct.id)
      |> Map.put_new(:name, import.manifest_struct.name)
      |> Map.put_new(:version, import.manifest_struct.version)
      |> Map.put_new(:description, import.manifest_struct.description)
      |> Map.put_new(:entrypoint, import.manifest_struct.entrypoint)
      |> Map.put_new(:runtime, import.manifest_struct.runtime)
      |> Map.put_new(:outputs, import.manifest_struct.outputs)

    case read_package_version(import.manifest_struct.id, import.manifest_struct.version, ash_opts) do
      {:ok, nil} ->
        with {:ok, package} <-
               PluginPackage
               |> Ash.Changeset.for_create(:create, attrs)
               |> create_resource(ash_opts) do
          {:ok, package, true}
        end

      {:ok, package} ->
        if same_first_party_artifact?(package, import) do
          {:ok, package, false}
        else
          replace_with_first_party_package(package, attrs, ash_opts)
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp replace_with_first_party_package(%PluginPackage{} = package, attrs, ash_opts) do
    attrs = Map.drop(attrs, [:plugin_id, "plugin_id", :version, "version"])

    package
    |> Ash.Changeset.for_update(:update, attrs)
    |> update_resource_with_opts(ash_opts)
    |> case do
      {:ok, updated} ->
        case ProducerScheduleCatalog.sync_package(updated, actor_opts(ash_opts)) do
          :ok -> {:ok, updated, true}
          {:error, error} -> {:error, error}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp store_wasm_blob(package, payload, content_hash, opts) do
    object_key = Storage.object_key_for(package)

    with :ok <- Storage.put_blob(object_key, payload),
         {:ok, updated} <-
           package
           |> Ash.Changeset.for_update(:update, %{
             wasm_object_key: object_key,
             content_hash: content_hash
           })
           |> update_resource_with_opts(opts) do
      mirror_plugin_artifact(updated, object_key, payload)
      {:ok, updated}
    end
  end

  defp store_wasm_blob_file(package, path, content_hash, opts) do
    object_key = Storage.object_key_for(package)

    with :ok <- Storage.put_blob_file(object_key, path),
         {:ok, updated} <-
           package
           |> Ash.Changeset.for_update(:update, %{
             wasm_object_key: object_key,
             content_hash: content_hash
           })
           |> update_resource_with_opts(opts) do
      mirror_plugin_artifact_from_storage(updated, object_key)
      {:ok, updated}
    end
  end

  # Mirror the plugin WASM into the datasvc `serviceradar-objects` read bucket so
  # agents (serviceradar_agent_gateway -> datasvc) can fetch it. web-ng only writes
  # to the `serviceradar_plugins` bucket, which datasvc cannot read, so without this
  # mirror the agent download fails with "object not found". Best-effort: a datasvc
  # outage must not fail the local blob write, which already succeeded.
  defp mirror_plugin_artifact(%PluginPackage{} = package, object_key, payload) when is_binary(payload) do
    if datasvc_mirror_available?() do
      case PluginArtifactMirror.mirror(object_key, payload, plugin_mirror_opts(package)) do
        {:ok, _key} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "plugin artifact datasvc mirror failed package_id=#{package.id} " <>
              "object_key=#{object_key} error=#{inspect(reason)}"
          )

          :ok
      end
    else
      Logger.debug(
        "plugin artifact datasvc mirror skipped (datasvc unavailable) " <>
          "package_id=#{package.id} object_key=#{object_key}"
      )

      :ok
    end
  end

  defp mirror_plugin_artifact(_package, _object_key, _payload), do: :ok

  defp mirror_plugin_artifact_from_storage(%PluginPackage{} = package, object_key) do
    case Storage.fetch_blob(object_key) do
      {:ok, {:binary, payload}} ->
        mirror_plugin_artifact(package, object_key, payload)

      _other ->
        Logger.debug(
          "plugin artifact datasvc mirror skipped (blob bytes unavailable) " <>
            "package_id=#{package.id} object_key=#{object_key}"
        )

        :ok
    end
  end

  defp plugin_mirror_opts(%PluginPackage{} = package) do
    attributes = %{
      "plugin_id" => to_string(package.plugin_id),
      "version" => to_string(package.version),
      "package_id" => to_string(package.id)
    }

    opts = [attributes: attributes]

    case Application.get_env(:serviceradar_web_ng, :plugin_artifact_upload) do
      upload when is_function(upload, 3) -> Keyword.put(opts, :upload_object, upload)
      _ -> opts
    end
  end

  # Skip the (cross-service) mirror when datasvc is not reachable so tests and
  # offline runs do not block on a gRPC connect. An injected upload function always
  # mirrors (it is the integration/test seam).
  defp datasvc_mirror_available? do
    case Application.get_env(:serviceradar_web_ng, :plugin_artifact_upload) do
      upload when is_function(upload, 3) -> true
      _ -> DataServiceClient.connected?()
    end
  end

  defp read_plugin(plugin_id, []) do
    Plugin
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(plugin_id == ^plugin_id)
    |> Ash.read_one()
  end

  defp read_plugin(plugin_id, ash_opts) do
    Plugin
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(plugin_id == ^plugin_id)
    |> Ash.read_one(ash_opts)
  end

  defp read(query, nil), do: Ash.read!(query)
  defp read(query, scope), do: Ash.read!(query, scope: scope)

  defp read_one_by_id(id, nil) do
    PluginPackage
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one()
  end

  defp read_one_by_id(id, scope) do
    PluginPackage
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one(scope: scope)
  end

  defp read_package_version(plugin_id, version, []) do
    PluginPackage
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(plugin_id == ^plugin_id and version == ^version)
    |> Ash.read_one()
  end

  defp read_package_version(plugin_id, version, ash_opts) do
    PluginPackage
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(plugin_id == ^plugin_id and version == ^version)
    |> Ash.read_one(ash_opts)
  end

  defp create_resource(changeset, []), do: Ash.create(changeset)
  defp create_resource(changeset, ash_opts), do: Ash.create(changeset, ash_opts)

  defp ash_opts(scope, actor) when not is_nil(scope) do
    maybe_put_actor([scope: scope], actor || scope_actor(scope))
  end

  defp ash_opts(_scope, actor) when not is_nil(actor), do: [actor: actor]
  defp ash_opts(_scope, _actor), do: []

  defp update_resource_with_opts(changeset, opts) do
    Ash.update(changeset, opts)
  end

  defp destroy_resource(changeset, nil), do: Ash.destroy(changeset)
  defp destroy_resource(changeset, scope), do: Ash.destroy(changeset, ash_opts(scope, nil))

  defp sync_northbound_actions({:ok, %PluginPackage{} = package}, :approved) do
    case PluginActionSync.sync_package(package) do
      {:ok, _result} -> {:ok, package}
      {:error, error} -> {:error, error}
    end
  end

  defp sync_northbound_actions({:ok, %PluginPackage{} = package}, :disabled) do
    case PluginActionSync.disable_package(package) do
      {:ok, _result} -> {:ok, package}
      {:error, error} -> {:error, error}
    end
  end

  defp sync_northbound_actions(other, _mode), do: other

  # Runs on the SAME transitions as the northbound action sync, and for the same
  # reason: a staged package's manifest has not been read by anyone, so nothing
  # it declares may reach the database until a human approves it.
  #
  # Rules are disabled rather than deleted on deny/revoke/restage. An operator
  # may have tuned thresholds on them, and re-approving should not silently lose
  # that work -- nor should a revoked plugin's rules keep firing.
  defp sync_alert_rules({:ok, %PluginPackage{} = package}, :approved) do
    case AlertRuleCatalog.sync_package(package) do
      :ok -> {:ok, package}
      {:error, error} -> {:error, error}
    end
  end

  defp sync_alert_rules({:ok, %PluginPackage{} = package}, :disabled) do
    case AlertRuleCatalog.disable_package_rules(package, []) do
      :ok -> {:ok, package}
      {:error, error} -> {:error, error}
    end
  end

  defp sync_alert_rules(other, _mode), do: other

  # Same transitions, same reason, and a stronger case than alert rules: an
  # approved SNMP requirement ultimately produces outbound UDP/161 traffic from
  # an agent to real inventory devices bearing real credentials.
  #
  # Profiles are disabled rather than deleted on deny/revoke/restage, for the
  # same reason rules are -- an operator may have bound a credential and
  # narrowed the target query, and re-approving must not lose that.
  defp sync_snmp_requirements({:ok, %PluginPackage{} = package}, :approved) do
    case SNMPRequirementCatalog.sync_package(package) do
      :ok -> {:ok, package}
      {:error, error} -> {:error, error}
    end
  end

  defp sync_snmp_requirements({:ok, %PluginPackage{} = package}, :disabled) do
    case SNMPRequirementCatalog.disable_package_snmp(package, []) do
      :ok -> {:ok, package}
      {:error, error} -> {:error, error}
    end
  end

  defp sync_snmp_requirements(other, _mode), do: other

  defp disable_assignments_for_package(%PluginPackage{} = package, ash_opts) do
    PackageAssignmentLifecycle.disable_for_package(package, actor_opts(ash_opts))
  end

  defp actor_opts(ash_opts) when is_list(ash_opts), do: Keyword.take(ash_opts, [:actor])

  defp maybe_put_actor(opts, nil), do: opts
  defp maybe_put_actor(opts, actor), do: Keyword.put(opts, :actor, actor)

  defp scope_actor(%{user: user, permissions: %MapSet{} = permissions}) when not is_nil(user) do
    user
    |> Map.take([:id, :email, :role, :role_profile_id])
    |> Map.put(:permissions, permissions)
  end

  defp scope_actor(%{user: user}) when not is_nil(user), do: user
  defp scope_actor(_scope), do: nil

  defp maybe_filter_plugin_id(query, filters) do
    plugin_id = Map.get(filters, :plugin_id) || Map.get(filters, "plugin_id")

    if is_binary(plugin_id) and plugin_id != "" do
      Ash.Query.filter(query, plugin_id == ^plugin_id)
    else
      query
    end
  end

  defp maybe_filter_status(query, filters) do
    statuses = Map.get(filters, :status) || Map.get(filters, "status")

    case normalize_list(statuses) do
      [] -> query
      list -> Ash.Query.filter(query, status in ^list)
    end
  end

  defp maybe_filter_source_type(query, filters) do
    source = Map.get(filters, :source_type) || Map.get(filters, "source_type")

    case normalize_list(source) do
      [] -> query
      list -> Ash.Query.filter(query, source_type in ^list)
    end
  end

  defp apply_manifest_defaults(attrs, manifest) do
    attrs
    |> maybe_put(
      :approved_capabilities,
      Map.get(manifest, "capabilities") || Map.get(manifest, :capabilities)
    )
    |> maybe_put(
      :approved_permissions,
      Map.get(manifest, "permissions") || Map.get(manifest, :permissions)
    )
    |> maybe_put(
      :approved_resources,
      Map.get(manifest, "resources") || Map.get(manifest, :resources)
    )
  end

  defp enforce_verification_policy(%PluginPackage{} = package) do
    policy = plugin_verification_policy()

    case package.source_type do
      :github -> enforce_github_policy(package, policy)
      # A first-party package names the catalog it came from, so it is verified
      # against that repository's key rather than a global map. An uploaded
      # package has no catalog -- the CLI and the admin upload form both land
      # here -- so it keeps the configured policy.
      :first_party -> enforce_upload_policy(package, repository_policy(package, policy))
      :upload -> enforce_upload_policy(package, policy)
      _ -> :ok
    end
  end

  # Falls back to the configured policy when the package's source is not a known
  # repository. That keeps packages imported before repositories became records
  # verifiable, and it is not a hole: an unknown source cannot widen trust, it
  # can only fall back to the same global map that governed every package
  # before this change.
  defp repository_policy(%PluginPackage{source_repo_url: repo_url}, policy) when is_binary(repo_url) do
    case Repositories.get_by_repo_url(repo_url) do
      {:ok, repository} ->
        case Repositories.trusted_keys(repository) do
          keys when map_size(keys) > 0 ->
            %{policy | trusted_upload_signing_keys: UploadSignature.normalize_trusted_keys(keys)}

          _ ->
            policy
        end

      {:error, _reason} ->
        policy
    end
  end

  defp repository_policy(_package, policy), do: policy

  defp enforce_github_policy(package, policy) do
    signer =
      package.signature
      |> signer_from_signature()
      |> case do
        nil -> package.gpg_key_id
        value -> value
      end
      |> normalize_signer()

    cond do
      not policy.require_gpg_for_github ->
        :ok

      is_nil(package.gpg_verified_at) ->
        {:error, :verification_required}

      policy.trusted_github_signers == [] ->
        {:error, :trusted_signers_not_configured}

      signer in policy.trusted_github_signers ->
        :ok

      true ->
        {:error, :untrusted_signer}
    end
  end

  defp enforce_upload_policy(package, policy) do
    cond do
      policy.allow_unsigned_uploads ->
        :ok

      policy.trusted_upload_signing_keys == %{} ->
        {:error, :trusted_upload_signers_not_configured}

      true ->
        UploadSignature.verify(
          package.signature,
          package.manifest || %{},
          package.content_hash || "",
          policy.trusted_upload_signing_keys
        )
    end
  end

  defp plugin_verification_policy do
    config = Application.get_env(:serviceradar_web_ng, :plugin_verification, [])

    %{
      require_gpg_for_github: Keyword.get(config, :require_gpg_for_github, false),
      allow_unsigned_uploads: Keyword.get(config, :allow_unsigned_uploads, true),
      trusted_upload_signing_keys:
        config
        |> Keyword.get(:trusted_upload_signing_keys, %{})
        |> UploadSignature.normalize_trusted_keys(),
      trusted_github_signers:
        config
        |> Keyword.get(:trusted_github_signers, [])
        |> Enum.map(&normalize_signer/1)
        |> Enum.reject(&is_nil/1)
    }
  end

  defp signer_from_signature(%{"signer" => signer}) when is_binary(signer), do: signer
  defp signer_from_signature(%{signer: signer}) when is_binary(signer), do: signer
  defp signer_from_signature(_signature), do: nil

  defp normalize_signer(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      signer -> String.downcase(signer)
    end
  end

  defp normalize_signer(_value), do: nil

  defp same_first_party_artifact?(%PluginPackage{} = package, import) do
    same_digest?(package.source_bundle_digest, import.source_bundle_digest) and
      same_optional_digest?(package.source_oci_digest, import.source_oci_digest)
  end

  defp same_optional_digest?(nil, _right), do: true
  defp same_optional_digest?(_left, nil), do: true
  defp same_optional_digest?(left, right), do: same_digest?(left, right)

  defp same_digest?(left, right) do
    normalize_digest(left) == normalize_digest(right) and not is_nil(normalize_digest(left))
  end

  defp normalize_digest(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.replace_prefix("sha256:", "")
    |> case do
      "" -> nil
      digest -> String.downcase(digest)
    end
  end

  defp normalize_digest(_value), do: nil

  defp maybe_put(attrs, _key, nil), do: attrs
  defp maybe_put(attrs, _key, value) when value == [], do: attrs
  defp maybe_put(attrs, _key, value) when value == %{}, do: attrs

  defp maybe_put(attrs, key, value) do
    case Map.get(attrs, key) do
      nil -> Map.put(attrs, key, value)
      [] -> Map.put(attrs, key, value)
      %{} = current when map_size(current) == 0 -> Map.put(attrs, key, value)
      _ -> attrs
    end
  end

  defp normalize_limit(nil), do: @default_limit
  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @max_limit)

  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(String.trim(limit)) do
      {parsed, ""} -> normalize_limit(parsed)
      _ -> @default_limit
    end
  end

  defp normalize_limit(_), do: @default_limit

  defp normalize_list(nil), do: []
  defp normalize_list(""), do: []

  defp normalize_list(list) when is_list(list) do
    list
    |> Enum.map(&normalize_status_value/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_list(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> normalize_list()
  end

  defp normalize_list(_), do: []

  defp normalize_status_value(value) when is_atom(value), do: value

  defp normalize_status_value(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      nil
    else
      try do
        String.to_existing_atom(trimmed)
      rescue
        ArgumentError -> nil
      end
    end
  end

  defp normalize_status_value(_), do: nil

  defp drop_nil_values(attrs) do
    attrs
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp normalize_source_type(nil), do: :upload
  defp normalize_source_type(""), do: :upload
  defp normalize_source_type(:upload), do: :upload
  defp normalize_source_type(:github), do: :github
  defp normalize_source_type(:first_party), do: :first_party

  defp normalize_source_type(value) when is_binary(value) do
    case String.trim(String.downcase(value)) do
      "github" -> :github
      "first_party" -> :first_party
      "first-party" -> :first_party
      "upload" -> :upload
      "" -> :upload
      _ -> :invalid
    end
  end

  defp normalize_source_type(_), do: :invalid
end
