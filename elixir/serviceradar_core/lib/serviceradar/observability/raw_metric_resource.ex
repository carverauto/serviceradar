defmodule ServiceRadar.Observability.RawMetricResource do
  @moduledoc false

  defmacro __using__(opts) do
    table = Keyword.fetch!(opts, :table)
    type = Keyword.fetch!(opts, :type)
    route = Keyword.fetch!(opts, :route)
    require_primary_key = Keyword.get(opts, :require_primary_key?, false)

    quote bind_quoted: [
            table: table,
            type: type,
            route: route,
            require_primary_key: require_primary_key
          ] do
      use Ash.Resource,
        domain: ServiceRadar.Observability,
        data_layer: AshPostgres.DataLayer,
        authorizers: [Ash.Policy.Authorizer],
        extensions: [AshJsonApi.Resource]

      postgres do
        table table
        repo ServiceRadar.Repo
        schema "platform"
        migrate? false
      end

      json_api do
        type type

        routes do
          base route
          index :read
        end
      end

      resource do
        require_primary_key? require_primary_key
      end

      policies do
        policy action_type(:read) do
          authorize_if always()
        end

        policy action(:create) do
          authorize_if always()
        end
      end
    end
  end
end
