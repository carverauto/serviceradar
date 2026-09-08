defmodule ServiceRadar.Plugins.EndpointInventoryAddonPackageSeeder do
  @moduledoc """
  Seeds the first-party ScaLibr endpoint inventory native add-on package.

  Without signed artifacts this stages a visible, non-assignable package. Release
  import later replaces it with mirrored artifacts and approval.
  """

  use ServiceRadar.DelayedSeeder, callback: :seed_defaults

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.AddonPackage

  require Ash.Query
  require Logger

  @addon_id "scalibr-endpoint-inventory"
  @config_schema_path Path.expand(
                        "../../../../../addons/scalibr-endpoint-inventory/config.schema.json",
                        __DIR__
                      )
  @external_resource @config_schema_path
  @config_schema @config_schema_path |> File.read!() |> Jason.decode!()

  @manifest_path Path.expand(
                   "../../../../../addons/scalibr-endpoint-inventory/addon.yaml",
                   __DIR__
                 )
  @external_resource @manifest_path
  @manifest @manifest_path |> File.read!() |> YamlElixir.read_from_string!()
  @version Map.get(@manifest, "version", "0.1.0")
  @capabilities Map.get(@manifest, "capabilities", ["endpoint-inventory"])
  @requires Map.get(@manifest, "requires", %{})
  @exec Map.get(@manifest, "exec", %{})

  @spec seed_defaults(keyword()) :: :ok | {:error, term()}
  def seed_defaults(opts \\ []) do
    config =
      :serviceradar_core
      |> Application.get_env(:endpoint_inventory_native_addon_package, [])
      |> Keyword.merge(opts)

    actor = SystemActor.system(:endpoint_inventory_addon_package_seeder)

    case normalize_artifacts(Keyword.get(config, :artifacts, %{})) do
      {:ok, artifacts} when map_size(artifacts) > 0 ->
        ensure_package(config, artifacts, actor, approve?: true)

      {:ok, _empty} ->
        Logger.info(
          "Seeding endpoint inventory native add-on package as staged (no signed artifacts configured yet)"
        )

        ensure_package(config, %{}, actor, approve?: false)

      {:error, _reason} = error ->
        error
    end
  end

  defp ensure_package(config, artifacts, actor, seed_opts) do
    approve? = Keyword.get(seed_opts, :approve?, true)
    attrs = package_attrs(config, artifacts)
    opts = [actor: actor]

    case find_package(attrs.addon_id, attrs.version, opts) do
      {:ok, nil} -> create_package(attrs, approve?, opts)
      {:ok, %AddonPackage{} = package} -> update_package(package, attrs, approve?, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp find_package(addon_id, version, opts) do
    AddonPackage
    |> Ash.Query.for_read(:read, %{}, opts)
    |> Ash.Query.filter(addon_id == ^addon_id and version == ^version)
    |> Ash.read_one(opts)
  end

  defp create_package(attrs, approve?, opts) do
    with {:ok, package} <-
           AddonPackage
           |> Ash.Changeset.for_create(:create, attrs, opts)
           |> Ash.create(opts),
         {:ok, _package} <- maybe_approve(package, approve?, opts) do
      Logger.info("Seeded endpoint inventory native add-on package",
        version: attrs.version,
        approved: approve?
      )

      :ok
    end
  end

  defp update_package(%AddonPackage{} = package, attrs, approve?, opts) do
    imported? = imported_with_artifacts?(package)

    update_attrs =
      if imported?,
        do: Map.take(attrs, [:config_schema]),
        else: Map.drop(attrs, [:addon_id, :version])

    with {:ok, package} <- maybe_restage(package, imported?, opts),
         {:ok, package} <-
           package
           |> Ash.Changeset.for_update(:update, update_attrs, opts)
           |> Ash.update(opts),
         {:ok, _package} <- maybe_approve(package, approve? and not imported?, opts) do
      :ok
    end
  end

  defp imported_with_artifacts?(%AddonPackage{artifacts: artifacts})
       when is_map(artifacts) and map_size(artifacts) > 0,
       do: true

  defp imported_with_artifacts?(_package), do: false

  defp maybe_restage(package, true, _opts), do: {:ok, package}

  defp maybe_restage(%AddonPackage{status: status} = package, false, _opts)
       when status in [:staged, :approved],
       do: {:ok, package}

  defp maybe_restage(%AddonPackage{} = package, false, opts) do
    package
    |> Ash.Changeset.for_update(:restage, %{}, opts)
    |> Ash.update(opts)
  end

  defp maybe_approve(package, true, opts), do: approve_if_needed(package, opts)
  defp maybe_approve(package, false, _opts), do: {:ok, package}

  defp approve_if_needed(%AddonPackage{status: :approved} = package, _opts), do: {:ok, package}

  defp approve_if_needed(%AddonPackage{} = package, opts) do
    package
    |> Ash.Changeset.for_update(
      :approve,
      %{
        approved_capabilities: @capabilities,
        approved_by: "system:endpoint_inventory_addon_package_seeder"
      },
      opts
    )
    |> Ash.update(opts)
  end

  defp package_attrs(config, artifacts) do
    version = Keyword.get(config, :version, @version)

    %{
      addon_id: @addon_id,
      version: version,
      name: Map.get(@manifest, "name", "ScaLibr Endpoint Software Inventory"),
      description: Map.get(@manifest, "description"),
      kind: :native,
      delivery: :pushed_artifact,
      supervision: :systemd_timer,
      binary: Map.get(@exec, "binary", "serviceradar-scalibr-endpoint-inventory"),
      install_path: Map.get(@exec, "install_path", "/usr/local/lib/serviceradar/bin"),
      capabilities: @capabilities,
      config_schema: @config_schema,
      artifacts: artifacts,
      requires: @requires,
      source_type: :first_party,
      source_oci_ref: Keyword.get(config, :source_oci_ref),
      source_oci_digest: Keyword.get(config, :source_oci_digest),
      source_release_tag: Keyword.get(config, :source_release_tag),
      source_metadata: %{
        "native_addon_inventory" => "scalibr_endpoint_inventory_addon_bundle",
        "seeded_by" => "ServiceRadar.Plugins.EndpointInventoryAddonPackageSeeder"
      },
      imported_at: DateTime.truncate(DateTime.utc_now(), :second),
      verification_status: "seeded"
    }
  end

  defp normalize_artifacts(artifacts) when is_map(artifacts) do
    Enum.reduce_while(artifacts, {:ok, %{}}, fn {platform, entry}, {:ok, acc} ->
      case normalize_artifact_entry(platform, entry) do
        {:ok, key, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp normalize_artifacts(_artifacts), do: {:error, :invalid_endpoint_inventory_addon_artifacts}

  defp normalize_artifact_entry(platform, entry) when is_map(entry) do
    key = to_string(platform)
    object_key = string_entry(entry, "object_key")
    sha256 = string_entry(entry, "sha256")
    signature = string_entry(entry, "signature")

    cond do
      key == "" or not String.contains?(key, "/") ->
        {:error, {:invalid_artifact_platform, platform}}

      object_key in [nil, ""] ->
        {:error, {:invalid_artifact_object_key, platform}}

      not sha256?(sha256) ->
        {:error, {:invalid_artifact_sha256, platform}}

      signature in [nil, ""] ->
        {:error, {:invalid_artifact_signature, platform}}

      true ->
        {:ok, key,
         %{
           "object_key" => object_key,
           "sha256" => String.downcase(sha256),
           "signature" => signature
         }}
    end
  end

  defp normalize_artifact_entry(platform, _entry),
    do: {:error, {:invalid_artifact_entry, platform}}

  defp string_entry(map, key), do: map |> Map.get(key) |> to_string_or_nil()

  defp to_string_or_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp to_string_or_nil(_value), do: nil

  defp sha256?(value), do: is_binary(value) and value =~ ~r/^[0-9a-fA-F]{64}$/
end
