defmodule ServiceRadar.Observability.Validations.ZenRuleCommon do
  @moduledoc false

  @allowed_subjects ["logs.syslog", "logs.snmp", "logs.otel", "otel.metrics.raw"]
  @internal_prefix "logs.internal."
  @name_regex ~r/^[a-z][a-z0-9_-]*$/

  def validate(changeset, opts \\ []) do
    name = attribute_or_existing(changeset, :name)
    subject = attribute_or_existing(changeset, :subject)
    format = attribute_or_existing(changeset, :format)
    validate_format? = Keyword.get(opts, :validate_format?, false)

    cond do
      not valid_name?(name) ->
        {:error, field: :name, message: "must be lowercase letters, numbers, - or _"}

      not valid_subject?(subject) ->
        {:error, field: :subject, message: "must be a supported logs subject"}

      validate_format? and not valid_format?(subject, format) ->
        {:error, field: :format, message: "does not match subject format"}

      true ->
        :ok
    end
  end

  defp valid_name?(name) when is_binary(name), do: Regex.match?(@name_regex, name)
  defp valid_name?(_), do: false

  defp valid_subject?(subject) when is_binary(subject) do
    subject in @allowed_subjects or String.starts_with?(subject, @internal_prefix)
  end

  defp valid_subject?(_), do: false

  defp valid_format?(subject, format) when is_binary(subject) do
    expected =
      cond do
        subject == "otel.metrics.raw" -> :otel_metrics
        String.starts_with?(subject, "logs.otel") -> :protobuf
        true -> :json
      end

    format == expected
  end

  defp valid_format?(_, _), do: false

  defp attribute_or_existing(changeset, attribute) do
    Ash.Changeset.get_attribute(changeset, attribute) || Map.get(changeset.data, attribute)
  end
end
