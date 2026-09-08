defmodule ServiceRadar.Observability.Changes.CompileZenRule do
  @moduledoc """
  Compiles Zen rule definitions into a GoRules JSON decision model.

  If `jdm_definition` is provided (from the JDM editor), it is used directly.
  Otherwise, falls back to compiling from `template` + `builder_config`.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Observability.ZenRuleSupport
  alias ServiceRadar.Observability.ZenRuleTemplates

  @impl true
  def change(changeset, _opts, _context) do
    jdm_definition = ZenRuleSupport.attribute_or_existing(changeset, :jdm_definition)
    subject = ZenRuleSupport.attribute_or_existing(changeset, :subject)

    case ZenRuleSupport.resolve_format(subject) do
      {:ok, format} ->
        changeset = Ash.Changeset.force_change_attribute(changeset, :format, format)

        # If jdm_definition is provided, use it directly
        apply_compiled_jdm(changeset, jdm_definition)

      {:error, message} ->
        Ash.Changeset.add_error(changeset, field: :subject, message: message)
    end
  end

  @impl true
  def atomic(changeset, _opts, _context) do
    jdm_definition = ZenRuleSupport.attribute_or_existing(changeset, :jdm_definition)
    subject = ZenRuleSupport.attribute_or_existing(changeset, :subject)

    with {:ok, format} <- ZenRuleSupport.resolve_format(subject),
         {:ok, payload} <- atomic_payload(format, jdm_definition, changeset) do
      {:atomic, payload}
    else
      _ -> :ok
    end
  end

  defp apply_compiled_jdm(changeset, jdm_definition) do
    if jdm_definition_present?(jdm_definition) do
      Ash.Changeset.force_change_attribute(changeset, :compiled_jdm, jdm_definition)
    else
      # Fall back to template compilation
      compile_from_template(changeset)
    end
  end

  defp jdm_definition_present?(jdm_definition) do
    is_map(jdm_definition) and map_size(jdm_definition) > 0
  end

  defp atomic_payload(format, jdm_definition, _changeset)
       when is_map(jdm_definition) and map_size(jdm_definition) > 0 do
    {:ok, %{format: format, compiled_jdm: jdm_definition}}
  end

  defp atomic_payload(format, _jdm_definition, changeset) do
    template = ZenRuleSupport.attribute_or_existing(changeset, :template)
    builder_config = ZenRuleSupport.attribute_or_existing(changeset, :builder_config) || %{}

    case ZenRuleTemplates.compile(template, builder_config) do
      {:ok, compiled} -> {:ok, %{format: format, compiled_jdm: compiled}}
      {:error, _message} -> :error
    end
  end

  defp compile_from_template(changeset) do
    template = ZenRuleSupport.attribute_or_existing(changeset, :template)
    builder_config = ZenRuleSupport.attribute_or_existing(changeset, :builder_config) || %{}

    case ZenRuleTemplates.compile(template, builder_config) do
      {:ok, compiled} ->
        Ash.Changeset.force_change_attribute(changeset, :compiled_jdm, compiled)

      {:error, message} ->
        Ash.Changeset.add_error(changeset, field: :template, message: message)
    end
  end
end
