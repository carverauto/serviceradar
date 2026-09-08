defmodule ServiceradarConfig.Manager.LoadError do
  @moduledoc "Why no configuration could be returned. Every variant names its source."

  alias ServiceradarConfig.Manager.Identity

  @spec message(term()) :: String.t()
  def message({:unknown_built_in, _source, name, available}) do
    "no configuration named #{inspect(name)} is built into this release. " <>
      "Available: #{Enum.join(available, ", ")}."
  end

  def message({:read, source, reason}),
    do: "cannot read configuration from #{source}: #{inspect(reason)}"

  def message({:decode, source, detail}),
    do: "configuration from #{source} is not an EnvironmentConfig: #{detail}"

  def message({:rule_set, reason}),
    do: "the rule set names a field the schema lacks: #{inspect(reason)}"

  def message({:invalid, source, violations}) do
    lines =
      Enum.map_join(violations, "\n", fn v ->
        "  #{String.pad_trailing(v.field_path, 34)} #{v.code}"
      end)

    "configuration from #{source} is invalid:\n" <> lines
  end

  # The consequence, not merely the difference: the component would connect to the wrong database
  # while believing it was right.
  def message({:identity_mismatch, source, selected, found}) do
    "#{Identity.env_var()}=#{selected} but #{source} describes #{found}. " <>
      "The wrong artifact is mounted: this component would connect to #{found}'s database " <>
      "believing it is #{selected}."
  end
end
