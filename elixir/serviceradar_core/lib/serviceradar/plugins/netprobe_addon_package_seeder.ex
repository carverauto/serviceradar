defmodule ServiceRadar.Plugins.NetprobeAddonPackageSeeder do
  @moduledoc """
  Seeds the first-party netprobe native add-on package when artifact refs exist.

  The native add-on package must point at real mirrored, signed pushed-artifacts.
  Without configured artifacts this seeder is intentionally a no-op: approving a
  package with placeholder object keys would let operators assign something the
  agent cannot verify or fetch.
  """

  use ServiceRadar.DelayedSeeder, callback: :seed_defaults

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.AddonPackage

  require Ash.Query
  require Logger

  @addon_id "netprobe"
  @config_schema_path Path.expand(
                        "../../../../../addons/netprobe/config.schema.json",
                        __DIR__
                      )
  @external_resource @config_schema_path
  @config_schema @config_schema_path |> File.read!() |> Jason.decode!()

  # Version + capabilities track the in-image manifest, not a hardcoded constant, so a
  # manifest bump (e.g. 0.1.0 -> 0.2.0) surfaces to operators on the next boot instead of
  # freezing at a fixed version. Signed artifact refs still come from runtime config; an
  # operator-facing config :version override still wins (see package_attrs/2).
  @manifest_path Path.expand("../../../../../addons/netprobe/addon.yaml", __DIR__)
  @external_resource @manifest_path
  @manifest @manifest_path |> File.read!() |> YamlElixir.read_from_string!()
  @version Map.get(@manifest, "version", "0.1.0")
  @capabilities Map.get(@manifest, "capabilities", ["host-network-visibility"])

  @spec seed_defaults(keyword()) :: :ok | {:error, term()}
  def seed_defaults(opts \\ []) do
    config =
      :serviceradar_core
      |> Application.get_env(:netprobe_native_addon_package, [])
      |> Keyword.merge(opts)

    actor = SystemActor.system(:netprobe_addon_package_seeder)

    case normalize_artifacts(Keyword.get(config, :artifacts, %{})) do
      {:ok, artifacts} when map_size(artifacts) > 0 ->
        # Verified signed artifacts present: seed + approve so the package is assignable.
        ensure_package(config, artifacts, actor, approve?: true)

      {:ok, _empty} ->
        # No signed artifacts yet: still surface the manifest version + config schema as a
        # STAGED (visible, not assignable) package, so operators see the current add-on and
        # its one-touch config instead of a silently frozen prior version.
        Logger.info(
          "Seeding netprobe native add-on package as staged (no signed artifacts configured yet)"
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
        Logger.warning("Failed to check netprobe add-on package seed: #{inspect(reason)}")
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
      Logger.info("Seeded netprobe native add-on package",
        version: attrs.version,
        approved: approve?
      )

      :ok
    else
      {:error, reason} ->
        Logger.warning("Failed to seed netprobe add-on package: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp update_package(%AddonPackage{} = package, attrs, approve?, opts) do
    with {:ok, package} <- restage_if_needed(package, opts),
         {:ok, package} <-
           package
           |> Ash.Changeset.for_update(:update, Map.drop(attrs, [:addon_id, :version]), opts)
           |> Ash.update(opts),
         {:ok, _package} <- maybe_approve(package, approve?, opts) do
      Logger.debug("netprobe native add-on package seed is current",
        version: attrs.version,
        approved: approve?
      )

      :ok
    else
      {:error, reason} ->
        Logger.warning("Failed to update netprobe add-on package seed: #{inspect(reason)}")
        {:error, reason}
    end
  end

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
        approved_by: "system:netprobe_addon_package_seeder"
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
      name: "Host Network Visibility (netprobe)",
      description:
        "Capability-granted long-running daemon for passive p0f/JA4 fingerprinting, " <>
          "DPI, eBPF process attribution, and flow visibility, delivered as a signed " <>
          "pushed-artifact add-on carved out of the base agent.",
      kind: :native,
      delivery: :pushed_artifact,
      supervision: :systemd_service,
      binary: "serviceradar-netprobe",
      install_path: "/usr/local/lib/serviceradar/bin",
      capabilities: @capabilities,
      config_schema: @config_schema,
      artifacts: artifacts,
      requires: %{
        "base_agent" => ">=1.2.0",
        "platforms" => ["linux"],
        "os_capabilities" => ["CAP_NET_RAW", "CAP_BPF", "CAP_PERFMON"],
        "run_as" => "serviceradar"
      },
      source_type: :first_party,
      source_oci_ref: Keyword.get(config, :source_oci_ref),
      source_oci_digest: Keyword.get(config, :source_oci_digest),
      source_release_tag: Keyword.get(config, :source_release_tag),
      source_metadata: %{
        "native_addon_inventory" => "netprobe_addon_bundle",
        "seeded_by" => "ServiceRadar.Plugins.NetprobeAddonPackageSeeder"
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

  defp normalize_artifacts(_artifacts), do: {:error, :invalid_netprobe_addon_artifacts}

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
