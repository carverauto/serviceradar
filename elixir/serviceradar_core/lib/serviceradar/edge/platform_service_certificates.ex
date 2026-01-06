defmodule ServiceRadar.Edge.PlatformServiceCertificates do
  @moduledoc """
  Issues platform service mTLS certificates with stable identifiers.
  """

  require Ash.Query
  require Logger

  alias ServiceRadar.Edge.OnboardingPackage
  alias ServiceRadar.Edge.OnboardingPackages

  @default_partition_id "platform"
  @default_sync_component_id "platform-sync"
  @default_gateway_addr "agent-gateway:50052"
  @default_sync_listen_addr ":50058"

  @spec platform_sync_component_id() :: String.t()
  def platform_sync_component_id do
    Application.get_env(
      :serviceradar_core,
      :platform_sync_component_id,
      System.get_env("SERVICERADAR_PLATFORM_SYNC_COMPONENT_ID") || @default_sync_component_id
    )
  end

  @spec ensure_platform_sync_certificate(String.t()) :: {:ok, OnboardingPackage.t()} | {:error, term()}
  def ensure_platform_sync_certificate(tenant_id) when is_binary(tenant_id) do
    component_id = platform_sync_component_id()

    ensure_platform_service_certificate(
      tenant_id,
      :sync,
      component_id,
      label: "Platform Sync Service",
      partition_id: @default_partition_id,
      metadata: platform_sync_metadata()
    )
  end

  @spec ensure_platform_service_certificate(String.t(), atom(), String.t(), keyword()) ::
          {:ok, OnboardingPackage.t()} | {:error, term()}
  def ensure_platform_service_certificate(tenant_id, component_type, component_id, opts \\ [])
      when is_binary(tenant_id) and is_binary(component_id) do
    label = Keyword.get(opts, :label, "Platform #{component_type} Service")
    partition_id = Keyword.get(opts, :partition_id, @default_partition_id)
    metadata = platform_metadata(Keyword.get(opts, :metadata, %{}))

    case find_existing_package(tenant_id, component_type, component_id) do
      {:ok, package} ->
        if package.status in [:revoked, :expired, :deleted] do
          create_platform_package(
            tenant_id,
            component_type,
            component_id,
            label,
            partition_id,
            metadata
          )
        else
          maybe_update_metadata(tenant_id, package, metadata)
        end

      :not_found ->
        create_platform_package(
          tenant_id,
          component_type,
          component_id,
          label,
          partition_id,
          metadata
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_platform_package(tenant_id, component_type, component_id, label, partition_id, metadata) do
    attrs = %{
      label: label,
      component_id: component_id,
      component_type: component_type,
      security_mode: :mtls,
      site: partition_id,
      metadata_json: metadata
    }

    case OnboardingPackages.create_with_tenant_cert(attrs,
           tenant: tenant_id,
           partition_id: partition_id,
           cert_validity_days: 365,
           actor: "system",
           authorize?: false
         ) do
      {:ok, %{package: package}} ->
        Logger.info(
          "[PlatformServiceCertificates] Issued platform certificate for #{component_type}:#{component_id}"
        )

        {:ok, package}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_existing_package(tenant_id, component_type, component_id) do
    query =
      OnboardingPackage
      |> Ash.Query.for_read(:read, %{}, tenant: tenant_id, authorize?: false)
      |> Ash.Query.filter(
        component_type == ^component_type and
          component_id == ^component_id and
          is_nil(deleted_at)
      )
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(1)

    case Ash.read_one(query, authorize?: false) do
      {:ok, nil} -> :not_found
      {:ok, package} -> {:ok, package}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_update_metadata(tenant_id, package, metadata) do
    existing = package.metadata_json || %{}
    merged = existing |> Map.merge(metadata) |> Map.put("platform_service", true)

    if merged == existing do
      {:ok, package}
    else
      package
      |> Ash.Changeset.for_update(:update_metadata, %{metadata_json: merged},
        tenant: tenant_id,
        authorize?: false
      )
      |> Ash.update()
    end
  end

  defp platform_metadata(extra) do
    extra = extra || %{}

    %{"platform_service" => true}
    |> Map.merge(extra)
    |> Map.put("platform_service", true)
  end

  defp platform_sync_metadata do
    gateway_addr =
      config_value(:gateway_addr, "SERVICERADAR_GATEWAY_ADDR", @default_gateway_addr)

    listen_addr =
      config_value(:sync_listen_addr, "SERVICERADAR_SYNC_LISTEN_ADDR", @default_sync_listen_addr)

    gateway_server_name = config_value(:gateway_server_name, "SERVICERADAR_GATEWAY_SERVER_NAME", nil)

    metadata = %{
      "gateway_addr" => gateway_addr,
      "listen_addr" => listen_addr
    }

    if is_binary(gateway_server_name) and String.trim(gateway_server_name) != "" do
      Map.put(metadata, "gateway_server_name", String.trim(gateway_server_name))
    else
      metadata
    end
  end

  defp config_value(key, env_var, fallback) do
    value = Application.get_env(:serviceradar_core, key, System.get_env(env_var) || fallback)

    case value do
      nil ->
        fallback

      value ->
        trimmed = String.trim(to_string(value))
        if trimmed == "", do: fallback, else: trimmed
    end
  end
end
