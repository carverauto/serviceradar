defmodule ServiceRadar.Edge.Changes.RedactDesktopTargetPolicy do
  @moduledoc """
  Redacts accidental credential material from desktop target policy maps.

  Desktop targets are operator-owned routing and policy records. They may
  reference brokered credential rules, but must not persist plaintext secrets.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Credentials.CredentialRedactor

  @fields [
    :target_tls,
    :nla,
    :screen_policy,
    :redirection_policy,
    :recording_policy,
    :metadata
  ]

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> redacted_payload()
    |> Enum.reduce(changeset, fn {field, value}, changeset ->
      Ash.Changeset.change_attribute(changeset, field, value)
    end)
  end

  @impl true
  def atomic(changeset, _opts, _context), do: {:atomic, redacted_payload(changeset)}

  defp redacted_payload(changeset) do
    Enum.reduce(@fields, %{}, fn field, payload ->
      case Map.fetch(changeset.attributes, field) do
        {:ok, value} when is_map(value) or is_list(value) ->
          Map.put(payload, field, CredentialRedactor.redact(value))

        _other ->
          payload
      end
    end)
  end
end
