defmodule ServiceRadar.Plugins.OtelCollectorAddonPackageSeeder do
  @moduledoc """
  Seeds the first-party otel-collector native add-on package when artifact refs exist.

  The native add-on package must point at real mirrored, signed pushed-artifacts.
  Without configured artifacts this seeder stages a visible (not assignable)
  package so operators see the current add-on + its one-touch config instead of
  the recurring "no approved package is available" warning. Approving a package
  with placeholder object keys would let operators assign something the agent
  cannot verify or fetch, so approval is gated on real artifacts.
  """

  use ServiceRadar.DelayedSeeder, callback: :seed_defaults

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.AddonPackage

  require Ash.Query
  require Logger

  @addon_id "otel-collector"
  @config_schema_path Path.expand(
                        "../../../../../addons/otel-collector/config.schema.json",
                        __DIR__
                      )
  @external_resource @config_schema_path
  @config_schema @config_schema_path |> File.read!() |> Jason.decode!()

  # Version + capabilities track the in-image manifest, not a hardcoded constant, so a
  # manifest bump (e.g. 0.1.0 -> 0.2.0) surfaces to operators on the next boot instead of
  # freezing at a fixed version. Signed artifact refs still come from runtime config; an
  # operator-facing config :version override still wins (see package_attrs/2).
  @manifest_path Path.expand("../../../../../addons/otel-collector/addon.yaml", __DIR__)
  @external_resource @manifest_path
  @manifest @manifest_path |> File.read!() |> YamlElixir.read_from_string!()
  @version Map.get(@manifest, "version", "0.1.0")
  @capabilities Map.get(@manifest, "capabilities", ["otlp-relay:v1", "native-telemetry:v1"])

  @spec seed_defaults(keyword()) :: :ok | {:error, term()}
  def seed_defaults(opts \\ []) do
    config =
      :serviceradar_core
      |> Application.get_env(:otel_collector_native_addon_package, [])
      |> Keyword.merge(opts)

    actor = SystemActor.system(:otel_collector_addon_package_seeder)

    case normalize_artifacts(Keyword.get(config, :artifacts, %{})) do
      {:ok, artifacts} when map_size(artifacts) > 0 ->
        # Verified signed artifacts present: seed + approve so the package is assignable.
        ensure_package(config, artifacts, actor, approve?: true)

      {:ok, _empty} ->
        # No signed artifacts yet: still surface the manifest version + config schema as a
        # STAGED (visible, not assignable) package, so operators see the current add-on and
        # its one-touch config instead of a silently frozen prior version.
        Logger.info(
          "Seeding otel-collector native add-on package as staged (no signed artifacts configured yet)"
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
      {:ok, nil} ->
        create_package(attrs, approve?, opts)

      {:ok, %AddonPackage{} = package} ->
        update_package(package, attrs, approve?, opts)

      {:error, reason} ->
        Logger.warning("Failed to check otel-collector add-on package seed: #{inspect(reason)}")
        {:error, reason}
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
      Logger.info("Seeded otel-collector native add-on package",
        version: attrs.version,
        approved: approve?
      )

      :ok
    else
      {:error, reason} ->
        Logger.warning("Failed to seed otel-collector add-on package: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp update_package(%AddonPackage{} = package, attrs, approve?, opts) do
    # An existing package that already carries non-empty artifacts was imported/mirrored
    # (and likely verified/approved) out-of-band by the importer. The manifest-driven
    # seeder must NOT clobber those mirrored artifacts with its own (often empty) runtime
    # config, nor downgrade the package status by re-staging it. In that case we keep the
    # imported artifacts + status untouched and, at most, refresh the config_schema so the
    # operator-facing one-touch config tracks the in-image manifest.
    imported? = imported_with_artifacts?(package)
    update_attrs = update_attrs(attrs, imported?)

    with {:ok, package} <- maybe_restage(package, imported?, opts),
         {:ok, package} <-
           package
           |> Ash.Changeset.for_update(:update, update_attrs, opts)
           |> Ash.update(opts),
         {:ok, _package} <- maybe_approve(package, approve? and not imported?, opts) do
      Logger.debug("otel-collector native add-on package seed is current",
        version: attrs.version,
        approved: approve? and not imported?,
        imported: imported?
      )

      :ok
    else
      {:error, reason} ->
        Logger.warning("Failed to update otel-collector add-on package seed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # True when the existing package already carries mirrored artifacts (imported/verified
  # out-of-band). map_size guards against the seeder's default empty %{} artifacts.
  defp imported_with_artifacts?(%AddonPackage{artifacts: artifacts})
       when is_map(artifacts) and map_size(artifacts) > 0,
       do: true

  defp imported_with_artifacts?(_package), do: false

  # For an imported package, only the config_schema may be refreshed; artifacts and every
  # other attribute (status-affecting or otherwise) are left as the importer set them. For
  # a seeder-owned package, update the full attribute set as before.
  defp update_attrs(attrs, true), do: Map.take(attrs, [:config_schema])
  defp update_attrs(attrs, false), do: Map.drop(attrs, [:addon_id, :version])

  # Never re-stage (which would downgrade status) a package the importer already populated.
  defp maybe_restage(package, true, _opts), do: {:ok, package}
  defp maybe_restage(package, false, opts), do: restage_if_needed(package, opts)

  defp maybe_approve(package, true, opts), do: approve_if_needed(package, opts)
  defp maybe_approve(package, false, _opts), do: {:ok, package}

  defp restage_if_needed(%AddonPackage{status: status} = package, _opts)
       when status in [:staged, :approved],
       do: {:ok, package}

  defp restage_if_needed(%AddonPackage{} = package, opts) do
    package
    |> Ash.Changeset.for_update(:restage, %{}, opts)
    |> Ash.update(opts)
  end

  defp approve_if_needed(%AddonPackage{status: :approved} = package, _opts), do: {:ok, package}
  defp approve_if_needed(%AddonPackage{} = package, opts), do: approve(package, opts)

  defp approve(%AddonPackage{} = package, opts) do
    package
    |> Ash.Changeset.for_update(
      :approve,
      %{
        approved_capabilities: @capabilities,
        approved_by: "system:otel_collector_addon_package_seeder"
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
      name: "OTEL Collector Add-on",
      description:
        "Edge OpenTelemetry collector for ServiceRadar. Accepts OTLP traces, logs, " <>
          "and metrics on local gRPC/HTTP listeners, spools them durably on disk, and " <>
          "relays them to the supervising agent over the acked otlp-relay:v1 stream, " <>
          "delivered as a signed pushed-artifact agent-sidecar add-on.",
      kind: :native,
      delivery: :pushed_artifact,
      supervision: :agent_sidecar,
      binary: "serviceradar-otel-addon",
      install_path: "/usr/local/lib/serviceradar/bin",
      capabilities: @capabilities,
      config_schema: @config_schema,
      artifacts: artifacts,
      requires: %{
        "base_agent" => ">=1.2.0",
        "platforms" => ["linux"],
        "os_capabilities" => [],
        "run_as" => "serviceradar"
      },
      source_type: :first_party,
      source_oci_ref: Keyword.get(config, :source_oci_ref),
      source_oci_digest: Keyword.get(config, :source_oci_digest),
      source_release_tag: Keyword.get(config, :source_release_tag),
      source_metadata: %{
        "native_addon_inventory" => "otel_collector_addon_bundle",
        "seeded_by" => "ServiceRadar.Plugins.OtelCollectorAddonPackageSeeder"
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

  defp normalize_artifacts(_artifacts), do: {:error, :invalid_otel_collector_addon_artifacts}

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

  defp string_entry(map, key) do
    case Map.get(map, key) || Map.get(map, atom_key(key)) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp atom_key("object_key"), do: :object_key
  defp atom_key("sha256"), do: :sha256
  defp atom_key("signature"), do: :signature

  defp sha256?(value) when is_binary(value), do: Regex.match?(~r/^[A-Fa-f0-9]{64}$/, value)
  defp sha256?(_value), do: false
end
