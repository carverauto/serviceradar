defmodule ServiceRadar.Observability.IpLookupCacheResource do
  @moduledoc false

  alias ServiceRadar.Observability.ResourceAttributeAst

  defmacro __using__(opts) do
    table = Keyword.fetch!(opts, :table)
    {fields, _binding} = Code.eval_quoted(Keyword.fetch!(opts, :fields), [], __CALLER__)
    read_policy = Keyword.get(opts, :read_policy, :restricted)
    upsert_roles = Keyword.get(opts, :upsert_roles, [:operator, :admin, :system])

    extra_fields = Enum.map(fields, &elem(&1, 0))
    common_fields = [:looked_up_at, :expires_at, :error, :error_count]
    ip_field = Macro.var(:ip, nil)
    by_ip_filter = quote(do: expr(unquote(ip_field) == ^arg(:ip)))

    extra_attributes = Enum.map(fields, &ResourceAttributeAst.build/1)

    read_policy_ast =
      case read_policy do
        :public ->
          quote do
            policy action_type(:read) do
              authorize_if always()
            end
          end

        :restricted ->
          quote do
            policy action_type(:read) do
              authorize_if actor_attribute_equals(:role, :viewer)
              authorize_if actor_attribute_equals(:role, :operator)
              authorize_if actor_attribute_equals(:role, :admin)
            end
          end
      end

    upsert_authorizers =
      Enum.map(upsert_roles, fn role ->
        quote do
          authorize_if actor_attribute_equals(:role, unquote(role))
        end
      end)

    quote do
      use Ash.Resource,
        domain: ServiceRadar.Observability,
        data_layer: AshPostgres.DataLayer,
        authorizers: [Ash.Policy.Authorizer]

      postgres do
        table unquote(table)
        repo ServiceRadar.Repo
        schema "platform"
        migrate? false
      end

      actions do
        defaults [:read, :destroy]

        read :by_ip do
          argument :ip, :string, allow_nil?: false
          filter unquote(by_ip_filter)
        end

        create :upsert do
          accept unquote([:ip | extra_fields ++ common_fields])

          upsert? true
          upsert_identity :unique_ip

          upsert_fields unquote(extra_fields ++ common_fields ++ [:updated_at])
        end
      end

      policies do
        bypass always() do
          authorize_if actor_attribute_equals(:role, :system)
        end

        unquote(read_policy_ast)

        policy action(:upsert) do
          unquote_splicing(upsert_authorizers)
        end

        policy action(:destroy) do
          authorize_if actor_attribute_equals(:role, :system)
        end
      end

      attributes do
        attribute :ip, :string do
          primary_key? true
          allow_nil? false
          public? true
        end

        unquote_splicing(extra_attributes)

        attribute :looked_up_at, :utc_datetime_usec do
          allow_nil? false
          public? true
        end

        attribute :expires_at, :utc_datetime_usec do
          allow_nil? false
          public? true
        end

        attribute :error, :string do
          public? true
        end

        attribute :error_count, :integer do
          allow_nil? false
          default 0
          public? true
        end

        create_timestamp :inserted_at
        update_timestamp :updated_at
      end

      identities do
        identity :unique_ip, [:ip]
      end
    end
  end
end
