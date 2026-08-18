defmodule ServiceRadar.Plugins.IntegrationCatalog do
  @moduledoc """
  Builds the runtime integration catalog from approved signed plugin packages.

  The catalog contains only descriptors validated by `ServiceRadar.Plugins.Manifest`.
  Provider implementations remain in their plugin packages; core performs no dynamic
  module loading and gives duplicate provider/source claims no implicit precedence.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.NativeDescriptors
  alias ServiceRadar.Plugins.Manifest
  alias ServiceRadar.Plugins.PluginPackage

  require Ash.Query

  @type catalog :: %{
          required(:credential_profiles) => [map()],
          required(:inventory_sources) => [map()]
        }

  @spec load(keyword()) :: {:ok, catalog()} | {:error, term()}
  def load(opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:plugin_integration_catalog))

    with {:ok, packages} <- approved_packages(actor),
         {:ok, catalog} <- from_packages(packages) do
      {:ok, merge_native_profiles(catalog)}
    end
  end

  @spec from_packages([map()]) :: {:ok, catalog()} | {:error, term()}
  def from_packages(packages) when is_list(packages) do
    packages
    |> latest_package_versions()
    |> Enum.reduce_while({:ok, empty()}, fn package, {:ok, catalog} ->
      case package_integrations(package) do
        {:ok, integrations} ->
          {:cont,
           {:ok,
            %{
              credential_profiles:
                catalog.credential_profiles ++ integrations.credential_profiles,
              inventory_sources: catalog.inventory_sources ++ integrations.inventory_sources
            }}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, catalog} -> validate_unique_claims(catalog)
      {:error, reason} -> {:error, reason}
    end
  end

  def from_packages(_packages), do: {:error, :invalid_plugin_packages}

  @spec profile_for(String.t(), keyword()) :: {:ok, map()} | :error | {:error, term()}
  def profile_for(provider, opts \\ [])

  def profile_for(provider, opts) when is_binary(provider) do
    with {:ok, catalog} <- load(opts) do
      case Enum.find(catalog.credential_profiles, &(&1["provider"] == provider)) do
        nil -> :error
        profile -> {:ok, profile}
      end
    end
  end

  def profile_for(_provider, _opts), do: :error

  @spec consumer_for_plugin_id(String.t(), keyword()) ::
          {:ok, {map(), map()}} | :error | {:error, term()}
  def consumer_for_plugin_id(plugin_id, opts \\ [])

  def consumer_for_plugin_id(plugin_id, opts) when is_binary(plugin_id) do
    with {:ok, catalog} <- load(opts) do
      Enum.find_value(catalog.credential_profiles, :error, fn profile ->
        profile
        |> get_in(["provisioning", "consumers"])
        |> List.wrap()
        |> Enum.find_value(fn consumer ->
          if consumer["plugin_id"] == plugin_id, do: {:ok, {profile, consumer}}
        end)
      end)
    end
  end

  def consumer_for_plugin_id(_plugin_id, _opts), do: :error

  @spec source_for(String.t(), keyword()) :: {:ok, map()} | :error | {:error, term()}
  def source_for(source, opts \\ [])

  def source_for(source, opts) when is_binary(source) do
    with {:ok, catalog} <- load(opts) do
      case Enum.find(catalog.inventory_sources, &(&1["source"] == source)) do
        nil -> :error
        descriptor -> {:ok, descriptor}
      end
    end
  end

  def source_for(_source, _opts), do: :error

  defp approved_packages(actor) do
    PluginPackage
    |> Ash.Query.for_read(:approved, %{}, actor: actor)
    |> Ash.read(actor: actor)
  end

  defp package_integrations(package) do
    manifest = value(package, :manifest) || %{}

    case Manifest.from_map(manifest) do
      {:ok, parsed} ->
        common = %{
          "plugin_id" => parsed.id,
          "plugin_name" => parsed.name,
          "plugin_package_id" => value(package, :id),
          "plugin_version" => parsed.version,
          "config_schema" => value(package, :config_schema) || %{},
          "documentation" => parsed.integrations["documentation"] || %{}
        }

        schedules = Map.new(parsed.producer_schedules, &{&1["schedule_id"], &1})

        {:ok,
         %{
           credential_profiles:
             Enum.map(parsed.integrations["credential_profiles"], fn profile ->
               profile
               |> Map.merge(common)
               |> maybe_attach_producer_schedule(schedules)
             end),
           inventory_sources:
             Enum.map(parsed.integrations["inventory_sources"], &Map.merge(&1, common))
         }}

      {:error, errors} ->
        {:error, {:invalid_approved_plugin_manifest, value(package, :id), errors}}
    end
  end

  defp latest_package_versions(packages) do
    packages
    |> Enum.sort(&newer_package?/2)
    |> Enum.uniq_by(&(value(&1, :plugin_id) || get_in(value(&1, :manifest) || %{}, ["id"])))
  end

  defp maybe_attach_producer_schedule(profile, schedules) do
    case profile["provisioning"] do
      %{"mode" => "producer_schedule", "schedule_id" => schedule_id} ->
        Map.put(profile, "producer_schedule", Map.fetch!(schedules, schedule_id))

      _ ->
        profile
    end
  end

  defp newer_package?(left, right) do
    case compare_versions(package_version(left), package_version(right)) do
      :gt -> true
      :lt -> false
      :eq -> package_tiebreaker(left) >= package_tiebreaker(right)
    end
  end

  defp package_version(package) do
    version = value(package, :version) || get_in(value(package, :manifest) || %{}, ["version"])

    case version do
      value when is_binary(value) ->
        case Version.parse(String.trim_leading(value, "v")) do
          {:ok, parsed} -> {:valid, parsed}
          :error -> :invalid
        end

      _ ->
        :invalid
    end
  end

  defp compare_versions({:valid, left}, {:valid, right}), do: Version.compare(left, right)
  defp compare_versions({:valid, _left}, :invalid), do: :gt
  defp compare_versions(:invalid, {:valid, _right}), do: :lt
  defp compare_versions(:invalid, :invalid), do: :eq

  defp package_tiebreaker(package) do
    {timestamp(value(package, :approved_at)), timestamp(value(package, :inserted_at)),
     to_string(value(package, :id) || "")}
  end

  defp timestamp(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)
  defp timestamp(_value), do: 0

  defp validate_unique_claims(catalog) do
    with :ok <- unique_claim(catalog.credential_profiles, "provider", :duplicate_plugin_provider),
         :ok <- unique_claim(catalog.inventory_sources, "source", :duplicate_inventory_source) do
      {:ok, catalog}
    end
  end

  defp unique_claim(values, key, error_tag) do
    case values
         |> Enum.group_by(&Map.get(&1, key))
         |> Enum.find(fn {_claim, descriptors} -> length(descriptors) > 1 end) do
      nil ->
        :ok

      {claim, descriptors} ->
        {:error, {error_tag, claim, Enum.map(descriptors, & &1["plugin_id"])}}
    end
  end

  defp value(%{} = value, key), do: Map.get(value, key) || Map.get(value, to_string(key))
  defp value(_value, _key), do: nil

  defp merge_native_profiles(catalog) do
    claimed = MapSet.new(catalog.credential_profiles, & &1["provider"])

    natives =
      NativeDescriptors.all()
      |> Map.values()
      |> Enum.reject(&MapSet.member?(claimed, &1["provider"]))
      |> Enum.sort_by(&String.downcase(&1["label"] || &1["provider"]))

    %{catalog | credential_profiles: natives ++ catalog.credential_profiles}
  end

  defp empty, do: %{credential_profiles: [], inventory_sources: []}
end
