defmodule ServiceRadar.Plugins.ActionCredentialRequirements do
  @moduledoc """
  Reads and validates the `credential_requirements` of a northbound action.

  An action's `credential_requirements` map takes one of three shapes: a
  `credentials` (or `requirements`) list, a single requirement, or a map of
  requirement name to requirement. `flatten/1` is the one reading of that shape,
  shared by manifest ingest and the northbound dispatcher, so validation and
  grant issuance cannot disagree about which requirements an action declares.

  A requirement of a plugin action may declare where its secret comes from
  instead of naming one:

    * `credential_source: assignment_schedule` with `requirement: <name>` takes
      the secret reference the credential provisioner bound into
      `credential_refs[<name>]` of the enabled producer schedule on the
      invocation's plugin assignment. `<name>` must be the
      `provisioning.credential_requirement` of one of the package's
      `producer_schedule` credential profiles.
    * `credential_source: package_rule` with `rule_input: <input key>` takes the
      secret of the credential rule whose id the operator supplied in that
      input. The id is accepted only among enabled rules provisioned for the
      same package and provider; `<input key>` must be a property of the
      action's `input_schema`.

  A declared source cannot be combined with a static secret or with an input
  that names a secret, so an invocation input can never select arbitrary
  credential material.
  """

  @sources ~w(assignment_schedule package_rule)

  @secret_keys ~w(
    credential_secret_id
    secret_id
    credential_secret_ref
    secret_ref
    credential_secret_input
    secret_input
    input_key
    credential_secret_ref_input
    secret_ref_input
  )

  @source_keys ~w(requirement rule_input)
  @name_pattern ~r/^[a-z0-9][a-z0-9_.-]*$/

  @doc "Declared credential sources a requirement may name."
  @spec sources() :: [String.t()]
  def sources, do: @sources

  @doc """
  Flattens an action's `credential_requirements` into a list of requirement maps
  with string keys. A requirement keyed by name carries that name as `"name"`
  unless it declares its own.
  """
  @spec flatten(term()) :: [map()]
  def flatten(nil), do: []

  def flatten(requirements) when is_list(requirements) do
    requirements
    |> Enum.filter(&is_map/1)
    |> Enum.map(&stringify_keys/1)
  end

  def flatten(%{} = requirements) do
    requirements = stringify_keys(requirements)

    cond do
      is_list(requirements["credentials"]) ->
        flatten(requirements["credentials"])

      is_list(requirements["requirements"]) ->
        flatten(requirements["requirements"])

      map_size(requirements) == 0 ->
        []

      requirement?(requirements) ->
        [requirements]

      true ->
        requirements
        |> Enum.filter(fn {_name, requirement} -> is_map(requirement) end)
        |> Enum.sort_by(fn {name, _requirement} -> name end)
        |> Enum.map(fn {name, requirement} ->
          requirement
          |> stringify_keys()
          |> Map.put_new("name", name)
        end)
    end
  end

  def flatten(_requirements), do: []

  @doc "True when the map is itself one credential requirement."
  @spec requirement?(map()) :: boolean()
  def requirement?(%{} = requirement) do
    requirement = stringify_keys(requirement)
    Enum.any?(["credential_source" | @secret_keys], &present?(requirement[&1]))
  end

  def requirement?(_requirement), do: false

  @doc "The declared credential source of a requirement, or nil when none is declared."
  @spec credential_source(map()) :: String.t() | nil
  def credential_source(%{} = requirement) do
    case stringify_keys(requirement)["credential_source"] do
      value when is_binary(value) -> normalize(value)
      value when is_atom(value) and not is_nil(value) -> Atom.to_string(value)
      _ -> nil
    end
  end

  @doc """
  Validates the declared credential sources of one action.

  Returns error strings rooted at `path` (for example `actions[1]`), newest
  first to match the manifest validator's accumulation order.
  """
  @spec validate(term(), term(), String.t()) :: [String.t()]
  def validate(credential_requirements, input_schema, path) do
    input_properties = input_schema_properties(input_schema)

    credential_requirements
    |> flatten()
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {requirement, index} ->
      validate_requirement(
        requirement,
        requirement_path(path, requirement, index),
        input_properties
      )
    end)
    |> Enum.reverse()
  end

  @doc """
  Checks `assignment_schedule` and `package_rule` requirements against the
  package's own credential profiles.

  `credential_profiles` is the validated `integrations.credential_profiles` list.
  """
  @spec validate_against_profiles([map()], [map()]) :: [String.t()]
  def validate_against_profiles(actions, credential_profiles) when is_list(actions) do
    scheduled_profiles =
      credential_profiles
      |> List.wrap()
      |> Enum.filter(&(get_in(&1, ["provisioning", "mode"]) == "producer_schedule"))

    bound_requirements =
      MapSet.new(scheduled_profiles, &get_in(&1, ["provisioning", "credential_requirement"]))

    actions
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {action, index} ->
      action
      |> Map.get(:credential_requirements)
      |> flatten()
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {requirement, requirement_index} ->
        path = requirement_path("actions[#{index}]", requirement, requirement_index)
        profile_errors(requirement, path, scheduled_profiles, bound_requirements)
      end)
    end)
    |> Enum.reverse()
  end

  def validate_against_profiles(_actions, _credential_profiles), do: []

  defp profile_errors(requirement, path, scheduled_profiles, bound_requirements) do
    case credential_source(requirement) do
      "assignment_schedule" ->
        name = normalize(requirement["requirement"])

        if MapSet.member?(bound_requirements, name) do
          []
        else
          [
            "#{path}.requirement must name the credential_requirement of a producer_schedule credential profile in integrations.credential_profiles"
          ]
        end

      "package_rule" when scheduled_profiles == [] ->
        [
          "#{path}.credential_source package_rule requires a producer_schedule credential profile in integrations.credential_profiles"
        ]

      _ ->
        []
    end
  end

  defp validate_requirement(requirement, path, input_keys) do
    raw_source = requirement["credential_source"]

    case credential_source(requirement) do
      nil when is_nil(raw_source) ->
        undeclared_source_errors(requirement, path)

      "assignment_schedule" ->
        common_source_errors(requirement, path, "rule_input") ++
          name_errors(requirement["requirement"], "#{path}.requirement")

      "package_rule" ->
        common_source_errors(requirement, path, "requirement") ++
          rule_input_errors(requirement["rule_input"], "#{path}.rule_input", input_keys)

      _other ->
        ["#{path}.credential_source must be one of: #{Enum.join(@sources, ", ")}"]
    end
  end

  defp undeclared_source_errors(requirement, path) do
    @source_keys
    |> Enum.filter(&Map.has_key?(requirement, &1))
    |> Enum.map(&"#{path}.#{&1} is only allowed with credential_source")
  end

  defp common_source_errors(requirement, path, foreign_key) do
    secret_errors =
      @secret_keys
      |> Enum.filter(&Map.has_key?(requirement, &1))
      |> Enum.map(
        &"#{path}.#{&1} is not allowed with credential_source; the source supplies the secret"
      )

    foreign_errors =
      if Map.has_key?(requirement, foreign_key) do
        [
          "#{path}.#{foreign_key} is not allowed with credential_source #{credential_source(requirement)}"
        ]
      else
        []
      end

    secret_errors ++ foreign_errors
  end

  defp name_errors(value, path) do
    case normalize(value) do
      nil ->
        ["#{path} must be a non-empty string"]

      name ->
        if Regex.match?(@name_pattern, name) do
          []
        else
          ["#{path} must use lowercase letters, numbers, dots, underscores, or hyphens"]
        end
    end
  end

  defp rule_input_errors(value, path, input_properties) do
    case normalize(value) do
      nil ->
        ["#{path} must be a non-empty string"]

      key ->
        case Map.get(input_properties, key) do
          %{type: "string"} -> []
          %{"type" => "string"} -> []
          _ -> ["#{path} must name a string property declared in input_schema.properties"]
        end
    end
  end

  defp requirement_path(path, requirement, index) do
    case normalize(requirement["name"]) do
      nil -> "#{path}.credential_requirements[#{index}]"
      name -> "#{path}.credential_requirements.#{name}"
    end
  end

  defp input_schema_properties(%{} = schema) do
    schema
    |> stringify_keys()
    |> Map.get("properties")
    |> case do
      %{} = properties -> properties
      _ -> %{}
    end
  end

  defp input_schema_properties(_schema), do: %{}

  defp normalize(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize(_value), do: nil

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?([]), do: false
  defp present?(%{} = value), do: map_size(value) > 0
  defp present?(_value), do: true

  defp stringify_keys(%{} = map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end
end
