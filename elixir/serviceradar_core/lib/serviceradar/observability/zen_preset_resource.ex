defmodule ServiceRadar.Observability.ZenPresetResource do
  @moduledoc false

  alias ServiceRadar.Observability.ResourceAttributeAst

  defmacro __using__(opts) do
    table = Keyword.fetch!(opts, :table)
    {fields, _binding} = Code.eval_quoted(Keyword.fetch!(opts, :fields), [], __CALLER__)
    {accept, _binding} = Code.eval_quoted(Keyword.fetch!(opts, :accept), [], __CALLER__)
    create_changes = eval_option(opts, :create_changes, __CALLER__)
    update_changes = eval_option(opts, :update_changes, __CALLER__)
    create_validations = eval_option(opts, :create_validations, __CALLER__)
    update_validations = eval_option(opts, :update_validations, __CALLER__)
    destroy_changes = eval_option(opts, :destroy_changes, __CALLER__)
    active_sort = eval_option(opts, :active_sort, __CALLER__)
    extra_actions = eval_option(opts, :extra_actions, __CALLER__) || []
    extra_code_interface = eval_option(opts, :extra_code_interface, __CALLER__) || []
    extra_operator_actions = eval_option(opts, :extra_operator_actions, __CALLER__) || []

    enabled_field = Macro.var(:enabled, nil)
    active_filter = quote(do: expr(unquote(enabled_field) == true))

    active_action_ast =
      if is_nil(active_sort) do
        []
      else
        [
          quote do
            read :active do
              filter unquote(active_filter)
              prepare build(sort: unquote(active_sort))
            end
          end
        ]
      end

    active_code_interface_ast =
      if is_nil(active_sort) do
        []
      else
        [quote(do: define(:list_active, action: :active))]
      end

    quote do
      use Ash.Resource,
        domain: ServiceRadar.Observability,
        data_layer: AshPostgres.DataLayer,
        authorizers: [Ash.Policy.Authorizer]

      postgres do
        table unquote(table)
        repo ServiceRadar.Repo
        schema "platform"
      end

      code_interface do
        define :list, action: :read
        unquote_splicing(active_code_interface_ast)
        define :create, action: :create
        define :update, action: :update
        define :destroy, action: :destroy
        unquote_splicing(extra_code_interface)
      end

      actions do
        defaults [:read]

        unquote_splicing(active_action_ast)

        create :create do
          accept unquote(accept)
          unquote_splicing(build_validations_ast(create_validations))
          unquote_splicing(build_changes_ast(create_changes))
        end

        update :update do
          accept unquote(accept)
          unquote_splicing(build_validations_ast(update_validations))
          unquote_splicing(build_changes_ast(update_changes))
        end

        destroy :destroy do
          unquote_splicing(build_changes_ast(destroy_changes))
        end

        unquote_splicing(extra_actions)
      end

      policies do
        import ServiceRadar.Policies

        system_bypass()
        read_viewer_plus()
        operator_action([:create, :update, :destroy] ++ unquote(extra_operator_actions))
      end

      attributes do
        uuid_primary_key :id
        unquote_splicing(Enum.map(fields, &ResourceAttributeAst.build/1))
        create_timestamp :inserted_at
        update_timestamp :updated_at
      end

      identities do
        identity :unique_name, [:subject, :name]
      end
    end
  end

  defp eval_option(opts, key, caller) do
    case Keyword.fetch(opts, key) do
      {:ok, value} ->
        {evaluated, _binding} = Code.eval_quoted(value, [], caller)
        evaluated

      :error ->
        nil
    end
  end

  defp build_validations_ast(nil), do: []

  defp build_validations_ast(validations) do
    Enum.map(validations, fn validation ->
      quote do
        validate unquote(validation)
      end
    end)
  end

  defp build_changes_ast(nil), do: []

  defp build_changes_ast(changes) do
    Enum.map(changes, fn change ->
      quote do
        change unquote(change)
      end
    end)
  end
end
