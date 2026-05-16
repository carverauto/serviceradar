defmodule ServiceRadar.Automation.Northbound.PluginActionSync do
  @moduledoc """
  Synchronizes approved Wasm plugin action descriptors into the northbound catalog.

  Plugin manifests are reviewed as package metadata, but launch surfaces should
  consume provider-neutral action descriptors. This module is the bridge between
  the plugin package lifecycle and the northbound action catalog.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Northbound
  alias ServiceRadar.Automation.Northbound.ActionDescriptor
  alias ServiceRadar.Automation.Northbound.ActionProvider
  alias ServiceRadar.Plugins.Manifest
  alias ServiceRadar.Plugins.PluginPackage

  require Logger

  @system_actor SystemActor.system(:northbound_plugin_action_sync)
  @provider_type :wasm_plugin

  @spec sync_package(PluginPackage.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def sync_package(package, opts \\ [])

  def sync_package(%PluginPackage{} = package, opts) do
    actor = Keyword.get(opts, :actor, @system_actor)

    with {:ok, manifest} <- parse_manifest(package),
         :approved <- package.status do
      sync_approved_package(package, manifest, actor)
    else
      {:error, _reason} = error ->
        error

      _not_approved ->
        disable_package(package, actor: actor)
    end
  end

  def sync_package(_package, _opts), do: {:error, :invalid_package}

  @spec disable_package(PluginPackage.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def disable_package(package, opts \\ [])

  def disable_package(%PluginPackage{} = package, opts) do
    actor = Keyword.get(opts, :actor, @system_actor)

    case read_provider(package, actor) do
      {:ok, nil} ->
        {:ok, %{provider: nil, disabled_descriptors: 0}}

      {:ok, provider} ->
        with {:ok, disabled_descriptors} <- disable_provider_descriptors(provider, actor),
             {:ok, provider} <- ensure_disabled(provider, actor) do
          {:ok, %{provider: provider, disabled_descriptors: disabled_descriptors}}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  def disable_package(_package, _opts), do: {:error, :invalid_package}

  defp sync_approved_package(%PluginPackage{} = package, %Manifest{} = manifest, actor) do
    actions = manifest.actions || []

    if actions == [] do
      disable_package(package, actor: actor)
    else
      with {:ok, provider} <- upsert_provider(package, manifest, actor),
           {:ok, provider} <- ensure_active(provider, actor),
           {:ok, descriptors} <- upsert_descriptors(provider, package, manifest, actor),
           {:ok, disabled_count} <- disable_stale_descriptors(provider, descriptors, actor) do
        {:ok,
         %{provider: provider, descriptors: descriptors, disabled_descriptors: disabled_count}}
      end
    end
  end

  defp parse_manifest(%PluginPackage{manifest: manifest}) when is_map(manifest) do
    case Manifest.from_map(manifest) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, errors} -> {:error, {:invalid_manifest, errors}}
    end
  end

  defp parse_manifest(_package), do: {:error, {:invalid_manifest, ["manifest must be a map"]}}

  defp upsert_provider(package, manifest, actor) do
    attrs = provider_attrs(package, manifest)

    case read_provider(package, actor) do
      {:ok, nil} ->
        ActionProvider
        |> Ash.Changeset.for_create(:create, attrs, actor: actor)
        |> Ash.create(actor: actor, domain: Northbound)

      {:ok, provider} ->
        provider
        |> Ash.Changeset.for_update(:update, Map.delete(attrs, :provider_type), actor: actor)
        |> Ash.update(actor: actor, domain: Northbound)

      {:error, error} ->
        {:error, error}
    end
  end

  defp provider_attrs(%PluginPackage{} = package, %Manifest{} = manifest) do
    %{
      name: manifest.name,
      description: manifest.description,
      provider_type: @provider_type,
      source_ref: source_ref(package),
      plugin_package_id: package.id,
      approved_capabilities: package.approved_capabilities || manifest.capabilities || [],
      credential_requirements: %{},
      metadata: %{
        "plugin_id" => package.plugin_id,
        "plugin_version" => package.version,
        "package_id" => package.id,
        "source_type" => to_string(package.source_type),
        "content_hash" => package.content_hash,
        "approved_permissions" => package.approved_permissions || %{},
        "approved_resources" => package.approved_resources || %{}
      }
    }
  end

  defp read_provider(%PluginPackage{} = package, actor) do
    ActionProvider
    |> Ash.Query.for_read(
      :by_source,
      %{provider_type: @provider_type, source_ref: source_ref(package)},
      actor: actor
    )
    |> Ash.read_one(actor: actor, domain: Northbound)
  end

  defp ensure_active(%ActionProvider{status: :active} = provider, _actor), do: {:ok, provider}

  defp ensure_active(%ActionProvider{status: :unhealthy} = provider, actor) do
    provider
    |> Ash.Changeset.for_update(
      :mark_recovered,
      %{last_health_summary: "Plugin package action descriptors approved"},
      actor: actor
    )
    |> Ash.update(actor: actor, domain: Northbound)
  end

  defp ensure_active(%ActionProvider{} = provider, actor) do
    provider
    |> Ash.Changeset.for_update(:activate, %{}, actor: actor)
    |> Ash.update(actor: actor, domain: Northbound)
  end

  defp ensure_disabled(%ActionProvider{status: :disabled} = provider, _actor), do: {:ok, provider}

  defp ensure_disabled(%ActionProvider{} = provider, actor) do
    provider
    |> Ash.Changeset.for_update(:disable, %{}, actor: actor)
    |> Ash.update(actor: actor, domain: Northbound)
  end

  defp upsert_descriptors(provider, package, manifest, actor) do
    manifest.actions
    |> Enum.reduce_while({:ok, []}, fn action, {:ok, acc} ->
      attrs = descriptor_attrs(action, provider, package, manifest)

      ActionDescriptor
      |> Ash.Changeset.for_create(:upsert, attrs, actor: actor)
      |> Ash.create(actor: actor, domain: Northbound)
      |> case do
        {:ok, descriptor} -> {:cont, {:ok, [descriptor | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, descriptors} -> {:ok, Enum.reverse(descriptors)}
      {:error, error} -> {:error, error}
    end
  end

  defp descriptor_attrs(action, provider, package, manifest) do
    %{
      provider_id: provider.id,
      action_id: action.action_id,
      version: action.version,
      label: action.label,
      description: action.description,
      scopes: action.scopes,
      required_context: action.required_context,
      input_schema: action.input_schema,
      safety_classification: safety_classification(action.safety_classification),
      requires_confirmation: action.requires_confirmation,
      timeout_seconds: action.timeout_seconds,
      credential_requirements: action.credential_requirements,
      result_schema_version: action.result_schema_version,
      descriptor_hash: descriptor_hash(action),
      enabled: true,
      metadata: %{
        "plugin_id" => package.plugin_id,
        "plugin_version" => package.version,
        "package_id" => package.id,
        "provider_name" => manifest.name
      }
    }
  end

  defp disable_stale_descriptors(provider, synced_descriptors, actor) do
    active_keys = MapSet.new(synced_descriptors, &descriptor_key/1)

    with {:ok, existing} <- list_provider_descriptors(provider, actor) do
      existing
      |> Enum.reject(&(descriptor_key(&1) in active_keys))
      |> Enum.reduce_while({:ok, 0}, fn descriptor, {:ok, count} ->
        disable_descriptor(descriptor, actor, count)
      end)
    end
  end

  defp disable_provider_descriptors(provider, actor) do
    with {:ok, descriptors} <- list_provider_descriptors(provider, actor) do
      Enum.reduce_while(descriptors, {:ok, 0}, fn descriptor, {:ok, count} ->
        disable_descriptor(descriptor, actor, count)
      end)
    end
  end

  defp list_provider_descriptors(provider, actor) do
    ActionDescriptor
    |> Ash.Query.for_read(:by_provider, %{provider_id: provider.id}, actor: actor)
    |> Ash.read(actor: actor, domain: Northbound)
  end

  defp disable_descriptor(%ActionDescriptor{enabled: false}, _actor, count),
    do: {:cont, {:ok, count}}

  defp disable_descriptor(%ActionDescriptor{} = descriptor, actor, count) do
    descriptor
    |> Ash.Changeset.for_update(:update, %{enabled: false}, actor: actor)
    |> Ash.update(actor: actor, domain: Northbound)
    |> case do
      {:ok, _descriptor} ->
        {:cont, {:ok, count + 1}}

      {:error, error} ->
        Logger.warning("Failed to disable northbound action descriptor: #{inspect(error)}")
        {:halt, {:error, error}}
    end
  end

  defp descriptor_key(%ActionDescriptor{} = descriptor) do
    {descriptor.action_id, descriptor.version}
  end

  defp source_ref(%PluginPackage{} = package), do: "plugin_package:#{package.id}"

  defp safety_classification("read_only"), do: :read_only
  defp safety_classification("destructive"), do: :destructive
  defp safety_classification(_), do: :standard

  defp descriptor_hash(action) do
    action
    |> canonicalize()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonicalize(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), canonicalize(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)
  defp canonicalize(value), do: value
end
