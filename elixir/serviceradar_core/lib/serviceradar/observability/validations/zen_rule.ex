defmodule ServiceRadar.Observability.Validations.ZenRule do
  @moduledoc """
  Validates Zen rule subject, name, and format constraints.
  """

  use Ash.Resource.Validation
  alias ServiceRadar.Observability.Validations.ZenRuleCommon

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  @impl true
  def validate(changeset, _opts, _context) do
    ZenRuleCommon.validate(changeset, validate_format?: true)
  end
end
