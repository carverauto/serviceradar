defmodule ServiceRadar.Automation.Northbound.Changes.RedactTargetResult do
  @moduledoc """
  Redacts per-target provider result payloads before persistence.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Automation.Northbound.ActionRedaction

  @impl true
  def change(changeset, _opts, _context) do
    if Ash.Changeset.changing_attribute?(changeset, :result) do
      Ash.Changeset.change_attribute(changeset, :result, redacted_result(changeset))
    else
      changeset
    end
  end

  @impl true
  def atomic(changeset, _opts, _context) do
    if Ash.Changeset.changing_attribute?(changeset, :result) do
      {:atomic, %{result: redacted_result(changeset)}}
    else
      :ok
    end
  end

  defp redacted_result(changeset) do
    changeset
    |> pending_attribute(:result)
    |> Kernel.||(%{})
    |> ActionRedaction.redact()
  end

  defp pending_attribute(changeset, attribute) do
    Keyword.get_lazy(changeset.atomics, attribute, fn ->
      Ash.Changeset.get_attribute(changeset, attribute)
    end)
  end
end
