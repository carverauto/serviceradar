defmodule ServiceRadar.Automation.Northbound.Changes.RedactInvocationResult do
  @moduledoc """
  Redacts public invocation result summaries and records result hash metadata.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Automation.Northbound.ActionRedaction

  @impl true
  def change(changeset, _opts, _context) do
    if Ash.Changeset.changing_attribute?(changeset, :result_summary) do
      changeset
      |> redaction_payload()
      |> apply_payload(changeset)
    else
      changeset
    end
  end

  @impl true
  def atomic(changeset, _opts, _context) do
    if Ash.Changeset.changing_attribute?(changeset, :result_summary) do
      {:atomic, redaction_payload(changeset)}
    else
      :ok
    end
  end

  defp redaction_payload(changeset) do
    result_summary = pending_attribute(changeset, :result_summary) || %{}
    redaction = ActionRedaction.for_storage(result_summary)

    %{
      result_summary: redaction.redacted,
      metadata:
        changeset
        |> Ash.Changeset.get_attribute(:metadata)
        |> put_redaction_metadata("result", redaction)
    }
  end

  defp apply_payload(payload, changeset) do
    Enum.reduce(payload, changeset, fn {attribute, value}, acc ->
      Ash.Changeset.change_attribute(acc, attribute, value)
    end)
  end

  defp put_redaction_metadata(metadata, prefix, redaction) when is_map(metadata) do
    metadata
    |> Map.put("#{prefix}_sha256", redaction.sha256)
    |> Map.put("#{prefix}_redaction_policy", redaction.policy_version)
  end

  defp put_redaction_metadata(_metadata, prefix, redaction) do
    put_redaction_metadata(%{}, prefix, redaction)
  end

  defp pending_attribute(changeset, attribute) do
    Keyword.get_lazy(changeset.atomics, attribute, fn ->
      Ash.Changeset.get_attribute(changeset, attribute)
    end)
  end
end
