defmodule ServiceRadar.Observability.RawMetricResource do
  @moduledoc false

  defmacro __using__(opts) do
    table = Keyword.fetch!(opts, :table)
    type = Keyword.fetch!(opts, :type)
    route = Keyword.fetch!(opts, :route)
    primary_key = Keyword.fetch!(opts, :primary_key)
    require_primary_key = Keyword.get(opts, :require_primary_key?, false)

    quote bind_quoted: [
            table: table,
            type: type,
            route: route,
            primary_key: primary_key,
            require_primary_key: require_primary_key
          ] do
      use Ash.Resource,
        domain: ServiceRadar.Observability,
        data_layer: AshPostgres.DataLayer,
        authorizers: [Ash.Policy.Authorizer],
        extensions: [AshJsonApi.Resource]

      postgres do
        table(table)
        repo(ServiceRadar.Repo)
        schema("platform")
        migrate?(false)
      end

      json_api do
        type(type)

        primary_key do
          keys(primary_key)
        end

        routes do
          base(route)
          index(:api_index)
        end
      end

      resource do
        require_primary_key?(require_primary_key)
      end

      actions do
        read :api_index do
          pagination do
            offset?(true)
            default_limit(100)
            max_page_size(1000)
            required?(true)
          end
        end
      end

      policies do
        import ServiceRadar.Policies

        system_bypass()
        read_viewer_plus()

        policy action(:create) do
          authorize_if(actor_attribute_equals(:role, :system))
        end
      end
    end
  end
end
