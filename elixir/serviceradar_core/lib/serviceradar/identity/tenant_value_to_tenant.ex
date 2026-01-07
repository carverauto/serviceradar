defimpl Ash.ToTenant, for: BitString do
  @moduledoc false

  alias ServiceRadar.Cluster.TenantSchemas

  def to_tenant(value, resource) when is_binary(value) do
    case Ash.Resource.Info.multitenancy_strategy(resource) do
      :context ->
        case schema_for_value(value) do
          nil ->
            raise ArgumentError, "Unknown tenant schema for #{inspect(value)}"

          schema ->
            schema
        end

      _ -> value
    end
  end

  defp schema_for_value(value) do
    cond do
      String.starts_with?(value, "tenant_") ->
        value

      uuid_string?(value) ->
        TenantSchemas.schema_for_id(value)

      true ->
        TenantSchemas.schema_for(value)
    end
  end

  defp uuid_string?(value) do
    Regex.match?(
      ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
      value
    )
  end
end
