defmodule ServiceRadar.Observability.Validations.ZenRuleTemplate do
  @moduledoc """
  Validates Zen rule template subject and naming constraints.
  """

  use Ash.Resource.Validation
  alias ServiceRadar.Observability.Validations.ZenRuleCommon

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  @impl true
  def validate(changeset, _opts, _context) do
    ZenRuleCommon.validate(changeset)
  end
end
