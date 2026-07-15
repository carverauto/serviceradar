defmodule ServiceRadar.Automation.Ansible.VariableSchema do
  @moduledoc """
  Normalizes Ansible variable definitions into a uniform typed-input shape.

  Legacy catalog and northbound views can still derive display fields from a
  mutable playbook survey with `from_playbook/1`. Secure human launch surfaces
  and `SecureChildLauncher` use only `from_binding/1`, which parses the
  immutable reviewed binding contract and fails closed.

  AWX survey_spec and Ansible vars_prompt are two different sources with
  overlapping intent. This module flattens both into `[%Var{}]` with a
  consistent set of fields.

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

  alias ServiceRadar.Automation.Ansible.DispatchMarkerContract

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

  @binding_input_name ~r/\A[A-Za-z_][A-Za-z0-9_]{0,127}\z/
  @sensitive_input_tokens MapSet.new(~w(
                            authorization bearer credential credentials passwd password secret token
                          ))
  @sensitive_input_token_pairs MapSet.new(~w(
                                 access_key access_token api_key api_token bearer_token
                                 client_secret credential_value private_key
                               ))
  @sensitive_input_compounds MapSet.new(~w(
                              accesskey accesstoken apikey apitoken bearertoken
                              clientsecret credentialvalue privatekey
                            ))
  @binding_definition_keys MapSet.new([
                             "type",
                             "required",
                             "choices",
                             "min",
                             "max",
                             "label",
                             "help"
                           ])
  @reserved_binding_inputs MapSet.new([
                             "allowed_callback_origin",
                             "allowed_origin",
                             "callback_manifest_sha256",
                             "callback_operation",
                             "callback_origin",
                             "callback_phase",
                             "callback_policy",
                             "callback_response_policy_provider",
                             "callback_state",
                             "callback_url",
                             "desired_state",
                             "manifest_sha256",
                             "operation",
                             "phase",
                             "remote_access_operation",
                             "response_policy_provider",
                             "serviceradar_dispatch_id",
                             "serviceradar_snapshot_digest",
                             "state"
                           ])
  @ansible_magic_inputs MapSet.new([
                          "group_names",
                          "groups",
                          "hostvars",
                          "inventory_dir",
                          "inventory_file",
                          "inventory_hostname",
                          "inventory_hostname_short",
                          "omit",
                          "play_hosts",
                          "playbook_dir",
                          "role_name",
                          "role_path"
                        ])
  @binding_input_types [:text, :textarea, :integer, :float, :select, :multiselect]
  @binding_input_classes ["public", "internal"]
  @max_binding_inputs 100

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

  @doc """
  Parses the immutable input contract on a reviewed AWX template binding.

  This is the sole parser used by secure launch preparation and dispatch. It
  rejects unknown definition keys, duplicate normalized names, secret-like or
  callback-reserved names, unsupported types, invalid choices/bounds, and an
  incomplete input-classification map. It never derives fields from the mutable
  AWX survey at launch time.
  """
  @spec from_binding(map()) :: {:ok, [Var.t()]} | {:error, term()}
  def from_binding(binding) when is_map(binding) do
    schema = map_value(binding, :input_schema)
    classifications = map_value(binding, :input_classifications)

    with {:ok, vars} <- from_binding_schema(schema),
         :ok <- binding_classifications(vars, classifications) do
      {:ok, vars}
    end
  end

  def from_binding(_binding), do: {:error, :binding_input_schema_invalid}

  @doc false
  @spec from_binding_schema(map()) :: {:ok, [Var.t()]} | {:error, term()}
  def from_binding_schema(schema)
      when is_map(schema) and map_size(schema) <= @max_binding_inputs do
    entries =
      schema
      |> Enum.map(fn {name, definition} -> {to_string(name), definition} end)
      |> Enum.sort_by(&elem(&1, 0))

    names = Enum.map(entries, &elem(&1, 0))
    normalized_names = Enum.map(names, &String.downcase/1)

    if length(normalized_names) == length(Enum.uniq(normalized_names)) do
      entries
      |> Enum.reduce_while({:ok, []}, fn {name, definition}, {:ok, acc} ->
        case binding_var(name, definition) do
          {:ok, var} -> {:cont, {:ok, [var | acc]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, vars} -> {:ok, Enum.reverse(vars)}
        error -> error
      end
    else
      {:error, :binding_input_schema_invalid}
    end
  end

  def from_binding_schema(_schema), do: {:error, :binding_input_schema_invalid}

  @doc "Returns true only for a non-secret input name that cannot alter Ansible target or transport scope."
  @spec reviewed_input_name?(term()) :: boolean()
  def reviewed_input_name?(name) when is_binary(name) do
    normalized = String.downcase(name)

    Regex.match?(@binding_input_name, name) and
      not sensitive_input_name?(name) and
      not String.starts_with?(normalized, "ansible_") and
      not MapSet.member?(@reserved_binding_inputs, normalized) and
      not MapSet.member?(@ansible_magic_inputs, normalized)
  end

  def reviewed_input_name?(_name), do: false

  # Keep this identifier tokenization in parity with the AWX catalog plugin.
  # Underscores, camel-case/acronym transitions, and letter/digit transitions
  # are boundaries so spelling changes cannot turn a secret survey input into a
  # reviewed non-secret binding input.
  defp sensitive_input_name?(name) do
    compact = name |> String.downcase() |> String.replace("_", "")

    tokens =
      name
      |> String.replace(~r/([A-Z]+)([A-Z][a-z])/, "\\1_\\2")
      |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1_\\2")
      |> String.replace(~r/([A-Za-z])([0-9])/, "\\1_\\2")
      |> String.replace(~r/([0-9])([A-Za-z])/, "\\1_\\2")
      |> String.downcase()
      |> String.split("_", trim: true)

    Enum.any?(@sensitive_input_compounds, &String.contains?(compact, &1)) or
      Enum.any?(tokens, &MapSet.member?(@sensitive_input_tokens, &1)) or
      tokens
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.any?(fn [left, right] ->
        MapSet.member?(@sensitive_input_token_pairs, "#{left}_#{right}")
      end)
  end

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
    |> Enum.reject(&DispatchMarkerContract.reserved_name?(&1.name))
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

    normalized_entries = Enum.map(params, fn {key, value} -> {to_string(key), value} end)
    normalized_params = Map.new(normalized_entries)
    normalized_params_unique? = length(normalized_entries) == map_size(normalized_params)

    unknown =
      normalized_params
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(vars_by_name, &1))
      |> Enum.sort()

    cond do
      not normalized_params_unique? ->
        {:error, :ambiguous_launch_inputs}

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

  defp binding_var(name, definition) when is_binary(name) and is_map(definition) do
    keys = definition |> Map.keys() |> MapSet.new(&to_string/1)
    required = map_value(definition, :required)
    choices = map_value(definition, :choices)
    min = map_value(definition, :min)
    max = map_value(definition, :max)
    label = map_value(definition, :label)
    help = map_value(definition, :help)

    with :ok <- binding_input_name(name),
         :ok <- binding_definition_keys(definition, keys),
         {:ok, type} <- binding_variable_type(map_value(definition, :type)),
         {:ok, required?} <- binding_required(required),
         {:ok, normalized_choices} <- binding_choices(type, choices),
         :ok <- binding_bounds(type, min, max),
         :ok <- optional_binding_text(label, 255),
         :ok <- optional_binding_text(help, 2_048) do
      {:ok,
       %Var{
         name: name,
         label: label || name,
         type: type,
         default: nil,
         required: required?,
         private: false,
         choices: normalized_choices,
         min: min,
         max: max,
         help: help
       }}
    end
  end

  defp binding_var(_name, _definition), do: {:error, :binding_input_schema_invalid}

  defp binding_input_name(name) do
    if reviewed_input_name?(name),
      do: :ok,
      else: {:error, {:sensitive_binding_input_forbidden, name}}
  end

  defp binding_definition_keys(definition, keys) do
    if map_size(definition) == MapSet.size(keys) and
         MapSet.subset?(keys, @binding_definition_keys),
       do: :ok,
       else: {:error, :binding_input_schema_invalid}
  end

  defp binding_variable_type(type) when is_binary(type) do
    case type do
      "text" -> {:ok, :text}
      "textarea" -> {:ok, :textarea}
      "integer" -> {:ok, :integer}
      "float" -> {:ok, :float}
      "select" -> {:ok, :select}
      "multiselect" -> {:ok, :multiselect}
      _ -> {:error, :binding_input_schema_invalid}
    end
  end

  defp binding_variable_type(type) when type in @binding_input_types, do: {:ok, type}
  defp binding_variable_type(_type), do: {:error, :binding_input_schema_invalid}

  defp binding_required(nil), do: {:ok, false}
  defp binding_required(required) when is_boolean(required), do: {:ok, required}
  defp binding_required(_required), do: {:error, :binding_input_schema_invalid}

  defp binding_choices(type, choices) when type in [:select, :multiselect] do
    if is_list(choices) and choices != [] and
         Enum.all?(choices, &(is_binary(&1) and byte_size(&1) in 1..1_024)) and
         length(choices) == length(Enum.uniq(choices)) do
      {:ok, choices}
    else
      {:error, :binding_input_schema_invalid}
    end
  end

  defp binding_choices(_type, choices) when choices in [nil, []], do: {:ok, []}
  defp binding_choices(_type, _choices), do: {:error, :binding_input_schema_invalid}

  defp binding_bounds(type, min, max) when type in [:integer, :float] do
    valid_numeric? = fn value -> is_nil(value) or is_number(value) end

    valid? =
      valid_numeric?.(min) and valid_numeric?.(max) and
        (is_nil(min) or is_nil(max) or min <= max) and
        (type != :integer or (integer_or_nil?(min) and integer_or_nil?(max)))

    if valid?, do: :ok, else: {:error, :binding_input_schema_invalid}
  end

  defp binding_bounds(_type, nil, nil), do: :ok
  defp binding_bounds(_type, _min, _max), do: {:error, :binding_input_schema_invalid}

  defp integer_or_nil?(nil), do: true
  defp integer_or_nil?(value), do: is_integer(value)

  defp optional_binding_text(nil, _max), do: :ok

  defp optional_binding_text(value, max) when is_binary(value) and byte_size(value) <= max,
    do: :ok

  defp optional_binding_text(_value, _max), do: {:error, :binding_input_schema_invalid}

  defp binding_classifications(vars, classifications) when is_map(classifications) do
    variable_names = MapSet.new(vars, & &1.name)
    classification_names = classifications |> Map.keys() |> MapSet.new(&to_string/1)
    normalized_names_unique? = map_size(classifications) == MapSet.size(classification_names)

    valid_values? =
      Enum.all?(classifications, fn {_name, classification} ->
        classification in @binding_input_classes
      end)

    if normalized_names_unique? and MapSet.equal?(variable_names, classification_names) and
         valid_values?,
       do: :ok,
       else: {:error, :binding_input_classifications_invalid}
  end

  defp binding_classifications(_vars, _classifications),
    do: {:error, :binding_input_classifications_invalid}

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

  defp map_value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp map_value(_map, _key), do: nil
end
