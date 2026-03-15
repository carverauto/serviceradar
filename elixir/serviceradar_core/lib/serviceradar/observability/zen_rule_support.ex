defmodule ServiceRadar.Observability.ZenRuleSupport do
  @moduledoc false

  @allowed_subjects ["logs.syslog", "logs.snmp", "logs.otel", "otel.metrics.raw"]
  @internal_prefix "logs.internal."
  @name_regex ~r/^[a-z][a-z0-9_-]*$/

  def attribute_or_existing(changeset, attribute) do
    Ash.Changeset.get_attribute(changeset, attribute) || Map.get(changeset.data, attribute)
  end

  def valid_name?(name) when is_binary(name), do: Regex.match?(@name_regex, name)
  def valid_name?(_), do: false

  def valid_subject?(subject) when is_binary(subject) do
    subject in @allowed_subjects or String.starts_with?(subject, @internal_prefix)
  end

  def valid_subject?(_), do: false

  def expected_format(subject) when is_binary(subject) do
    cond do
      subject == "otel.metrics.raw" -> :otel_metrics
      String.starts_with?(subject, "logs.otel") -> :protobuf
      true -> :json
    end
  end

  def expected_format(_), do: nil

  def valid_format?(subject, format) when is_binary(subject), do: format == expected_format(subject)
  def valid_format?(_, _), do: false

  def resolve_format(nil), do: {:error, "subject is required"}
  def resolve_format(subject) when is_binary(subject), do: {:ok, expected_format(subject)}
  def resolve_format(_), do: {:error, "invalid subject"}
end
