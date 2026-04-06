defmodule ServiceRadar.Observability.Validations.ZenRuleCommon do
  @moduledoc false
  alias ServiceRadar.Observability.ZenRuleSupport

  def validate(changeset, opts \\ []) do
    name = ZenRuleSupport.attribute_or_existing(changeset, :name)
    subject = ZenRuleSupport.attribute_or_existing(changeset, :subject)
    format = format_for_validation(changeset, subject)
    validate_format? = Keyword.get(opts, :validate_format?, false)

    cond do
      not ZenRuleSupport.valid_name?(name) ->
        {:error, field: :name, message: "must be lowercase letters, numbers, - or _"}

      not ZenRuleSupport.valid_subject?(subject) ->
        {:error, field: :subject, message: "must be a supported logs subject"}

      validate_format? and not ZenRuleSupport.valid_format?(subject, format) ->
        {:error, field: :format, message: "does not match subject format"}

      true ->
        :ok
    end
  end

  defp format_for_validation(changeset, subject) do
    if Ash.Changeset.changing_attribute?(changeset, :format) do
      ZenRuleSupport.attribute_or_existing(changeset, :format)
    else
      ZenRuleSupport.expected_format(subject) ||
        ZenRuleSupport.attribute_or_existing(changeset, :format)
    end
  end
end
