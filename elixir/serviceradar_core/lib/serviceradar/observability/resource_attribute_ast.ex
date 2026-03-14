defmodule ServiceRadar.Observability.ResourceAttributeAst do
  @moduledoc false

  def build({name, type, opts}) do
    allow_nil? = Keyword.get(opts, :allow_nil?, true)
    public? = Keyword.get(opts, :public?, true)
    primary_key? = Keyword.get(opts, :primary_key?, false)
    default = Keyword.get(opts, :default, :__no_default__)
    description = Keyword.get(opts, :description)
    constraints = Keyword.get(opts, :constraints)

    extra_clauses =
      []
      |> maybe_primary_key(primary_key?)
      |> maybe_default(default)
      |> maybe_description(description)
      |> maybe_constraints(constraints)

    quote do
      attribute unquote(name), unquote(type) do
        unquote_splicing(extra_clauses)
        allow_nil? unquote(allow_nil?)
        public? unquote(public?)
      end
    end
  end

  defp maybe_primary_key(clauses, false), do: clauses
  defp maybe_primary_key(clauses, true), do: clauses ++ [quote(do: primary_key? true)]

  defp maybe_default(clauses, :__no_default__), do: clauses
  defp maybe_default(clauses, default) do
    clauses ++ [quote(do: default(unquote(Macro.escape(default))))]
  end

  defp maybe_description(clauses, nil), do: clauses
  defp maybe_description(clauses, description),
    do: clauses ++ [quote(do: description(unquote(Macro.escape(description))))]

  defp maybe_constraints(clauses, nil), do: clauses

  defp maybe_constraints(clauses, constraints) do
    clauses ++ [quote(do: constraints(unquote(Macro.escape(constraints))))]
  end
end
