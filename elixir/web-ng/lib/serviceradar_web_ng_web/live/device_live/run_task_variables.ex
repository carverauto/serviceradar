defmodule ServiceRadarWebNGWeb.DeviceLive.RunTaskVariables do
  @moduledoc """
  Bridges a northbound "Run Task" action to the typed Ansible variable form the
  Device Details panel uses.

  An AWX/Ansible northbound descriptor carries its originating `playbook_id` in
  `metadata`. Given a selected action we load that `Playbook` and reuse
  `VariableSchema.from_playbook/1` — the same normalizer the device-detail panel
  renders — so the bulk modal shows the exact same typed, pre-filled variable
  form (AWX `survey_spec` + git `vars_prompt`/`declared_vars`).

  On submit the typed values collapse back into an `extra_vars` map via
  `VariableSchema.extra_vars_from_form/2`, optionally merged with a raw-JSON
  escape hatch (raw keys win).

  Playbook reads use a `SystemActor` — mirroring `AnsiblePanelRuntime`, whose
  moduledoc explains why the ansible read/launch path needs a system actor. The
  human operator is already gated by `northbound.actions.launch` /
  `ansible.runs.launch` before the modal opens.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.Playbook
  alias ServiceRadar.Automation.Ansible.VariableSchema
  alias ServiceRadar.Automation.Ansible.VariableSchema.Var

  @actor_name :device_run_task_variables

  @doc """
  The Ansible playbook id backing a northbound action, or `nil` when the action
  is not an Ansible/AWX task (e.g. an interface command).
  """
  @spec playbook_id(map()) :: String.t() | nil
  def playbook_id(%{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, "playbook_id") || Map.get(metadata, :playbook_id) do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  def playbook_id(_action), do: nil

  @doc "True when the action is an Ansible/AWX task (has a backing playbook)."
  @spec ansible?(map()) :: boolean()
  def ansible?(action), do: not is_nil(playbook_id(action))

  @doc """
  Load the typed variable schema (`[%Var{}]`) for a playbook id. Returns `[]`
  when the playbook declares no variables or cannot be read.
  """
  @spec load_vars(String.t() | nil) :: [Var.t()]
  def load_vars(playbook_id) when is_binary(playbook_id) do
    case Playbook.get_by_id(playbook_id, actor: actor()) do
      {:ok, playbook} -> VariableSchema.from_playbook(playbook)
      _ -> []
    end
  end

  def load_vars(_playbook_id), do: []

  @doc "Seed form values from each variable's declared default."
  @spec default_values([Var.t()]) :: map()
  def default_values(vars) when is_list(vars) do
    Enum.reduce(vars, %{}, fn %Var{} = var, acc ->
      case var.default do
        nil -> acc
        default -> Map.put(acc, var.name, to_form_default(default))
      end
    end)
  end

  def default_values(_vars), do: %{}

  @doc "Pull just the declared variables' values out of raw form params."
  @spec values_from_params([Var.t()], map()) :: map()
  def values_from_params(vars, var_params) when is_list(vars) and is_map(var_params) do
    Enum.reduce(vars, %{}, fn %Var{name: name}, acc ->
      case Map.get(var_params, name) do
        nil -> acc
        value -> Map.put(acc, name, value)
      end
    end)
  end

  def values_from_params(_vars, _params), do: %{}

  @doc """
  Assemble the final `extra_vars` map from the typed form values, optionally
  merged with a raw-JSON object (raw keys override the typed values). Returns
  `{:error, message}` when the raw JSON is present but not a valid object.
  """
  @spec extra_vars([Var.t()], map(), String.t() | nil) ::
          {:ok, map()} | {:error, String.t()}
  def extra_vars(vars, var_params, raw_json) do
    typed = VariableSchema.extra_vars_from_form(vars || [], var_params || %{})

    case parse_raw(raw_json) do
      :empty -> {:ok, typed}
      {:ok, raw_map} -> {:ok, Map.merge(typed, raw_map)}
      {:error, message} -> {:error, message}
    end
  end

  defp parse_raw(nil), do: :empty

  defp parse_raw(raw) when is_binary(raw) do
    case String.trim(raw) do
      "" -> :empty
      "{}" -> :empty
      trimmed -> decode_raw(trimmed)
    end
  end

  defp parse_raw(_raw), do: :empty

  defp decode_raw(trimmed) do
    case Jason.decode(trimmed) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _other} -> {:error, ~s(expected a JSON object like {"key": "value"})}
      {:error, %Jason.DecodeError{} = error} -> {:error, Exception.message(error)}
      {:error, _error} -> {:error, "invalid JSON"}
    end
  end

  defp to_form_default(value) when is_binary(value), do: value
  defp to_form_default(value) when is_integer(value) or is_float(value), do: to_string(value)
  defp to_form_default(true), do: "true"
  defp to_form_default(false), do: "false"
  defp to_form_default(value) when is_list(value), do: value
  defp to_form_default(value), do: inspect(value)

  defp actor, do: SystemActor.system(@actor_name)
end
