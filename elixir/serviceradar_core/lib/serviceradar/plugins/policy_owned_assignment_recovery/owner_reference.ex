defmodule ServiceRadar.Plugins.PolicyOwnedAssignmentRecovery.OwnerReference do
  @moduledoc false

  @credential_prefix "network-credential-rule:"
  @purposes %{
    "inventory_enrichment" => :inventory_enrichment,
    "console_access" => :console_access,
    "discovery" => :discovery,
    "generic" => :generic,
    "camera_inventory" => :camera_inventory,
    "camera_stream" => :camera_stream
  }

  @type owner_reference :: %{
          required(:kind) => :plugin_target_policy | :credential_rule,
          required(:id) => String.t(),
          optional(:purpose) => atom() | nil
        }

  @spec parse(String.t()) :: {:ok, owner_reference()} | {:error, :invalid_policy_owner}
  def parse(policy_id) when is_binary(policy_id) do
    policy_id = String.trim(policy_id)

    cond do
      policy_id == "" ->
        {:error, :invalid_policy_owner}

      String.starts_with?(policy_id, @credential_prefix) ->
        parse_credential_rule(String.replace_prefix(policy_id, @credential_prefix, ""))

      true ->
        case uuid(policy_id) do
          {:ok, id} -> {:ok, %{kind: :plugin_target_policy, id: id, purpose: nil}}
          :error -> {:error, :invalid_policy_owner}
        end
    end
  end

  def parse(_policy_id), do: {:error, :invalid_policy_owner}

  @spec matches_request?(map()) :: boolean()
  def matches_request?(request) when is_map(request) do
    with {:ok, owner} <- parse(value(request, :legacy_policy_id)),
         true <- owner.kind == value(request, :owner_kind),
         true <- owner.id == value(request, :owner_id),
         true <- owner.purpose == value(request, :owner_purpose) do
      true
    else
      _ -> false
    end
  end

  def matches_request?(_request), do: false

  @spec purpose_from_string(String.t()) :: {:ok, atom()} | :error
  def purpose_from_string(value) when is_binary(value) do
    case Map.fetch(@purposes, value) do
      {:ok, purpose} -> {:ok, purpose}
      :error -> :error
    end
  end

  def purpose_from_string(_value), do: :error

  defp parse_credential_rule(value) do
    case String.split(value, ":", parts: 2) do
      [rule_id] ->
        case uuid(rule_id) do
          {:ok, id} -> {:ok, %{kind: :credential_rule, id: id, purpose: :inventory_enrichment}}
          :error -> {:error, :invalid_policy_owner}
        end

      [rule_id, purpose] ->
        with {:ok, id} <- uuid(rule_id),
             {:ok, purpose} <- purpose_from_string(purpose) do
          {:ok, %{kind: :credential_rule, id: id, purpose: purpose}}
        else
          :error -> {:error, :invalid_policy_owner}
        end

      _ ->
        {:error, :invalid_policy_owner}
    end
  end

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> :error
    end
  end

  defp value(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
