defmodule ServiceRadar.Edge.Changes.RedactDesktopTargetPolicy do
  @moduledoc """
  Redacts accidental credential material from desktop target policy maps.

  Desktop targets are operator-owned routing and policy records. They may
  reference brokered credential rules, but must not persist plaintext secrets.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Credentials.CredentialRedactor

  @non_secret_fields MapSet.new([
                       :name,
                       :description,
                       :enabled,
                       :device_uid,
                       :protocol,
                       :target_kind,
                       :target_host,
                       :target_port,
                       :agent_id,
                       :gateway_id,
                       :credential_custody_mode,
                       :credential_rule_id,
                       :approval_required,
                       :allowed_principals,
                       :target_tls,
                       :nla,
                       :screen_policy,
                       :redirection_policy,
                       :recording_policy,
                       :metadata
                     ])

  @structured_policy_fields MapSet.new([
                              :target_tls,
                              :nla,
                              :screen_policy,
                              :redirection_policy,
                              :recording_policy,
                              :metadata
                            ])

  @redacted "REDACTED"

  @doc false
  @spec redact_attributes(map()) :: map()
  def redact_attributes(attrs) when is_map(attrs) do
    Map.new(attrs, fn {field, value} ->
      {field, redact_attribute(field, value)}
    end)
  end

  @doc false
  @spec redacted_change_payload(map()) :: map()
  def redacted_change_payload(attrs) when is_map(attrs) do
    attrs
    |> redact_attributes()
    |> Enum.reject(fn {field, redacted_value} -> Map.get(attrs, field) == redacted_value end)
    |> Map.new()
  end

  @sensitive_replacement %{"redacted" => true}

  defp redact_attribute(field, value) do
    normalized_field = normalize_field(field)

    cond do
      MapSet.member?(@structured_policy_fields, normalized_field) ->
        CredentialRedactor.redact(value)

      MapSet.member?(@non_secret_fields, normalized_field) ->
        CredentialRedactor.redact(value)

      true ->
        strip_unlisted_value(value)
    end
  end

  defp strip_unlisted_value(value) when is_map(value), do: @sensitive_replacement
  defp strip_unlisted_value(value) when is_list(value), do: []
  defp strip_unlisted_value(value) when is_binary(value), do: @redacted
  defp strip_unlisted_value(_value), do: nil

  defp normalize_field(field) when is_atom(field), do: field

  defp normalize_field(field) when is_binary(field) do
    String.to_existing_atom(field)
  rescue
    ArgumentError -> field
  end

  defp normalize_field(field), do: field

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
    redacted_change_payload(changeset.attributes)
  end
end
