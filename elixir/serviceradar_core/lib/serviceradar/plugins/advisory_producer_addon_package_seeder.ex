defmodule ServiceRadar.Plugins.AdvisoryProducerAddonPackageSeeder do
  @moduledoc """
  Seeds the first-party advisory producer native add-on package when artifact refs exist.

  The add-on owns provider-specific download and normalization for CISA KEV,
  NVD CVE 2.0, and VulnCheck feeds while emitting the generic advisory-feed
  contract consumed by core.
  """

  use ServiceRadar.DelayedSeeder, callback: :seed_defaults

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.AddonPackage

  require Ash.Query
  require Logger

  @addon_id "advisory-producer"
  @version "0.1.0"
  @capabilities ["advisory-feed:v1", "producer-schedule:v1", "artifact-staging:v1"]
  @config_schema %{
    "title" => "Advisory Producer Configuration",
    "type" => "object",
    "properties" => %{
      "provider" => %{
        "type" => "string",
        "enum" => ["cisa", "nvd", "vulncheck"],
        "description" => "Default provider for manual command invocations"
      },
      "feed_key" => %{"type" => "string", "description" => "Default logical feed key"},
      "url" => %{"type" => "string", "format" => "uri", "description" => "Provider API URL"},
      "api_key" => %{"type" => "string", "description" => "NVD API key material"},
      "api_token" => %{"type" => "string", "description" => "VulnCheck API token material"}
    },
    "additionalProperties" => false
  }

  @producer_schedules [
    %{
      "schedule_id" => "cisa_kev.refresh",
      "label" => "Refresh CISA KEV",
      "description" =>
        "Download the CISA Known Exploited Vulnerabilities catalog and emit normalized advisory records.",
      "action_id" => "cisa_kev.refresh",
      "command_type" => "addon.run_command",
      "default_cadence_seconds" => 21_600,
      "min_cadence_seconds" => 300,
      "max_cadence_seconds" => 2_592_000,
      "schedule_type" => "interval",
      "jitter_seconds" => 300,
      "dispatch_scope" => "assignment",
      "timeout_seconds" => 900,
      "settings_schema" => %{
        "type" => "object",
        "properties" => %{
          "url" => %{
            "type" => "string",
            "title" => "Catalog URL",
            "default" =>
              "https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json"
          }
        }
      }
    },
    %{
      "schedule_id" => "nvd_cve.refresh",
      "label" => "Refresh NVD CVE 2.0",
      "description" =>
        "Download NVD CVE 2.0 data and emit CPE-backed normalized advisory records.",
      "action_id" => "nvd_cve.refresh",
      "command_type" => "addon.run_command",
      "default_cadence_seconds" => 86_400,
      "min_cadence_seconds" => 3_600,
      "max_cadence_seconds" => 2_592_000,
      "schedule_type" => "interval",
      "jitter_seconds" => 900,
      "dispatch_scope" => "assignment",
      "timeout_seconds" => 1_800,
      "settings_schema" => %{
        "type" => "object",
        "properties" => %{
          "url" => %{
            "type" => "string",
            "title" => "NVD API URL",
            "default" => "https://services.nvd.nist.gov/rest/json/cves/2.0"
          }
        }
      },
      "credential_requirements" => %{
        "api_key" => %{
          "required" => false,
          "description" => "Optional NVD API key credential ref for higher API limits"
        }
      },
      "redaction" => %{"fields" => ["credential_refs.api_key", "input_values.api_key"]}
    },
    %{
      "schedule_id" => "vulncheck.refresh",
      "label" => "Refresh VulnCheck",
      "description" =>
        "Download VulnCheck KEV/NVD-enriched data and emit PURL/CPE normalized advisory records.",
      "action_id" => "vulncheck.refresh",
      "command_type" => "addon.run_command",
      "default_cadence_seconds" => 43_200,
      "min_cadence_seconds" => 3_600,
      "max_cadence_seconds" => 2_592_000,
      "schedule_type" => "interval",
      "jitter_seconds" => 900,
      "dispatch_scope" => "assignment",
      "timeout_seconds" => 1_800,
      "settings_schema" => %{
        "type" => "object",
        "properties" => %{
          "url" => %{
            "type" => "string",
            "title" => "VulnCheck API URL",
            "description" => "VulnCheck feed endpoint for KEV/NVD-enriched records"
          }
        },
        "required" => ["url"]
      },
      "credential_requirements" => %{
        "api_token" => %{
          "required" => true,
          "description" => "VulnCheck API token credential ref"
        }
      },
      "redaction" => %{"fields" => ["credential_refs.api_token", "input_values.api_token"]}
    }
  ]

  @spec seed_defaults(keyword()) :: :ok | {:error, term()}
  def seed_defaults(opts \\ []) do
    config =
      :serviceradar_core
      |> Application.get_env(:advisory_producer_native_addon_package, [])
      |> Keyword.merge(opts)

    case normalize_artifacts(Keyword.get(config, :artifacts, %{})) do
      {:ok, artifacts} when map_size(artifacts) > 0 ->
        actor = SystemActor.system(:advisory_producer_addon_package_seeder)
        ensure_package(config, artifacts, actor)

      {:ok, _empty} ->
        Logger.debug(
          "Skipping advisory producer native add-on package seed: no artifacts configured"
        )

        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp ensure_package(config, artifacts, actor) do
    attrs = package_attrs(config, artifacts)
    opts = [actor: actor]

    case find_package(attrs.addon_id, attrs.version, opts) do
      {:ok, nil} -> create_and_approve(attrs, opts)
      {:ok, %AddonPackage{} = package} -> update_and_approve(package, attrs, opts)
      {:error, reason} -> {:error, reason}
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
      Logger.info("Seeded approved advisory producer native add-on package",
        version: attrs.version
      )

      :ok
    else
      {:error, reason} ->
        Logger.warning("Failed to seed advisory producer add-on package: #{inspect(reason)}")
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
      Logger.debug("Advisory producer native add-on package seed is current",
        version: attrs.version
      )

      :ok
    else
      {:error, reason} ->
        Logger.warning("Failed to update advisory producer add-on package: #{inspect(reason)}")
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
        approved_by: "system:advisory_producer_addon_package_seeder"
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
      name: "Advisory Feed Producer",
      description:
        "First-party native producer for CISA KEV, NVD CVE 2.0, and VulnCheck advisory feeds.",
      kind: :native,
      delivery: :pushed_artifact,
      supervision: :agent_sidecar,
      binary: "serviceradar-advisory-producer",
      install_path: "/usr/local/lib/serviceradar/bin",
      capabilities: @capabilities,
      config_schema: @config_schema,
      producer_schedules: @producer_schedules,
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
        "native_addon_inventory" => "advisory_producer_addon_bundle",
        "seeded_by" => "ServiceRadar.Plugins.AdvisoryProducerAddonPackageSeeder"
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

  defp normalize_artifacts(_artifacts), do: {:error, :invalid_advisory_producer_addon_artifacts}

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

  defp atom_key(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp sha256?(value) when is_binary(value) do
    value =~ ~r/\A[0-9a-fA-F]{64}\z/
  end

  defp sha256?(_value), do: false
end
