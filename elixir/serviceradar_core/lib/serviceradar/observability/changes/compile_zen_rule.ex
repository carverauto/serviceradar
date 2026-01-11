defmodule ServiceRadar.Observability.Changes.CompileZenRule do
  @moduledoc """
  Compiles Zen rule builder config into a GoRules JSON decision model.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Observability.ZenRuleTemplates

  @impl true
  def change(changeset, _opts, _context) do
    template = attribute_or_existing(changeset, :template)
    builder_config = attribute_or_existing(changeset, :builder_config) || %{}
    subject = attribute_or_existing(changeset, :subject)

    with {:ok, format} <- resolve_format(subject),
         {:ok, compiled} <- ZenRuleTemplates.compile(template, builder_config) do
      changeset
      |> Ash.Changeset.force_change_attribute(:format, format)
      |> Ash.Changeset.force_change_attribute(:compiled_jdm, compiled)
    else
      {:error, message} ->
        Ash.Changeset.add_error(changeset, field: :template, message: message)
    end
  end

  @impl true
  def atomic(changeset, _opts, _context) do
    template = attribute_or_existing(changeset, :template)
    builder_config = attribute_or_existing(changeset, :builder_config) || %{}
    subject = attribute_or_existing(changeset, :subject)

    with {:ok, format} <- resolve_format(subject),
         {:ok, compiled} <- ZenRuleTemplates.compile(template, builder_config) do
      {:atomic, %{format: format, compiled_jdm: compiled}}
    else
      {:error, _message} ->
        :ok
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
