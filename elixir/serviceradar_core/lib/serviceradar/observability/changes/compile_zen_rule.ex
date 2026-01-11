defmodule ServiceRadar.Observability.Changes.CompileZenRule do
  @moduledoc """
  Compiles Zen rule definitions into a GoRules JSON decision model.

  If `jdm_definition` is provided (from the JDM editor), it is used directly.
  Otherwise, falls back to compiling from `template` + `builder_config`.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Observability.ZenRuleTemplates

  @impl true
  def change(changeset, _opts, _context) do
    jdm_definition = attribute_or_existing(changeset, :jdm_definition)
    subject = attribute_or_existing(changeset, :subject)

    case resolve_format(subject) do
      {:ok, format} ->
        changeset = Ash.Changeset.force_change_attribute(changeset, :format, format)

        # If jdm_definition is provided, use it directly
        if jdm_definition && map_size(jdm_definition) > 0 do
          Ash.Changeset.force_change_attribute(changeset, :compiled_jdm, jdm_definition)
        else
          # Fall back to template compilation
          compile_from_template(changeset)
        end

      {:error, message} ->
        Ash.Changeset.add_error(changeset, field: :subject, message: message)
    end
  end

  @impl true
  def atomic(changeset, _opts, _context) do
    jdm_definition = attribute_or_existing(changeset, :jdm_definition)
    subject = attribute_or_existing(changeset, :subject)

    case resolve_format(subject) do
      {:ok, format} ->
        # If jdm_definition is provided, use it directly
        if jdm_definition && map_size(jdm_definition) > 0 do
          {:atomic, %{format: format, compiled_jdm: jdm_definition}}
        else
          # Fall back to template compilation
          template = attribute_or_existing(changeset, :template)
          builder_config = attribute_or_existing(changeset, :builder_config) || %{}

          case ZenRuleTemplates.compile(template, builder_config) do
            {:ok, compiled} -> {:atomic, %{format: format, compiled_jdm: compiled}}
            {:error, _message} -> :ok
          end
        end

      {:error, _message} ->
        :ok
    end
  end

  defp compile_from_template(changeset) do
    template = attribute_or_existing(changeset, :template)
    builder_config = attribute_or_existing(changeset, :builder_config) || %{}

    case ZenRuleTemplates.compile(template, builder_config) do
      {:ok, compiled} ->
        Ash.Changeset.force_change_attribute(changeset, :compiled_jdm, compiled)

      {:error, message} ->
        Ash.Changeset.add_error(changeset, field: :template, message: message)
    end
  end

  defp attribute_or_existing(changeset, attribute) do
    Ash.Changeset.get_attribute(changeset, attribute) || Map.get(changeset.data, attribute)
  end

  defp resolve_format(nil), do: {:error, "subject is required"}

  defp resolve_format(subject) when is_binary(subject) do
    cond do
      subject == "otel.metrics.raw" -> {:ok, :otel_metrics}
      String.starts_with?(subject, "logs.otel") -> {:ok, :protobuf}
      true -> {:ok, :json}
    end
  end

  defp resolve_format(_), do: {:error, "invalid subject"}
end
