defmodule ServiceRadar.Observability.NetflowLookupCacheResource do
  @moduledoc false

  alias ServiceRadar.Observability.ResourceAttributeAst

  defmacro __using__(opts) do
    table = Keyword.fetch!(opts, :table)
    {key_fields, _binding} = Code.eval_quoted(Keyword.fetch!(opts, :key_fields), [], __CALLER__)
    {fields, _binding} = Code.eval_quoted(Keyword.fetch!(opts, :fields), [], __CALLER__)
    identity = Keyword.fetch!(opts, :identity)
    upsert_fields = Keyword.fetch!(opts, :upsert_fields)

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
        defaults [:read]

        create :upsert do
          accept unquote(Enum.map(key_fields ++ fields, &elem(&1, 0)))

          upsert? true
          upsert_identity unquote(identity)
          upsert_fields unquote(upsert_fields ++ [:updated_at])
        end
      end

      policies do
        bypass always() do
          authorize_if actor_attribute_equals(:role, :system)
        end

        policy action_type(:read) do
          authorize_if actor_attribute_equals(:role, :viewer)
          authorize_if actor_attribute_equals(:role, :operator)
          authorize_if actor_attribute_equals(:role, :admin)
        end

        policy action(:upsert) do
          authorize_if actor_attribute_equals(:role, :operator)
          authorize_if actor_attribute_equals(:role, :admin)
          authorize_if actor_attribute_equals(:role, :system)
        end
      end

      attributes do
        unquote_splicing(Enum.map(key_fields ++ fields, &ResourceAttributeAst.build/1))
        create_timestamp :inserted_at
        update_timestamp :updated_at
      end

      identities do
        identity unquote(identity), unquote(Enum.map(key_fields, &elem(&1, 0)))
      end
    end
  end
end
