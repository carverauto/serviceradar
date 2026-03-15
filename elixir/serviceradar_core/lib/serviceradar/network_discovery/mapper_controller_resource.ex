defmodule ServiceRadar.NetworkDiscovery.MapperControllerResource do
  @moduledoc false

  alias ServiceRadar.Observability.ResourceAttributeAst

  defmacro __using__(opts) do
    table = Keyword.fetch!(opts, :table)
    index_name = Keyword.fetch!(opts, :index_name)
    secret_field = Keyword.fetch!(opts, :secret_field)
    secret_present_calc = Keyword.fetch!(opts, :secret_present_calc)
    normalizer_change = Keyword.fetch!(opts, :normalizer_change)
    base_url_description = Keyword.fetch!(opts, :base_url_description)
    secret_description = Keyword.fetch!(opts, :secret_description)
    name_description = Keyword.fetch!(opts, :name_description)
    insecure_description = Keyword.fetch!(opts, :insecure_description)
    {extra_fields, _binding} = Code.eval_quoted(Keyword.get(opts, :extra_fields, quote(do: [])), [], __CALLER__)
    {create_accept, _binding} = Code.eval_quoted(Keyword.fetch!(opts, :create_accept), [], __CALLER__)
    {update_accept, _binding} = Code.eval_quoted(Keyword.fetch!(opts, :update_accept), [], __CALLER__)
    mapper_job_id_field = Macro.var(:mapper_job_id, nil)
    by_job_filter = quote(do: expr(unquote(mapper_job_id_field) == ^arg(:mapper_job_id)))

    common_fields = [
      {:name, :string, [description: name_description]},
      {:base_url, :string, [allow_nil?: false, description: base_url_description]},
      {secret_field, :string,
       [public?: false, sensitive?: true, description: secret_description]},
      {:insecure_skip_verify, :boolean,
       [allow_nil?: false, default: false, description: insecure_description]},
      {:mapper_job_id, :uuid, [allow_nil?: false, description: "Parent mapper job ID"]}
    ]

    quote do
      use Ash.Resource,
        domain: ServiceRadar.NetworkDiscovery,
        data_layer: AshPostgres.DataLayer,
        authorizers: [Ash.Policy.Authorizer],
        extensions: [AshCloak]

      postgres do
        table unquote(table)
        repo ServiceRadar.Repo
        schema "platform"

        custom_indexes do
          index [:mapper_job_id], name: unquote(index_name)
        end
      end

      cloak do
        vault(ServiceRadar.Vault)
        attributes([unquote(secret_field)])
        decrypt_by_default([unquote(secret_field)])
      end

      actions do
        defaults [:read, :destroy]

        create :create do
          accept unquote(create_accept)
          change unquote(normalizer_change)
        end

        update :update do
          accept unquote(update_accept)
          change unquote(normalizer_change)
        end

        read :by_job do
          argument :mapper_job_id, :uuid, allow_nil?: false
          filter unquote(by_job_filter)
        end
      end

      policies do
        import ServiceRadar.Policies

        system_bypass()
        operator_action_type([:create, :update])
        admin_action_type(:destroy)
        read_all()
      end

      attributes do
        uuid_primary_key :id
        unquote_splicing(Enum.map(common_fields ++ extra_fields, &ResourceAttributeAst.build/1))
        create_timestamp :inserted_at
        update_timestamp :updated_at
      end

      relationships do
        belongs_to :mapper_job, ServiceRadar.NetworkDiscovery.MapperJob do
          allow_nil? false
          public? true
          define_attribute? false
          source_attribute :mapper_job_id
          destination_attribute :id
        end
      end

      calculations do
        calculate unquote(secret_present_calc), :boolean, fn records, _opts ->
          Enum.map(records, fn record ->
            has_value?(Map.get(record, unquote(secret_field)))
          end)
        end
      end

      identities do
        identity :unique_base_url_per_job, [:mapper_job_id, :base_url]
      end

      defp has_value?(nil), do: false
      defp has_value?(""), do: false
      defp has_value?(value) when is_binary(value), do: byte_size(value) > 0
      defp has_value?(_), do: false
    end
  end
end
