defmodule ServiceRadar.Automation.Ansible.Changes.ApproveAwxHostMembership do
  @moduledoc false
  use Ash.Resource.Change

  alias ServiceRadar.AshContext

  require Ash.Expr

  @approval_schema "serviceradar.awx_membership_approval.v1"
  @source_evidence_keys MapSet.new(~w(
    kind
    controller_id
    inventory_id
    awx_host_id
    matching_device_uids
    match_count
  ))

  @impl true
  def change(changeset, _opts, context) do
    actor = AshContext.actor(changeset) || AshContext.actor(context)
    data = changeset.data
    expected_evidence = Ash.Changeset.get_argument(changeset, :expected_link_evidence)

    with :ok <- require_human(actor),
         :ok <- require_exact_identity(changeset, data),
         :ok <- require_current_proposal(data),
         :ok <- require_exact_evidence(changeset, data, expected_evidence) do
      approve(changeset, actor, expected_evidence)
    else
      {:error, field, message} ->
        Ash.Changeset.add_error(changeset, field: field, message: message)
    end
  end

  defp require_human(%{role: :system}),
    do: {:error, :link_disposition, "AWX membership approval requires a human principal"}

  defp require_human(%{principal_type: type}) when type not in [:human, "human"],
    do: {:error, :link_disposition, "AWX membership approval requires a human principal"}

  defp require_human(%{"principal_type" => type}) when type not in [:human, "human"],
    do: {:error, :link_disposition, "AWX membership approval requires a human principal"}

  defp require_human(actor) do
    if non_empty_string?(actor_id(actor)) do
      :ok
    else
      {:error, :link_disposition, "AWX membership approval requires an attributable human"}
    end
  end

  defp require_exact_identity(changeset, data) do
    checks = [
      {:controller_id, data.controller_id},
      {:inventory_id, data.inventory_id},
      {:awx_host_id, data.awx_host_id},
      {:canonical_device_uid, data.canonical_device_uid},
      {:source_generation, data.source_generation},
      {:source_fingerprint, data.source_fingerprint}
    ]

    case Enum.find(checks, fn {argument, current} ->
           not exact?(Ash.Changeset.get_argument(changeset, argument), current)
         end) do
      nil -> :ok
      {field, _current} -> {:error, field, "does not match the current AWX membership evidence"}
    end
  end

  defp require_current_proposal(data) do
    cond do
      data.current != true or data.enabled != true or not is_nil(data.expired_at) ->
        {:error, :current, "AWX membership is not current and enabled"}

      data.link_disposition != :proposed ->
        {:error, :link_disposition, "AWX membership link is not awaiting human approval"}

      not non_empty_string?(data.canonical_device_uid) ->
        {:error, :canonical_device_uid, "AWX membership has no unambiguous device proposal"}

      true ->
        :ok
    end
  end

  defp require_exact_evidence(changeset, data, expected_evidence) do
    device_uid = Ash.Changeset.get_argument(changeset, :canonical_device_uid)
    expected_digest = Ash.Changeset.get_argument(changeset, :link_evidence_digest)

    cond do
      expected_evidence != data.link_evidence ->
        {:error, :expected_link_evidence, "does not match the current AWX link evidence"}

      evidence_digest(expected_evidence) != {:ok, expected_digest} ->
        {:error, :link_evidence_digest, "does not match the current AWX link evidence"}

      not unambiguous_source_evidence?(expected_evidence, data, device_uid) ->
        {:error, :expected_link_evidence, "does not prove one exact AWX-to-device link"}

      true ->
        :ok
    end
  end

  defp approve(changeset, actor, expected_evidence) do
    controller_id = Ash.Changeset.get_argument(changeset, :controller_id)
    inventory_id = Ash.Changeset.get_argument(changeset, :inventory_id)
    awx_host_id = Ash.Changeset.get_argument(changeset, :awx_host_id)
    canonical_device_uid = Ash.Changeset.get_argument(changeset, :canonical_device_uid)
    source_generation = Ash.Changeset.get_argument(changeset, :source_generation)
    source_fingerprint = Ash.Changeset.get_argument(changeset, :source_fingerprint)
    evidence_digest = Ash.Changeset.get_argument(changeset, :link_evidence_digest)
    approved_at = Ash.Changeset.get_argument(changeset, :approved_at)

    approval = %{
      "schema" => @approval_schema,
      "principal_type" => "human",
      "principal_id" => actor_id(actor),
      "approved_at" => DateTime.to_iso8601(approved_at),
      "controller_id" => to_string(controller_id),
      "inventory_id" => inventory_id,
      "awx_host_id" => awx_host_id,
      "canonical_device_uid" => canonical_device_uid,
      "source_generation" => source_generation,
      "source_fingerprint" => source_fingerprint,
      "link_evidence_digest" => evidence_digest
    }

    approved_evidence = Map.put(expected_evidence, "approval", approval)

    changeset
    |> Ash.Changeset.filter(
      Ash.Expr.expr(
        controller_id == ^controller_id and
          inventory_id == ^inventory_id and
          awx_host_id == ^awx_host_id and
          canonical_device_uid == ^canonical_device_uid and
          source_generation == ^source_generation and
          source_fingerprint == ^source_fingerprint and
          current == true and enabled == true and is_nil(expired_at) and
          link_disposition == :proposed and link_evidence == ^expected_evidence
      )
    )
    |> Ash.Changeset.change_attribute(:link_disposition, :approved)
    |> Ash.Changeset.change_attribute(:link_evidence, approved_evidence)
  end

  defp unambiguous_source_evidence?(evidence, data, device_uid) when is_map(evidence) do
    case normalize_keys(evidence) do
      {:ok, normalized} ->
        MapSet.new(Map.keys(normalized)) == @source_evidence_keys and
          normalized["kind"] == "stored_awx_source_tuple" and
          exact?(normalized["controller_id"], data.controller_id) and
          normalized["inventory_id"] == data.inventory_id and
          normalized["awx_host_id"] == data.awx_host_id and
          normalized["matching_device_uids"] == [device_uid] and
          normalized["match_count"] == 1

      _ ->
        false
    end
  end

  defp unambiguous_source_evidence?(_evidence, _data, _device_uid), do: false

  defp normalize_keys(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, normalized} ->
      with {:ok, key} <- normalize_key(key),
           false <- Map.has_key?(normalized, key) do
        {:cont, {:ok, Map.put(normalized, key, value)}}
      else
        _ -> {:halt, {:error, :invalid_evidence_keys}}
      end
    end)
  end

  defp normalize_key(key) when is_binary(key), do: {:ok, key}
  defp normalize_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp normalize_key(_key), do: {:error, :invalid_evidence_key}

  defp evidence_digest(evidence) do
    ServiceRadar.Automation.CallbackGrants.CanonicalJSON.digest(evidence)
  end

  defp exact?(left, right) when is_binary(left) and is_binary(right),
    do: to_string(left) == to_string(right)

  defp exact?(left, right), do: left == right

  defp actor_id(%{id: id}) when not is_nil(id), do: to_string(id)
  defp actor_id(%{"id" => id}) when not is_nil(id), do: to_string(id)
  defp actor_id(_actor), do: nil

  defp non_empty_string?(value), do: is_binary(value) and value != ""
end
