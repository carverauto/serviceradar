defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.Index.MapperPersistence do
  @moduledoc false

  import ServiceRadarWebNGWeb.Settings.NetworksLive.Index.Data, only: [load_mapper_job: 2]

  alias ServiceRadar.NetworkDiscovery.MapperJob
  alias ServiceRadar.NetworkDiscovery.MapperMikrotikController
  alias ServiceRadar.NetworkDiscovery.MapperSeed
  alias ServiceRadar.NetworkDiscovery.MapperUnifiController

  def save_mapper_job(job, job_params, seeds, unifi_params, mikrotik_params, scope) do
    with {:ok, job} <- upsert_mapper_job(job, job_params, scope),
         :ok <- replace_mapper_seeds(job, seeds, scope),
         :ok <- upsert_unifi_controller(job, unifi_params, scope),
         :ok <- upsert_mikrotik_controller(job, mikrotik_params, scope) do
      {:ok, job}
    end
  end

  def upsert_mapper_job(nil, params, scope) do
    MapperJob
    |> Ash.Changeset.for_create(:create, params)
    |> Ash.create(scope: scope)
  end

  def upsert_mapper_job(job, params, scope) do
    job
    |> Ash.Changeset.for_update(:update, params)
    |> Ash.update(scope: scope)
  end

  def replace_mapper_seeds(job, seeds, scope) do
    # Load the seeds relationship if not already loaded
    existing =
      case Ash.load(job, [:seeds], scope: scope) do
        {:ok, loaded} -> loaded.seeds || []
        {:error, _} -> []
      end

    Enum.each(existing, fn seed ->
      _ = Ash.destroy(seed, scope: scope)
    end)

    Enum.reduce_while(seeds, :ok, fn seed, _acc ->
      case MapperSeed
           |> Ash.Changeset.for_create(:create, %{seed: seed, mapper_job_id: job.id})
           |> Ash.create(scope: scope) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def upsert_unifi_controller(_job, params, _scope) when map_size(params) == 0, do: :ok

  def upsert_unifi_controller(job, params, scope) do
    base_url = params |> Map.get("base_url") |> to_string() |> String.trim()

    if base_url == "" do
      :ok
    else
      persist_unifi_controller(job, params, scope)
    end
  end

  def upsert_mikrotik_controller(_job, params, _scope) when map_size(params) == 0, do: :ok

  def upsert_mikrotik_controller(job, params, scope) do
    base_url = params |> Map.get("base_url") |> to_string() |> String.trim()

    if base_url == "" do
      :ok
    else
      persist_mikrotik_controller(job, params, scope)
    end
  end

  def fetch_mapper_job(scope, id) do
    case load_mapper_job(scope, id) do
      nil -> {:error, :not_found}
      job -> {:ok, job}
    end
  end

  def persist_unifi_controller(job, params, scope) do
    # Load the unifi_controllers relationship if not already loaded
    existing =
      case Ash.load(job, [:unifi_controllers], scope: scope) do
        {:ok, loaded} -> List.first(loaded.unifi_controllers || [])
        {:error, _} -> nil
      end

    result =
      case existing do
        nil ->
          create_params = Map.put(params, "mapper_job_id", job.id)

          MapperUnifiController
          |> Ash.Changeset.for_create(:create, create_params)
          |> Ash.create(scope: scope)

        controller ->
          # Don't include mapper_job_id in update - it's not accepted
          controller
          |> Ash.Changeset.for_update(:update, params)
          |> Ash.update(scope: scope)
      end

    case result do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def persist_mikrotik_controller(job, params, scope) do
    existing =
      case Ash.load(job, [:mikrotik_controllers], scope: scope) do
        {:ok, loaded} -> List.first(loaded.mikrotik_controllers || [])
        {:error, _} -> nil
      end

    result =
      case existing do
        nil ->
          create_params = Map.put(params, "mapper_job_id", job.id)

          MapperMikrotikController
          |> Ash.Changeset.for_create(:create, create_params)
          |> Ash.create(scope: scope)

        controller ->
          controller
          |> Ash.Changeset.for_update(:update, params)
          |> Ash.update(scope: scope)
      end

    case result do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
