defmodule ServiceRadar.Integrations.EventPublisher do
  @moduledoc """
  Publishes integration source lifecycle events to the OCSF events pipeline.
  """

  require Logger

  alias ServiceRadar.Cluster.TenantRegistry
  alias ServiceRadar.Identity.Tenant
  alias ServiceRadar.NATS.Channels
  alias ServiceRadar.NATS.Connection

  @spec publish_integration_source_event(map(), atom(), keyword()) :: :ok | {:error, term()}
  def publish_integration_source_event(source, action, opts \\ []) do
    tenant_id = source.tenant_id |> to_string()
    tenant_slug = Keyword.get(opts, :tenant_slug) || lookup_tenant_slug(tenant_id)

    if tenant_slug == nil do
      Logger.warning("Integration source event missing tenant slug", tenant_id: tenant_id)
      {:error, :tenant_slug_missing}
    else
      action_name = normalize_action(action)
      subject = Channels.standard(:config_events, tenant_slug: tenant_slug)
      event = build_cloud_event(source, action_name, tenant_slug, opts)

      case Connection.publish(subject, Jason.encode!(event)) do
        :ok -> :ok
        {:error, reason} ->
          Logger.warning("Failed to publish integration source event: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp build_cloud_event(source, action_name, tenant_slug, opts) do
    actor = Keyword.get(opts, :actor)
    time = DateTime.utc_now() |> DateTime.to_iso8601()

    %{
      "specversion" => "1.0",
      "id" => UUID.uuid4(),
      "source" => "serviceradar.core.integrations",
      "type" => "serviceradar.integration_source.#{action_name}",
      "subject" => "integration_sources/#{source.id}",
      "time" => time,
      "data" => %{
        "message" => "Integration source #{action_name}",
        "integration_source" => integration_source_payload(source, tenant_slug),
        "action" => action_name,
        "actor" => actor_payload(actor)
      }
    }
  end

  defp integration_source_payload(source, tenant_slug) do
    %{
      "id" => to_string(source.id),
      "name" => source.name,
      "source_type" => source.source_type && Atom.to_string(source.source_type),
      "endpoint" => source.endpoint,
      "enabled" => source.enabled,
      "sync_service_id" => source.sync_service_id && to_string(source.sync_service_id),
      "tenant_id" => to_string(source.tenant_id),
      "tenant_slug" => tenant_slug,
      "partition" => source.partition
    }
  end

  defp actor_payload(nil), do: %{}

  defp actor_payload(actor) when is_map(actor) do
    %{
      "id" => Map.get(actor, :id),
      "email" => Map.get(actor, :email),
      "role" => Map.get(actor, :role)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp actor_payload(_), do: %{}

  defp normalize_action(action) when is_atom(action) do
    case action do
      :create -> "created"
      :update -> "updated"
      :enable -> "enabled"
      :disable -> "disabled"
      :delete -> "deleted"
      :destroy -> "deleted"
      _ -> Atom.to_string(action)
    end
  end

  defp lookup_tenant_slug(tenant_id) do
    case TenantRegistry.slug_for_tenant_id(tenant_id) do
      {:ok, slug} -> slug
      :error -> lookup_tenant_slug_from_db(tenant_id)
    end
  end

  defp lookup_tenant_slug_from_db(nil), do: nil

  defp lookup_tenant_slug_from_db(tenant_id) do
    require Ash.Query

    case Tenant
         |> Ash.Query.filter(id == ^tenant_id)
         |> Ash.Query.limit(1)
         |> Ash.read(authorize?: false) do
      {:ok, [tenant | _]} -> to_string(tenant.slug)
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
