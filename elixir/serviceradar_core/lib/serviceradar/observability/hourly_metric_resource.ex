defmodule ServiceRadar.Observability.HourlyMetricResource do
  @moduledoc false

  defmacro __using__(opts) do
    table = Keyword.fetch!(opts, :table)
    type = Keyword.fetch!(opts, :type)
    route = Keyword.fetch!(opts, :route)

    quote bind_quoted: [table: table, type: type, route: route] do
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
        require_primary_key? false
      end

      actions do
        defaults [:read]
      end

      policies do
        import ServiceRadar.Policies

        system_bypass()
        read_viewer_plus()
      end
    end
  end
end
