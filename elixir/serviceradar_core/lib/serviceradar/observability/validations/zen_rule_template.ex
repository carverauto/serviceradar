defmodule ServiceRadar.Observability.Validations.ZenRuleTemplate do
  @moduledoc """
  Validates Zen rule template subject and naming constraints.
  """

  use Ash.Resource.Validation

  @allowed_subjects ["logs.syslog", "logs.snmp", "logs.otel", "otel.metrics.raw"]
  @internal_prefix "logs.internal."
  @name_regex ~r/^[a-z][a-z0-9_-]*$/

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  @impl true
  def validate(changeset, _opts, _context) do
    name = attribute_or_existing(changeset, :name)
    subject = attribute_or_existing(changeset, :subject)

    cond do
      not valid_name?(name) ->
        {:error, field: :name, message: "must be lowercase letters, numbers, - or _"}

      not valid_subject?(subject) ->
        {:error, field: :subject, message: "must be a supported logs subject"}

      true ->
        :ok
    end
  end

  defp valid_name?(name) when is_binary(name) do
    Regex.match?(@name_regex, name)
  end

  defp valid_name?(_), do: false

  defp valid_subject?(subject) when is_binary(subject) do
    subject in @allowed_subjects or String.starts_with?(subject, @internal_prefix)
  end

  defp valid_subject?(_), do: false

  defp attribute_or_existing(changeset, attribute) do
    Ash.Changeset.get_attribute(changeset, attribute) || Map.get(changeset.data, attribute)
  end
end
