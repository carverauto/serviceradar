defmodule ServiceRadar.Plugins.BumblebeeAddonPackageSeeder do
  @moduledoc """
  Seeds the first-party Bumblebee native add-on package when artifact refs exist.

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

  @addon_id "bumblebee"
  @version "0.1.2"
  @capabilities ["exposure-scan"]
  @config_schema_path Path.expand(
                        "../../../../../addons/bumblebee-scan/config.schema.json",
                        __DIR__
                      )
  @external_resource @config_schema_path
  @config_schema @config_schema_path |> File.read!() |> Jason.decode!()

  @spec seed_defaults(keyword()) :: :ok | {:error, term()}
  def seed_defaults(opts \\ []) do
    config =
      :serviceradar_core
      |> Application.get_env(:bumblebee_native_addon_package, [])
      |> Keyword.merge(opts)

    case normalize_artifacts(Keyword.get(config, :artifacts, %{})) do
      {:ok, artifacts} when map_size(artifacts) > 0 ->
        actor = SystemActor.system(:bumblebee_addon_package_seeder)
        ensure_package(config, artifacts, actor)

      {:ok, _empty} ->
        Logger.debug("Skipping Bumblebee native add-on package seed: no artifacts configured")
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp ensure_package(config, artifacts, actor) do
    attrs = package_attrs(config, artifacts)
    opts = [actor: actor]

    case find_package(attrs.addon_id, attrs.version, opts) do
      {:ok, nil} ->
        create_and_approve(attrs, opts)

      {:ok, %AddonPackage{} = package} ->
        update_and_approve(package, attrs, opts)

      {:error, reason} ->
        Logger.warning("Failed to check Bumblebee add-on package seed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp find_package(addon_id, version, opts) do
    AddonPackage
    |> Ash.Query.for_read(:read, %{}, opts)
    |> Ash.Query.filter(addon_id == ^addon_id and version == ^version)
    |> Ash.read_one(opts)
  end

  defp create_and_approve(attrs, opts) do
    with {:ok, package} <-
           AddonPackage
           |> Ash.Changeset.for_create(:create, attrs, opts)
           |> Ash.create(opts),
         {:ok, _approved} <- approve(package, opts) do
      Logger.info("Seeded approved Bumblebee native add-on package", version: attrs.version)
      :ok
    else
      {:error, reason} ->
        Logger.warning("Failed to seed Bumblebee add-on package: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp update_and_approve(%AddonPackage{} = package, attrs, opts) do
    with {:ok, package} <- restage_if_needed(package, opts),
         {:ok, package} <-
           package
           |> Ash.Changeset.for_update(:update, Map.drop(attrs, [:addon_id, :version]), opts)
           |> Ash.update(opts),
         {:ok, _approved} <- approve_if_needed(package, opts) do
      Logger.debug("Bumblebee native add-on package seed is current", version: attrs.version)
      :ok
    else
      {:error, reason} ->
        Logger.warning("Failed to update Bumblebee add-on package seed: #{inspect(reason)}")
        {:error, reason}
    end
  end

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
        approved_by: "system:bumblebee_addon_package_seeder"
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
      name: "Bumblebee Exposure Scanner",
      description:
        "Root-owned systemd-timer scanner for local package and developer exposure findings.",
      kind: :native,
      delivery: :pushed_artifact,
      supervision: :systemd_timer,
      binary: "serviceradar-bumblebee-scan",
      install_path: "/usr/local/lib/serviceradar/bin",
      capabilities: @capabilities,
      config_schema: @config_schema,
      artifacts: artifacts,
      requires: %{
        "base_agent" => ">=1.2.0",
        "platforms" => ["linux"],
        "os_capabilities" => [],
        "run_as" => "root"
      },
      source_type: :first_party,
      source_oci_ref: Keyword.get(config, :source_oci_ref),
      source_oci_digest: Keyword.get(config, :source_oci_digest),
      source_release_tag: Keyword.get(config, :source_release_tag),
      source_metadata: %{
        "native_addon_inventory" => "bumblebee_scan_addon_bundle",
        "seeded_by" => "ServiceRadar.Plugins.BumblebeeAddonPackageSeeder"
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

  defp normalize_artifacts(_artifacts), do: {:error, :invalid_bumblebee_addon_artifacts}

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
