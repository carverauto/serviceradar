defmodule ServiceRadar.Observability.NetflowDatasetSnapshotResource do
  @moduledoc false

  defmacro __using__(opts) do
    table = Keyword.fetch!(opts, :table)
    is_active_field = Macro.var(:is_active, nil)
    id_field = Macro.var(:id, nil)
    active_filter = quote(do: expr(unquote(is_active_field) == true))
    by_id_filter = quote(do: expr(unquote(id_field) == ^arg(:id)))

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

      code_interface do
        define :create, action: :create
        define :active, action: :active
        define :by_id, action: :by_id
        define :promote, action: :promote
      end

      actions do
        defaults [:read]

        read :active do
          get? true
          filter unquote(active_filter)
        end

        read :by_id do
          get? true
          argument :id, :uuid, allow_nil?: false
          filter unquote(by_id_filter)
        end

        create :create do
          accept [
            :source_url,
            :source_etag,
            :source_sha256,
            :fetched_at,
            :promoted_at,
            :is_active,
            :record_count,
            :metadata
          ]
        end

        update :promote do
          accept [:is_active, :promoted_at]
          change set_attribute(:is_active, true)
          change set_attribute(:promoted_at, &DateTime.utc_now/0)
        end
      end

      policies do
        bypass always() do
          authorize_if actor_attribute_equals(:role, :system)
        end

        policy action_type(:read) do
          authorize_if always()
        end

        policy action([:create, :promote]) do
          authorize_if actor_attribute_equals(:role, :system)
        end
      end

      attributes do
        uuid_primary_key :id

        attribute :source_url, :string do
          allow_nil? false
          public? true
        end

        attribute :source_etag, :string do
          public? true
        end

        attribute :source_sha256, :string do
          public? true
        end

        attribute :fetched_at, :utc_datetime_usec do
          allow_nil? false
          public? true
        end

        attribute :promoted_at, :utc_datetime_usec do
          public? true
        end

        attribute :is_active, :boolean do
          allow_nil? false
          default false
          public? true
        end

        attribute :record_count, :integer do
          allow_nil? false
          default 0
          public? true
        end

        attribute :metadata, :map do
          allow_nil? false
          default %{}
          public? true
        end

        create_timestamp :inserted_at
        update_timestamp :updated_at
      end
    end
  end
end
