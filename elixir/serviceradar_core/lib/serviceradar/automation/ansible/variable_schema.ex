defmodule ServiceRadar.Automation.Ansible.VariableSchema do
  @moduledoc """
  Normalizes a `Playbook`'s declared variables into a uniform shape the
  launch form can render as typed inputs.

  AWX survey_spec and Ansible vars_prompt are two different sources with
  overlapping intent. This module flattens both into `[%Var{}]` with a
  consistent set of fields. The LaunchLive page renders one input per
  entry; on submit it collects values back into an `extra_vars` map.

  ## Sources

    * **AWX-sourced playbooks** (`source_type: :awx`) carry an AWX
      survey_spec on `playbook.survey_spec` -- a map with a `"spec"`
      list of entries shaped like:
      `%{"question_name", "variable", "type", "required", "default", "choices"}`.
    * **Git-sourced playbooks** (`source_type: :git`) carry an Ansible
      `vars_prompt` list on `playbook.vars_prompt` -- entries shaped
      like `%{"name", "prompt", "default", "private", "confirm"}`.

  Anything we can't categorize gets `type: :text`, which is correct in
  the default Ansible vars_prompt case (text input with no special
  treatment).
  """

  defmodule Var do
    @moduledoc false
    defstruct [
      :name,
      :label,
      :type,
      :default,
      :required,
      :private,
      :choices,
      :min,
      :max,
      :help
    ]

    @type t :: %__MODULE__{
            name: String.t(),
            label: String.t(),
            type: :text | :textarea | :password | :integer | :float | :select | :multiselect,
            default: any(),
            required: boolean(),
            private: boolean(),
            choices: [String.t()],
            min: integer() | nil,
            max: integer() | nil,
            help: String.t() | nil
          }
  end

  @doc """
  Normalize a Playbook into a list of `%Var{}`. Returns `[]` when no
  variables are declared.

  Git-sourced playbooks surface their `vars_prompt` entries first,
  followed by any top-level `declared_vars` (the plain `vars:` block the
  git catalog sync extracts) that are not already covered by a
  `vars_prompt` of the same name. Declared vars are pre-filled with their
  defaults, optional, and get their input type inferred from the default
  value. `vars_prompt` wins on a name collision so an interactive prompt
  is never shadowed by the static default.
  """
  @spec from_playbook(map()) :: [Var.t()]
  def from_playbook(%{source_type: :awx, survey_spec: spec}) when is_map(spec),
    do: from_awx_survey(spec)

  def from_playbook(%{source_type: :git} = playbook) do
    prompts = playbook |> Map.get(:vars_prompt, []) |> List.wrap()
    declared = Map.get(playbook, :declared_vars, %{})
    from_git_sources(prompts, declared)
  end

  def from_playbook(_), do: []

  @doc false
  @spec from_git_sources([map()], map()) :: [Var.t()]
  def from_git_sources(prompts, declared) do
    prompt_vars = from_vars_prompt(List.wrap(prompts))
    taken_names = MapSet.new(prompt_vars, & &1.name)
    prompt_vars ++ declared_vars(declared, taken_names)
  end

  defp declared_vars(declared, taken_names) when is_map(declared) do
    declared
    |> Enum.map(fn {name, default} -> {to_string(name), default} end)
    |> Enum.reject(fn {name, _default} -> name == "" or MapSet.member?(taken_names, name) end)
    |> Enum.sort_by(fn {name, _default} -> name end)
    |> Enum.map(&declared_var/1)
  end

  defp declared_vars(_declared, _taken_names), do: []

  defp declared_var({name, default}) do
    %Var{
      name: name,
      label: name,
      type: declared_type(default),
      default: default,
      required: false,
      private: false,
      choices: [],
      min: nil,
      max: nil,
      help: nil
    }
  end

  # Booleans and strings both render as text inputs (the pre-filled default
  # carries the value); only numeric defaults get numeric inputs.
  defp declared_type(value) when is_integer(value), do: :integer
  defp declared_type(value) when is_float(value), do: :float
  defp declared_type(_value), do: :text

  @doc false
  @spec from_awx_survey(map()) :: [Var.t()]
  def from_awx_survey(spec) when is_map(spec) do
    spec
    |> Map.get("spec", [])
    |> List.wrap()
    |> Enum.map(&awx_survey_entry/1)
    |> Enum.reject(&is_nil/1)
  end

  defp awx_survey_entry(%{} = entry) do
    name = string(entry["variable"]) || string(entry["name"]) || ""

    if name == "" do
      nil
    else
      type = awx_type(entry["type"])

      %Var{
        name: name,
        label: string(entry["question_name"]) || string(entry["name"]) || name,
        type: type,
        default: entry["default"],
        required: !!entry["required"],
        private: type == :password,
        choices: parse_choices(entry["choices"], type),
        min: integer_or_nil(entry["min"]),
        max: integer_or_nil(entry["max"]),
        help: string(entry["question_description"])
      }
    end
  end

  defp awx_survey_entry(_), do: nil

  defp awx_type("text"), do: :text
  defp awx_type("textarea"), do: :textarea
  defp awx_type("password"), do: :password
  defp awx_type("integer"), do: :integer
  defp awx_type("float"), do: :float
  defp awx_type("multiplechoice"), do: :select
  defp awx_type("multiselect"), do: :multiselect
  defp awx_type(_), do: :text

  defp parse_choices(nil, _type), do: []
  defp parse_choices("", _type), do: []

  defp parse_choices(raw, type) when is_binary(raw) and type in [:select, :multiselect] do
    raw
    |> String.split(["\n", ","])
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_choices(list, _type) when is_list(list), do: Enum.map(list, &to_string/1)
  defp parse_choices(_, _), do: []

  @doc false
  @spec from_vars_prompt([map()]) :: [Var.t()]
  def from_vars_prompt(prompts) when is_list(prompts) do
    prompts
    |> Enum.filter(&is_map/1)
    |> Enum.map(&vars_prompt_entry/1)
    |> Enum.reject(&is_nil/1)
  end

  defp vars_prompt_entry(%{} = entry) do
    name = string(entry["name"]) || string(entry[:name]) || ""

    if name == "" do
      nil
    else
      private? =
        case entry["private"] || entry[:private] do
          true -> true
          "yes" -> true
          "true" -> true
          _ -> false
        end

      %Var{
        name: name,
        label: string(entry["prompt"]) || string(entry[:prompt]) || name,
        type: if(private?, do: :password, else: :text),
        default: entry["default"] || entry[:default],
        required: false,
        private: private?,
        choices: [],
        min: nil,
        max: nil,
        help: nil
      }
    end
  end

  defp vars_prompt_entry(_), do: nil

  @doc """
  Apply form-submission values to a variable schema, producing the
  `extra_vars` map AWX expects. String values get coerced to integers /
  floats per the variable's declared type. Empty strings collapse to
  the variable's default (when any) or are dropped.
  """
  @spec extra_vars_from_form([Var.t()], map()) :: map()
  def extra_vars_from_form(vars, form_params) when is_list(vars) and is_map(form_params) do
    Enum.reduce(vars, %{}, fn %Var{} = var, acc ->
      case coerce(var, Map.get(form_params, var.name)) do
        :drop -> acc
        value -> Map.put(acc, var.name, value)
      end
    end)
  end

  def extra_vars_from_form(_, _), do: %{}

  @doc """
  Validates and canonicalizes inputs for the hardened launch path.

  ServiceRadar does not collect secret launch values. A schema containing a
  private/password field is non-launchable until the value is moved into a
  reviewed pre-bound AWX credential. Unknown fields and invalid typed values
  fail instead of being silently dropped.
  """
  @spec validated_non_secret_inputs([Var.t()], map()) ::
          {:ok, map()} | {:error, term()}
  def validated_non_secret_inputs(vars, params) when is_list(vars) and is_map(params) do
    vars_by_name = Map.new(vars, &{&1.name, &1})

    sensitive =
      vars
      |> Enum.filter(&(&1.private == true or &1.type == :password))
      |> Enum.map(& &1.name)
      |> Enum.sort()

    normalized_params = Map.new(params, fn {key, value} -> {to_string(key), value} end)

    unknown =
      normalized_params
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(vars_by_name, &1))
      |> Enum.sort()

    cond do
      sensitive != [] ->
        {:error, {:sensitive_launch_inputs, sensitive}}

      unknown != [] ->
        {:error, {:undeclared_launch_inputs, unknown}}

      true ->
        with {:ok, inputs} <- strict_inputs(vars, normalized_params),
             :ok <- bounded_inputs(inputs) do
          {:ok, inputs}
        end
    end
  end

  def validated_non_secret_inputs(_vars, _params), do: {:error, :invalid_launch_inputs}

  defp strict_inputs(vars, params) do
    Enum.reduce_while(vars, {:ok, %{}}, fn %Var{} = var, {:ok, acc} ->
      case strict_value(var, Map.fetch(params, var.name)) do
        {:ok, :drop} -> {:cont, {:ok, acc}}
        {:ok, value} -> {:cont, {:ok, Map.put(acc, var.name, value)}}
        {:error, reason} -> {:halt, {:error, {reason, var.name}}}
      end
    end)
  end

  defp strict_value(%Var{required: true}, :error), do: {:error, :required_launch_input}
  defp strict_value(_var, :error), do: {:ok, :drop}
  defp strict_value(%Var{required: true}, {:ok, ""}), do: {:error, :required_launch_input}
  defp strict_value(_var, {:ok, ""}), do: {:ok, :drop}

  defp strict_value(%Var{type: :integer, min: min, max: max}, {:ok, value}) do
    with {:ok, parsed} <- strict_integer(value),
         :ok <- within_bounds(parsed, min, max) do
      {:ok, parsed}
    end
  end

  defp strict_value(%Var{type: :float, min: min, max: max}, {:ok, value}) do
    with {:ok, parsed} <- strict_float(value),
         :ok <- within_bounds(parsed, min, max) do
      {:ok, parsed}
    end
  end

  defp strict_value(%Var{type: :select, choices: choices}, {:ok, value}) do
    value = to_string(value)

    if choices == [] or value in choices,
      do: {:ok, value},
      else: {:error, :invalid_launch_choice}
  end

  defp strict_value(%Var{type: :multiselect, choices: choices}, {:ok, value}) do
    selected =
      case value do
        list when is_list(list) ->
          Enum.map(list, &to_string/1)

        string when is_binary(string) ->
          string |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

        _ ->
          :invalid
      end

    cond do
      selected == :invalid ->
        {:error, :invalid_launch_choice}

      choices != [] and not Enum.all?(selected, &(&1 in choices)) ->
        {:error, :invalid_launch_choice}

      true ->
        {:ok, Enum.uniq(selected)}
    end
  end

  defp strict_value(%Var{type: type}, {:ok, value}) when type in [:text, :textarea] do
    if is_binary(value), do: {:ok, value}, else: {:error, :invalid_launch_input}
  end

  defp strict_value(_var, _value), do: {:error, :invalid_launch_input}

  defp strict_integer(value) when is_integer(value), do: {:ok, value}

  defp strict_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> {:ok, parsed}
      _ -> {:error, :invalid_launch_input}
    end
  end

  defp strict_integer(_), do: {:error, :invalid_launch_input}

  defp strict_float(value) when is_float(value), do: {:ok, value}
  defp strict_float(value) when is_integer(value), do: {:ok, value / 1}

  defp strict_float(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> {:ok, parsed}
      _ -> {:error, :invalid_launch_input}
    end
  end

  defp strict_float(_), do: {:error, :invalid_launch_input}

  defp within_bounds(value, min, _max) when is_number(min) and value < min,
    do: {:error, :launch_input_out_of_bounds}

  defp within_bounds(value, _min, max) when is_number(max) and value > max,
    do: {:error, :launch_input_out_of_bounds}

  defp within_bounds(_value, _min, _max), do: :ok

  defp bounded_inputs(inputs) do
    if :erlang.external_size(inputs) <= 65_536 do
      :ok
    else
      {:error, :launch_inputs_too_large}
    end
  end

  defp coerce(_var, nil), do: :drop

  defp coerce(%Var{type: :integer}, ""), do: :drop

  defp coerce(%Var{type: :integer}, val) when is_binary(val) do
    case Integer.parse(val) do
      {n, ""} -> n
      _ -> :drop
    end
  end

  defp coerce(%Var{type: :float}, ""), do: :drop

  defp coerce(%Var{type: :float}, val) when is_binary(val) do
    case Float.parse(val) do
      {n, ""} -> n
      _ -> :drop
    end
  end

  defp coerce(%Var{type: :multiselect}, val) when is_list(val), do: val
  defp coerce(%Var{type: :multiselect}, ""), do: :drop

  defp coerce(%Var{type: :multiselect}, val) when is_binary(val) do
    val |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  defp coerce(_var, ""), do: :drop
  defp coerce(_var, val) when is_binary(val), do: val
  defp coerce(_var, val), do: val

  ## Helpers ------------------------------------------------------------------

  defp string(nil), do: nil
  defp string(""), do: nil
  defp string(s) when is_binary(s), do: s
  defp string(other) when is_integer(other) or is_float(other), do: to_string(other)
  defp string(_), do: nil

  defp integer_or_nil(n) when is_integer(n), do: n
  defp integer_or_nil(_), do: nil
end
