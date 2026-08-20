defmodule ServiceradarConfig.Validator do
  @moduledoc """
  Evaluates the committed rule set against an environment instance.

  This is an implementation of `config/SEMANTICS.md`, not a second definition of it. Where this
  module and that document disagree, the document is right and this is a bug -- which is what
  the shared conformance vectors under `//config/rules/fixtures` exist to detect.

  Decision 12 requires every implementation to validate at LOAD, so this runs on the boot path
  and not only in tests.

  One deliberate divergence from the document is recorded here: SEMANTICS.md specifies RE2 for
  `matches`, and the BEAM has no RE2 -- `Regex` is PCRE. Every pattern in the committed rule set
  is a simple anchored prefix or character class on which the two agree, and the conformance
  vectors compare the outcome rather than the engine. A pattern using PCRE-only syntax
  (backreferences, lookaround) would pass here and fail the other two implementations, so do not
  add one.
  """

  alias Serviceradar.Config.V1.{EnvironmentConfig, Rule, RuleSet}

  defmodule Violation do
    @moduledoc "One rule that fired, identified by the pair the vectors compare."
    defstruct [:field_path, :code, :description]
  end

  @typedoc """
  A field flattened to the shapes the predicate vocabulary can talk about. `:absent` is a
  first-class value: only `required` treats it as a violation.
  """
  @type value :: :absent | {:str, String.t()} | {:num, non_neg_integer()} | {:enum, String.t()}

  @doc """
  Every file-phase violation in `cfg`, ordered by `{field_path, code}`.

  Returns `{:error, {:unknown_field, path}}` when a rule names a field the schema lacks. A hard
  error rather than a skipped rule: a rule that silently never fires is the failure this system
  exists to remove.
  """
  @spec validate(RuleSet.t(), EnvironmentConfig.t()) ::
          {:ok, [Violation.t()]} | {:error, {:unknown_field, String.t()}}
  def validate(%RuleSet{rules: rules}, %EnvironmentConfig{} = cfg) do
    rules
    |> Enum.filter(&applies?(&1, cfg))
    # Cascading: an absent field required by one rule reports once. Other predicates on the same
    # path return :not_applicable for absence anyway, but a path whose `required` already fired
    # is skipped outright, so the guarantee does not depend on each predicate's manners.
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn rule, {:ok, acc, failed} ->
      path = rule.field_path || ""

      if MapSet.member?(failed, path) do
        {:cont, {:ok, acc, failed}}
      else
        case evaluate(rule, cfg) do
          {:error, _} = err ->
            {:halt, err}

          {:ok, :violated} ->
            failed = if required?(rule), do: MapSet.put(failed, path), else: failed
            violation = %Violation{
              field_path: path,
              code: rule.code || "",
              description: rule.description || ""
            }

            {:cont, {:ok, [violation | acc], failed}}

          {:ok, _} ->
            {:cont, {:ok, acc, failed}}
        end
      end
    end)
    |> case do
      {:ok, acc, _} -> {:ok, Enum.sort_by(acc, &{&1.field_path, &1.code})}
      {:error, _} = err -> err
    end
  end

  defp required?(%Rule{predicate: {:required, _}}), do: true
  defp required?(_), do: false

  defp applies?(%Rule{} = rule, cfg), do: phase_applies?(rule.phase) and in_scope?(rule.scope, cfg)

  # A file-phase validator sees configuration alone, so a rule needing resolved secrets is
  # skipped rather than reported NotApplicable -- it was never in scope.
  defp phase_applies?(:PHASE_CONFIG), do: true
  defp phase_applies?(:PHASE_BOTH), do: true
  defp phase_applies?(_), do: false

  defp in_scope?(nil, _cfg), do: true
  defp in_scope?(_scope, %EnvironmentConfig{kind: nil}), do: true

  defp in_scope?(scope, %EnvironmentConfig{kind: kind}) do
    cond do
      kind in (scope.except_kinds || []) -> false
      scope.kinds in [nil, []] -> true
      true -> kind in scope.kinds
    end
  end

  defp evaluate(%Rule{} = rule, cfg) do
    with {:ok, value} <- field(cfg, rule.field_path || "") do
      apply_predicate(rule.predicate, value, cfg)
    end
  end

  defp apply_predicate({:required, _}, :absent, _cfg), do: {:ok, :violated}
  defp apply_predicate({:required, _}, _value, _cfg), do: {:ok, :satisfied}

  defp apply_predicate({:non_empty, _}, :absent, _cfg), do: {:ok, :not_applicable}
  defp apply_predicate({:non_empty, _}, {:str, ""}, _cfg), do: {:ok, :violated}
  defp apply_predicate({:non_empty, _}, _value, _cfg), do: {:ok, :satisfied}

  defp apply_predicate({:int_range, range}, {:num, n}, _cfg) do
    lo = range.min || -9_223_372_036_854_775_808
    hi = range.max || 9_223_372_036_854_775_807
    {:ok, if(n < lo or n > hi, do: :violated, else: :satisfied)}
  end

  defp apply_predicate({:int_range, _}, _value, _cfg), do: {:ok, :not_applicable}

  defp apply_predicate({:one_of, one_of}, {:enum, name}, _cfg),
    do: {:ok, member(one_of.enum_values, name)}

  defp apply_predicate({:one_of, one_of}, {:str, s}, _cfg),
    do: {:ok, member(one_of.string_values, s)}

  defp apply_predicate({:one_of, _}, _value, _cfg), do: {:ok, :not_applicable}

  defp apply_predicate({:matches, matches}, {:str, s}, _cfg) do
    pattern = matches.pattern || ""

    case Regex.compile(pattern) do
      {:ok, regex} -> {:ok, if(Regex.match?(regex, s), do: :satisfied, else: :violated)}
      {:error, reason} -> {:error, {:bad_pattern, pattern, reason}}
    end
  end

  defp apply_predicate({:matches, _}, _value, _cfg), do: {:ok, :not_applicable}

  defp apply_predicate({:required_if, cond_}, value, cfg) do
    with {:ok, other} <- field(cfg, cond_.other_field_path || "") do
      triggered =
        triggered?(other, List.wrap(cond_.other_enum_value), List.wrap(cond_.other_string_value))

      cond do
        not triggered -> {:ok, :not_applicable}
        value == :absent -> {:ok, :violated}
        true -> {:ok, :satisfied}
      end
    end
  end

  defp apply_predicate({:forbidden_value, forbidden}, {:enum, name}, _cfg),
    do: {:ok, if(forbidden.enum_value == name, do: :violated, else: :satisfied)}

  defp apply_predicate({:forbidden_value, forbidden}, {:str, s}, _cfg),
    do: {:ok, if(forbidden.string_value == s, do: :violated, else: :satisfied)}

  defp apply_predicate({:forbidden_value, _}, :absent, _cfg), do: {:ok, :not_applicable}
  defp apply_predicate({:forbidden_value, _}, _value, _cfg), do: {:ok, :satisfied}

  # Absence is what the predicate wants; there is nothing to forbid.
  defp apply_predicate({:forbidden_if, _}, :absent, _cfg), do: {:ok, :not_applicable}

  defp apply_predicate({:forbidden_if, cond_}, _value, cfg) do
    with {:ok, other} <- field(cfg, cond_.other_field_path || "") do
      triggered =
        triggered?(other, cond_.other_enum_values || [], cond_.other_string_values || [])

      {:ok, if(triggered, do: :violated, else: :satisfied)}
    end
  end

  # Ranges over instances rather than within one, so a single-instance pass cannot decide it.
  defp apply_predicate({:equal_across_envs, _}, _value, _cfg), do: {:ok, :not_applicable}
  defp apply_predicate(nil, _value, _cfg), do: {:ok, :not_applicable}

  defp member(set, v), do: if(v in (set || []), do: :satisfied, else: :violated)

  defp triggered?({:enum, name}, enums, _strs), do: member(enums, name) == :satisfied
  defp triggered?({:str, s}, _enums, strs), do: member(strs, s) == :satisfied
  defp triggered?(_other, _enums, _strs), do: false

  # Field access is an explicit match rather than reflection. The schema is closed and small,
  # and the payoff is that a rule naming a field that does not exist is a hard error here
  # instead of a silently skipped rule.
  defp field(cfg, path) do
    case path do
      "kind" -> {:ok, enum_value(cfg.kind)}
      "instance" -> {:ok, str_value(cfg.instance)}
      "database." <> rest -> section(cfg.database, rest, path, &database_field/2)
      "nats." <> rest -> section(cfg.nats, rest, path, &nats_field/2)
      "core." <> rest -> section(cfg.core, rest, path, &core_field/2)
      "dgraph." <> rest -> section(cfg.dgraph, rest, path, &dgraph_field/2)
      _ -> {:error, {:unknown_field, path}}
    end
  end

  # An absent SECTION is not an unknown field: the path is real, the value is absent. Only a
  # name the schema does not have is an error.
  defp section(nil, rest, path, reader) do
    case reader.(%{}, rest) do
      :unknown -> {:error, {:unknown_field, path}}
      _ -> {:ok, :absent}
    end
  end

  defp section(struct, rest, path, reader) do
    case reader.(struct, rest) do
      :unknown -> {:error, {:unknown_field, path}}
      value -> {:ok, value}
    end
  end

  defp database_field(d, "host"), do: str_value(Map.get(d, :host))
  defp database_field(d, "port"), do: num_value(Map.get(d, :port))
  defp database_field(d, "database"), do: str_value(Map.get(d, :database))
  defp database_field(d, "connecting_role"), do: str_value(Map.get(d, :connecting_role))
  defp database_field(d, "owning_role"), do: str_value(Map.get(d, :owning_role))
  defp database_field(d, "tls_mode"), do: enum_value(Map.get(d, :tls_mode))
  defp database_field(d, "tls_server_name"), do: str_value(Map.get(d, :tls_server_name))
  defp database_field(d, "admin_role"), do: str_value(Map.get(d, :admin_role))
  defp database_field(d, "ca_bundle_url"), do: str_value(Map.get(d, :ca_bundle_url))
  defp database_field(d, "search_path"), do: str_value(Map.get(d, :search_path))
  defp database_field(d, "pool_size"), do: num_value(Map.get(d, :pool_size))
  defp database_field(d, "queue_target_ms"), do: num_value(Map.get(d, :queue_target_ms))
  defp database_field(d, "queue_interval_ms"), do: num_value(Map.get(d, :queue_interval_ms))
  defp database_field(d, "ownership_timeout_ms"), do: num_value(Map.get(d, :ownership_timeout_ms))
  defp database_field(_d, _), do: :unknown

  defp nats_field(n, "url"), do: str_value(Map.get(n, :url))
  defp nats_field(n, "server_name"), do: str_value(Map.get(n, :server_name))
  defp nats_field(_n, _), do: :unknown

  defp core_field(c, "address"), do: str_value(Map.get(c, :address))
  defp core_field(c, "api_url"), do: str_value(Map.get(c, :api_url))
  defp core_field(c, "security_mode"), do: enum_value(Map.get(c, :security_mode))
  defp core_field(c, "server_name"), do: str_value(Map.get(c, :server_name))
  defp core_field(c, "trust_domain"), do: str_value(Map.get(c, :trust_domain))
  defp core_field(c, "server_spiffe_id"), do: str_value(Map.get(c, :server_spiffe_id))
  defp core_field(c, "workload_socket"), do: str_value(Map.get(c, :workload_socket))
  defp core_field(_c, _), do: :unknown

  defp dgraph_field(d, "host"), do: str_value(Map.get(d, :host))
  defp dgraph_field(d, "port"), do: num_value(Map.get(d, :port))
  defp dgraph_field(d, "tls_mode"), do: enum_value(Map.get(d, :tls_mode))
  defp dgraph_field(d, "ca_bundle_url"), do: str_value(Map.get(d, :ca_bundle_url))
  defp dgraph_field(_d, _), do: :unknown

  defp str_value(nil), do: :absent
  defp str_value(s) when is_binary(s), do: {:str, s}

  defp num_value(nil), do: :absent
  defp num_value(n) when is_integer(n), do: {:num, n}

  defp enum_value(nil), do: :absent
  defp enum_value(a) when is_atom(a), do: {:enum, Atom.to_string(a)}
  # A value outside the enum decodes as an integer. It names nothing, so no rule can match it.
  defp enum_value(n) when is_integer(n), do: {:enum, Integer.to_string(n)}
end
