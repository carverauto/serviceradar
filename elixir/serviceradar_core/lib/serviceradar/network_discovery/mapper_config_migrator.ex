defmodule ServiceRadar.NetworkDiscovery.MapperConfigMigrator do
  @moduledoc """
  One-time migration helper to import legacy mapper KV config into Ash resources.
  """

  require Logger
  require Ash.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.DataService.Client
  alias ServiceRadar.NetworkDiscovery.{
    MapperJob,
    MapperSeed,
    MapperSNMPCredential,
    MapperUnifiController
  }

  @kv_key "config/mapper.json"

  @spec migrate_from_kv(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def migrate_from_kv(opts \\ []) do
    actor = opts[:actor] || SystemActor.system(:mapper_config_migrator)

    with {:ok, raw} <- Client.get(@kv_key),
         {:ok, config} <- Jason.decode(raw) do
      migrate_config(config, actor)
    else
      {:error, :not_found} -> {:ok, 0}
      {:error, reason} -> {:error, reason}
    end
  end

  defp migrate_config(config, actor) do
    jobs = Map.get(config, "scheduled_jobs", [])
    unifi_apis = Map.get(config, "unifi_apis", [])

    migrated_count =
      Enum.reduce(jobs, 0, fn job, acc ->
        case ensure_job(job, unifi_apis, actor) do
          {:ok, :created} -> acc + 1
          {:ok, :skipped} -> acc
          {:error, reason} ->
            Logger.warning("Mapper KV migration: job skipped due to error #{inspect(reason)}")
            acc
        end
      end)

    {:ok, migrated_count}
  end

  defp ensure_job(job, unifi_apis, actor) do
    name = Map.get(job, "name", "")

    if name == "" do
      {:error, :missing_name}
    else
      case find_job(name, actor) do
        {:ok, nil} ->
          create_job(job, unifi_apis, actor)

        {:ok, _existing} ->
          Logger.info("Mapper KV migration: job already exists, skipping", name: name)
          {:ok, :skipped}
      end
    end
  end

  defp find_job(name, actor) do
    jobs =
      MapperJob
      |> Ash.Query.filter(name == ^name)
      |> Ash.Query.limit(1)
      |> Ash.read(actor: actor)

    case jobs do
      {:ok, [job | _]} -> {:ok, job}
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_job(job, unifi_apis, actor) do
    attrs = %{
      name: Map.get(job, "name"),
      enabled: Map.get(job, "enabled", true),
      interval: Map.get(job, "interval", "2h"),
      discovery_type: parse_atom(Map.get(job, "type", "full")),
      discovery_mode: discovery_mode_for(unifi_apis),
      concurrency: Map.get(job, "concurrency", 10),
      timeout: Map.get(job, "timeout", "45s"),
      retries: Map.get(job, "retries", 2),
      options: Map.get(job, "options", %{})
    }

    changeset = Ash.Changeset.for_create(MapperJob, :create, attrs, actor: actor)

    case Ash.create(changeset, actor: actor) do
      {:ok, record} ->
        with {:ok, _} <- create_seeds(record, job, actor),
             {:ok, _} <- create_snmp_credential(record, job, actor),
             {:ok, _} <- create_unifi_controllers(record, unifi_apis, actor) do
          {:ok, :created}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_seeds(job_record, job, actor) do
    seeds = Map.get(job, "seeds", [])

    Enum.reduce_while(seeds, {:ok, 0}, fn seed, {:ok, count} ->
      attrs = %{seed: seed, mapper_job_id: job_record.id}
      changeset = Ash.Changeset.for_create(MapperSeed, :create, attrs, actor: actor)

      case Ash.create(changeset, actor: actor) do
        {:ok, _} -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp create_snmp_credential(job_record, job, actor) do
    credentials = Map.get(job, "credentials")

    if is_map(credentials) do
      attrs = %{
        mapper_job_id: job_record.id,
        name: Map.get(credentials, "name"),
        version: parse_atom(Map.get(credentials, "version", "v2c")),
        community: Map.get(credentials, "community"),
        username: Map.get(credentials, "username"),
        auth_protocol: Map.get(credentials, "auth_protocol"),
        auth_password: Map.get(credentials, "auth_password"),
        privacy_protocol: Map.get(credentials, "privacy_protocol"),
        privacy_password: Map.get(credentials, "privacy_password")
      }

      changeset = Ash.Changeset.for_create(MapperSNMPCredential, :create, attrs, actor: actor)

      case Ash.create(changeset, actor: actor) do
        {:ok, _} -> {:ok, 1}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, 0}
    end
  end

  defp create_unifi_controllers(job_record, unifi_apis, actor) do
    Enum.reduce_while(unifi_apis, {:ok, 0}, fn api, {:ok, count} ->
      attrs = %{
        mapper_job_id: job_record.id,
        name: Map.get(api, "name"),
        base_url: Map.get(api, "base_url"),
        api_key: Map.get(api, "api_key"),
        insecure_skip_verify: Map.get(api, "insecure_skip_verify", false)
      }

      changeset = Ash.Changeset.for_create(MapperUnifiController, :create, attrs, actor: actor)

      case Ash.create(changeset, actor: actor) do
        {:ok, _} -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_atom(value) when is_atom(value), do: value

  defp parse_atom(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.to_existing_atom()
  rescue
    _ -> :full
  end

  defp parse_atom(_), do: :full

  defp discovery_mode_for([]), do: :snmp
  defp discovery_mode_for(_), do: :api
end
