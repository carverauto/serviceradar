defmodule ServiceRadar.Plugins.ProducerScheduleCatalog do
  @moduledoc """
  Materializes package-declared producer schedule contracts as operator state rows.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Plugins.ProducerSchedule
  alias ServiceRadar.Plugins.RetiredNativeAddons

  require Ash.Query
  require Logger

  @spec sync_package(PluginPackage.t() | AddonPackage.t(), keyword()) :: :ok | {:error, term()}
  def sync_package(package, opts \\ [])

  def sync_package(%PluginPackage{} = package, opts) do
    sync_contracts(:wasm_plugin, package, package.producer_schedules || [], opts)
  end

  def sync_package(%AddonPackage{addon_id: addon_id} = package, opts) do
    # Retired native add-ons (e.g. advisory-producer, now owned by core/web-ng)
    # must never re-seed producer schedules — even when an old package row is
    # re-saved and the AfterAction hook fires. The generic producer-schedule
    # subsystem stays intact for every non-retired package.
    if RetiredNativeAddons.retired?(addon_id) do
      Logger.debug(
        "producer_schedule_catalog: skipping producer-schedule seeding for retired native add-on #{addon_id}"
      )

      :ok
    else
      sync_contracts(:native_addon, package, package.producer_schedules || [], opts)
    end
  end

  def sync_package(_package, _opts), do: :ok

  defp sync_contracts(kind, package, contracts, opts) when is_list(contracts) do
    _opts = opts
    actor = SystemActor.system(:producer_schedule_catalog)

    Enum.reduce_while(contracts, :ok, fn contract, :ok ->
      case sync_contract(kind, package, normalize_contract(contract), actor) do
        {:ok, _schedule} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp sync_contracts(_kind, _package, _contracts, _opts), do: :ok

  defp sync_contract(kind, package, contract, actor) do
    schedule_id = map_get(contract, "schedule_id")

    attrs =
      put_package_ref(
        %{
          producer_kind: kind,
          schedule_id: schedule_id,
          display_name: map_get(contract, "label") || schedule_id,
          description: map_get(contract, "description"),
          contract: contract,
          schedule_type: schedule_type(map_get(contract, "schedule_type")),
          cadence_seconds: contract_int(contract, "default_cadence_seconds", 86_400)
        },
        kind,
        package.id
      )

    case find_existing(kind, package.id, schedule_id, actor) do
      {:ok, nil} ->
        ProducerSchedule
        |> Ash.Changeset.for_create(:create, attrs)
        |> Ash.create(actor: actor)

      {:ok, schedule} ->
        schedule
        |> Ash.Changeset.for_update(
          :update,
          Map.take(attrs, [:display_name, :description, :contract])
        )
        |> Ash.update(actor: actor)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_existing(:wasm_plugin, package_id, schedule_id, actor) do
    ProducerSchedule
    |> Ash.Query.filter(
      producer_kind == :wasm_plugin and plugin_package_id == ^package_id and
        schedule_id == ^schedule_id
    )
    |> Ash.read_one(actor: actor)
  end

  defp find_existing(:native_addon, package_id, schedule_id, actor) do
    ProducerSchedule
    |> Ash.Query.filter(
      producer_kind == :native_addon and addon_package_id == ^package_id and
        schedule_id == ^schedule_id
    )
    |> Ash.read_one(actor: actor)
  end

  defp put_package_ref(attrs, :wasm_plugin, package_id),
    do: Map.put(attrs, :plugin_package_id, package_id)

  defp put_package_ref(attrs, :native_addon, package_id),
    do: Map.put(attrs, :addon_package_id, package_id)

  defp normalize_contract(contract) when is_map(contract) do
    Map.new(contract, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_contract(_contract), do: %{}

  defp schedule_type("cron"), do: :cron
  defp schedule_type(:cron), do: :cron
  defp schedule_type("manual"), do: :manual
  defp schedule_type(:manual), do: :manual
  defp schedule_type(_), do: :interval

  defp contract_int(contract, key, default) do
    case map_get(contract, key) do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_int(value, default)
      _ -> default
    end
  end

  defp parse_int(value, default) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp map_get(map, key) when is_map(map), do: Map.get(map, key)
end
