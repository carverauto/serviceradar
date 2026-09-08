defmodule ServiceradarConfig.ValidatorPropertyTest do
  @moduledoc """
  The Elixir half of the predicate laws.

  The vectors prove this engine agrees with Rust and Go on the committed cases; these prove it
  obeys the same laws on inputs no case table contains. StreamData shrinks a failure to a
  minimal counterexample, the same property proptest and rapid provide in the other two trees.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Serviceradar.Config.V1.{
    DatabaseConfig,
    EnvironmentConfig,
    ForbiddenIf,
    ForbiddenValue,
    IntRange,
    NonEmpty,
    OneOf,
    Required,
    RequiredIf,
    Rule,
    RuleSet
  }

  alias ServiceradarConfig.Validator

  @code "UNDER_TEST"

  @all_tls ~w(TLS_MODE_UNSPECIFIED TLS_MODE_DISABLE TLS_MODE_REQUIRE TLS_MODE_VERIFY_CA TLS_MODE_VERIFY_FULL)a
  @all_kinds ~w(ENVIRONMENT_KIND_UNSPECIFIED ENVIRONMENT_KIND_LOCALHOST ENVIRONMENT_KIND_CI
                ENVIRONMENT_KIND_SAAS ENVIRONMENT_KIND_ONPREM ENVIRONMENT_KIND_DEMO)a

  defp one(field_path, predicate) do
    %RuleSet{
      rules: [%Rule{field_path: field_path, code: @code, phase: :PHASE_CONFIG, predicate: predicate}]
    }
  end

  defp fired?(rules, cfg) do
    {:ok, violations} = Validator.validate(rules, cfg)
    Enum.any?(violations, &(&1.code == @code))
  end

  defp with_port(port), do: %EnvironmentConfig{database: %DatabaseConfig{port: port}}
  defp with_host(host), do: %EnvironmentConfig{database: %DatabaseConfig{host: host}}
  defp with_tls(mode), do: %EnvironmentConfig{database: %DatabaseConfig{tls_mode: mode}}

  # Values are drawn RELATIVE TO THE BOUNDS, not independently of them. An independent draw over
  # a large range reaches v == max only by luck, which is how the first Rust generator passed
  # against a deliberately off-by-one engine. Sampling a boundary is not testing it.
  defp boundary_relative(min, max) do
    gen all(pick <- integer(0..5), free <- integer(0..400_000)) do
      case pick do
        0 -> max(min - 1, 0)
        1 -> min
        2 -> max
        3 -> max + 1
        4 -> min + div(max - min, 2)
        _ -> free
      end
    end
  end

  property "int_range is inclusive containment" do
    check all(
            min <- integer(0..200_000),
            span <- integer(0..200_000),
            max = min + span,
            v <- boundary_relative(min, max)
          ) do
      rules = one("database.port", {:int_range, %IntRange{min: min, max: max}})
      assert fired?(rules, with_port(v)) == not (v >= min and v <= max)
    end
  end

  property "int_range is monotone in its bounds" do
    check all(
            min <- integer(0..100_000),
            span <- integer(0..100_000),
            grow_lo <- integer(0..100_000),
            grow_hi <- integer(0..100_000),
            max = min + span,
            v <- boundary_relative(min, max)
          ) do
      narrow = one("database.port", {:int_range, %IntRange{min: min, max: max}})
      wide = one("database.port", {:int_range, %IntRange{min: min - grow_lo, max: max + grow_hi}})

      if not fired?(narrow, with_port(v)) do
        refute fired?(wide, with_port(v)),
               "#{v} accepted by [#{min},#{max}] but rejected by the wider range"
      end
    end
  end

  property "one_of is membership" do
    check all(
            set <- list_of(member_of(@all_tls), max_length: 6),
            v <- member_of(@all_tls)
          ) do
      names = Enum.map(set, &Atom.to_string/1)
      rules = one("database.tls_mode", {:one_of, %OneOf{enum_values: names}})
      assert fired?(rules, with_tls(v)) == (v not in set)
    end
  end

  property "forbidden_value is disequality" do
    check all(x <- member_of(@all_tls), v <- member_of(@all_tls)) do
      rules =
        one("database.tls_mode", {:forbidden_value, %ForbiddenValue{enum_value: Atom.to_string(x)}})

      assert fired?(rules, with_tls(v)) == (x == v)
    end
  end

  property "non_empty is length" do
    check all(v <- string(:printable)) do
      rules = one("database.host", {:non_empty, %NonEmpty{}})
      assert fired?(rules, with_host(v)) == (v == "")
    end
  end

  property "required is the negation of absence" do
    check all(v <- one_of([constant(nil), string(:printable)])) do
      rules = one("database.host", {:required, %Required{}})
      assert fired?(rules, with_host(v)) == is_nil(v)
    end
  end

  property "conditional predicates fire only on trigger and presence" do
    others = @all_kinds |> Enum.reject(&(&1 == :ENVIRONMENT_KIND_ONPREM)) |> Enum.map(&Atom.to_string/1)

    check all(kind <- member_of(@all_kinds), present <- boolean()) do
      instance = if present, do: "x", else: nil
      cfg = %EnvironmentConfig{kind: kind, instance: instance}
      onprem = kind == :ENVIRONMENT_KIND_ONPREM

      required_if =
        one("instance", {:required_if, %RequiredIf{
          other_field_path: "kind",
          other_enum_value: "ENVIRONMENT_KIND_ONPREM"
        }})

      assert fired?(required_if, cfg) == (onprem and not present)

      forbidden_if =
        one("instance", {:forbidden_if, %ForbiddenIf{
          other_field_path: "kind",
          other_enum_values: others
        }})

      assert fired?(forbidden_if, cfg) == (not onprem and present)
    end
  end
end
