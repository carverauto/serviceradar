defmodule ServiceRadar.Automation.CallbackGrants.SshCaBundleResponse do
  @moduledoc """
  Builds the exact public SSH-CA callback response from an immutable grant.

  Request fields select nothing: every field must equal its snapshotted value.
  Targets are correlated against the exact AWX launch tuple set, normalized in a
  deterministic order, and encoded once so same-key replay can return the
  byte-identical committed response.
  """

  alias ServiceRadar.Automation.CallbackGrants.ActionContract
  alias ServiceRadar.Automation.CallbackGrants.CanonicalJSON

  @action "remote_access.ssh_ca.bundle.read"
  @schema "serviceradar.remote_access.ssh_ca_bundle/v1"
  @phases ~w(preflight stage verify commit)
  @operations ~w(enroll overlap retire remove)
  @states ~w(present absent)

  @request_keys MapSet.new(~w(action schema_version manifest_sha256 job_id phase operation state))

  @approval_snapshot_keys MapSet.new(
                            ~w(binding_id binding_version approval_id approval_expires_at reviewed_by_principal_type reviewed_by_principal_id reviewed_at review_metadata issued_at)
                          )

  @target_keys MapSet.new(
                 ~w(inventory_hostname inventory_address target_identity ca_keys accounts transaction retirement_proof)
               )

  @identity_keys MapSet.new(~w(controller_id inventory_id awx_host_id canonical_device_uid))
  @ca_key_keys MapSet.new(~w(id public_key fingerprint))
  @account_keys MapSet.new(~w(name principals))

  @transaction_keys MapSet.new(
                      ~w(id stage_job_id verification_job_id generation machine_credential_ref)
                    )

  @retirement_keys MapSet.new(
                     ~w(kind verified proof_id target_identity overlap_policy_digest new_ca_fingerprint principal_policy_version fresh_until fresh_until_epoch route_id)
                   )

  @retirement_required MapSet.new(
                         ~w(kind verified proof_id target_identity new_ca_fingerprint principal_policy_version fresh_until_epoch route_id)
                       )

  @type built :: %{document: map(), bytes: binary(), digest: binary()}

  @spec expected_request(map()) :: {:ok, map()} | {:error, term()}
  def expected_request(grant) when is_map(grant) do
    expected_request(grant, grant |> value(:job_binding) |> value(:job_id))
  end

  def expected_request(_grant), do: {:error, :invalid_grant}

  @doc "Builds the immutable request expected while the accepted AWX job is not bound yet."
  @spec expected_request(map(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def expected_request(grant, job_id) when is_map(grant) do
    snapshot = value(grant, :response_snapshot) || %{}

    request = %{
      "action" => value(grant, :action),
      "schema_version" => @schema,
      "manifest_sha256" => value(snapshot, :manifest_sha256),
      "job_id" => job_id,
      "phase" => value(snapshot, :phase),
      "operation" => value(snapshot, :operation),
      "state" => value(snapshot, :state)
    }

    with :ok <- validate_request_shape(request) do
      {:ok, request}
    end
  end

  def expected_request(_grant, _job_id), do: {:error, :invalid_grant}

  @spec build(map(), map()) :: {:ok, built()} | {:error, term()}
  def build(grant, request) when is_map(grant) and is_map(request) do
    with {:ok, contract} <- ActionContract.fetch(value(grant, :action)),
         {:ok, expected_request} <- expected_request(grant),
         {:ok, request} <- validate_request(request),
         true <- request == expected_request || {:error, :callback_request_mismatch},
         {:ok, authorization} <- authorization(grant, contract),
         {:ok, targets} <- targets(grant, expected_request, authorization),
         document = Map.put(expected_request, "authorization", authorization),
         document = Map.put(document, "targets", targets),
         {:ok, bytes} <- CanonicalJSON.encode(document),
         :ok <- enforce_size(bytes, contract.max_response_bytes) do
      {:ok, %{document: document, bytes: bytes, digest: CanonicalJSON.sha256(bytes)}}
    else
      false -> {:error, :callback_request_mismatch}
      {:error, _} = error -> error
    end
  end

  def build(_grant, _request), do: {:error, :invalid_callback_response_input}

  @doc "Validates the exact public SSH CA callback request envelope."
  @spec validate_request(map()) :: {:ok, map()} | {:error, term()}
  def validate_request(request) when is_map(request) do
    with {:ok, request} <- string_map(request),
         :ok <- exact_keys(request, @request_keys, :invalid_callback_request),
         :ok <- validate_request_shape(request) do
      {:ok, request}
    end
  end

  def validate_request(_request), do: {:error, :invalid_callback_request}

  defp authorization(grant, contract) do
    approval = value(grant, :approval_snapshot) || %{}
    awx = value(grant, :awx_scope_snapshot) || %{}
    approval_id = value(approval, :approval_id) || value(approval, :id)

    authorization = %{
      "permissions" => ActionContract.required_permissions(contract),
      "policy_approved" => approved_snapshot?(approval),
      "binding_verified" => value(grant, :binding_verified) == true,
      "scm_revision" => value(awx, :scm_revision),
      "content_sha256" => value(awx, :content_sha256)
    }

    authorization =
      authorization
      |> maybe_put("approval_id", approval_id)
      |> maybe_put("binding_id", value(awx, :binding_id))

    cond do
      authorization["policy_approved"] != true -> {:error, :policy_not_approved}
      authorization["binding_verified"] != true -> {:error, :awx_binding_not_verified}
      not digest?(authorization["content_sha256"], 64) -> {:error, :invalid_content_digest}
      not digest?(authorization["scm_revision"], 40..64) -> {:error, :invalid_scm_revision}
      true -> {:ok, authorization}
    end
  end

  defp approved_snapshot?(approval) do
    with {:ok, normalized} <- string_map(approval),
         :ok <- exact_keys(normalized, @approval_snapshot_keys, :invalid_approval_snapshot),
         :ok <- nonempty_string(normalized["binding_id"], :invalid_approval_snapshot),
         true <- is_integer(normalized["binding_version"]) and normalized["binding_version"] > 0,
         :ok <- nonempty_string(normalized["approval_id"], :invalid_approval_snapshot),
         true <- datetime_string?(normalized["approval_expires_at"]),
         true <-
           normalized["reviewed_by_principal_type"] in [
             :human,
             "human",
             :service_principal,
             "service_principal"
           ],
         :ok <-
           nonempty_string(
             normalized["reviewed_by_principal_id"],
             :invalid_approval_snapshot
           ),
         true <- datetime_string?(normalized["reviewed_at"]),
         true <- is_map(normalized["review_metadata"]),
         true <- datetime_string?(normalized["issued_at"]) do
      true
    else
      _ -> false
    end
  end

  defp targets(grant, request, authorization) do
    response_snapshot = value(grant, :response_snapshot) || %{}
    target_snapshots = value(response_snapshot, :targets)

    with true <- is_list(target_snapshots) || {:error, :target_snapshot_required},
         true <- length(target_snapshots) in 1..100 || {:error, :invalid_target_count},
         {:ok, targets} <- normalize_targets(target_snapshots, request, authorization, []),
         :ok <- validate_unique_targets(targets),
         :ok <- validate_awx_target_equality(grant, targets) do
      {:ok, Enum.sort_by(targets, &target_sort_key/1)}
    else
      false -> {:error, :target_snapshot_required}
      {:error, _} = error -> error
    end
  end

  defp normalize_targets([], _request, _authorization, normalized),
    do: {:ok, Enum.reverse(normalized)}

  defp normalize_targets([target | rest], request, authorization, normalized)
       when is_map(target) do
    with {:ok, target} <- string_map(target),
         :ok <- exact_optional_keys(target, @target_keys, :invalid_target_snapshot),
         {:ok, identity} <- identity(target["target_identity"]),
         {:ok, ca_keys} <- ca_keys(target["ca_keys"], request["state"]),
         {:ok, accounts} <- accounts(target["accounts"], request["state"]),
         {:ok, transaction} <- transaction(target["transaction"], request["phase"]),
         {:ok, retirement_proof} <-
           retirement_proof(target["retirement_proof"], request["operation"], identity),
         :ok <- nonempty_string(target["inventory_hostname"], :invalid_inventory_hostname),
         :ok <- nonempty_string(target["inventory_address"], :invalid_inventory_address) do
      result = %{
        "inventory_hostname" => target["inventory_hostname"],
        "inventory_address" => to_string(target["inventory_address"]),
        "target_identity" => identity,
        "operation" => request["operation"],
        "phase" => request["phase"],
        "state" => request["state"],
        "ca_keys" => ca_keys,
        "accounts" => accounts,
        "transaction" => transaction,
        "authorization" => authorization
      }

      result = maybe_put(result, "retirement_proof", retirement_proof)
      normalize_targets(rest, request, authorization, [result | normalized])
    end
  end

  defp normalize_targets(_targets, _request, _authorization, _normalized),
    do: {:error, :invalid_target_snapshot}

  defp identity(identity) when is_map(identity) do
    with {:ok, identity} <- string_map(identity),
         :ok <- exact_keys(identity, @identity_keys, :invalid_target_identity),
         :ok <- nonempty_string(identity["controller_id"], :invalid_controller_id),
         :ok <- scalar_id(identity["inventory_id"], :invalid_inventory_id),
         :ok <- scalar_id(identity["awx_host_id"], :invalid_awx_host_id),
         :ok <- nonempty_string(identity["canonical_device_uid"], :invalid_device_uid) do
      {:ok, identity}
    end
  end

  defp identity(_identity), do: {:error, :invalid_target_identity}

  defp ca_keys([], "absent"), do: {:ok, []}

  defp ca_keys(keys, "present") when is_list(keys) and keys != [] do
    keys
    |> Enum.reduce_while({:ok, []}, fn key, {:ok, acc} ->
      with {:ok, key} <- string_map(key),
           :ok <- exact_keys(key, @ca_key_keys, :invalid_ca_key),
           true <- valid_ca_id?(key["id"]) || {:error, :invalid_ca_key_id},
           true <- valid_public_key?(key["public_key"]) || {:error, :invalid_ca_public_key},
           true <- valid_fingerprint?(key["fingerprint"]) || {:error, :invalid_ca_fingerprint} do
        {:cont, {:ok, [key | acc]}}
      else
        {:error, _} = error -> {:halt, error}
        false -> {:halt, {:error, :invalid_ca_key}}
      end
    end)
    |> case do
      {:ok, normalized} ->
        normalized = Enum.sort_by(normalized, & &1["id"])

        if unique_by?(normalized, & &1["id"]) and
             unique_by?(normalized, & &1["fingerprint"]),
           do: {:ok, normalized},
           else: {:error, :duplicate_ca_key}

      error ->
        error
    end
  end

  defp ca_keys(_keys, _state), do: {:error, :invalid_ca_key_set}

  defp accounts([], "absent"), do: {:ok, []}

  defp accounts(accounts, "present") when is_list(accounts) and accounts != [] do
    accounts
    |> Enum.reduce_while({:ok, []}, fn account, {:ok, acc} ->
      with {:ok, account} <- string_map(account),
           :ok <- exact_keys(account, @account_keys, :invalid_account),
           true <- valid_account?(account["name"]) || {:error, :invalid_account_name},
           true <- account["name"] != "root" || {:error, :root_account_forbidden},
           {:ok, principals} <- principals(account["principals"]) do
        {:cont, {:ok, [%{"name" => account["name"], "principals" => principals} | acc]}}
      else
        {:error, _} = error -> {:halt, error}
        false -> {:halt, {:error, :invalid_account}}
      end
    end)
    |> case do
      {:ok, normalized} ->
        normalized = Enum.sort_by(normalized, & &1["name"])

        if unique_by?(normalized, & &1["name"]),
          do: {:ok, normalized},
          else: {:error, :duplicate_account}

      error ->
        error
    end
  end

  defp accounts(_accounts, _state), do: {:error, :invalid_account_set}

  defp principals(principals) when is_list(principals) and principals != [] do
    if Enum.all?(principals, &valid_principal?/1) and unique_by?(principals, & &1),
      do: {:ok, Enum.sort(principals)},
      else: {:error, :invalid_principals}
  end

  defp principals(_principals), do: {:error, :invalid_principals}

  defp transaction(transaction, phase) when is_map(transaction) do
    with {:ok, transaction} <- string_map(transaction),
         :ok <- exact_optional_keys(transaction, @transaction_keys, :invalid_transaction),
         :ok <- validate_transaction_fields(transaction, phase) do
      {:ok, transaction}
    end
  end

  defp transaction(_transaction, _phase), do: {:error, :invalid_transaction}

  defp validate_transaction_fields(_transaction, "preflight"), do: :ok

  defp validate_transaction_fields(transaction, _phase) do
    with :ok <- nonempty_string(transaction["id"], :transaction_id_required),
         :ok <- scalar_id(transaction["stage_job_id"], :stage_job_id_required),
         :ok <- nonempty_string(transaction["generation"], :transaction_generation_required) do
      credential_reference(
        transaction["machine_credential_ref"],
        :machine_credential_reference_required
      )
    end
  end

  defp retirement_proof(nil, operation, _identity) when operation != "retire", do: {:ok, nil}

  defp retirement_proof(%{} = proof, operation, _identity) when operation != "retire" do
    if map_size(proof) == 0,
      do: {:ok, nil},
      else: {:error, :unexpected_retirement_proof}
  end

  defp retirement_proof(proof, "retire", identity) when is_map(proof) do
    with {:ok, proof} <- string_map(proof),
         :ok <- exact_optional_keys(proof, @retirement_keys, :invalid_retirement_proof),
         true <-
           MapSet.subset?(@retirement_required, MapSet.new(Map.keys(proof))) ||
             {:error, :incomplete_retirement_proof},
         true <-
           proof["kind"] == "serviceradar_selected_edge_ca_login" ||
             {:error, :invalid_retirement_proof_kind},
         true <- proof["verified"] == true || {:error, :unverified_retirement_proof},
         {:ok, proof_identity} <- identity(proof["target_identity"]),
         true <- proof_identity == identity || {:error, :retirement_target_mismatch},
         :ok <- nonempty_string(proof["proof_id"], :retirement_proof_id_required),
         :ok <- nonempty_string(proof["route_id"], :retirement_route_required),
         :ok <-
           nonempty_string(
             proof["new_ca_fingerprint"],
             :retirement_ca_fingerprint_required
           ),
         true <-
           is_integer(proof["fresh_until_epoch"]) ||
             {:error, :retirement_freshness_required} do
      {:ok, proof}
    else
      false -> {:error, :invalid_retirement_proof}
      {:error, _} = error -> error
    end
  end

  defp retirement_proof(_proof, "retire", _identity), do: {:error, :retirement_proof_required}

  defp validate_unique_targets(targets) do
    names = Enum.map(targets, & &1["inventory_hostname"])
    tuples = Enum.map(targets, &identity_key(&1["target_identity"]))

    if unique_by?(names, & &1) and unique_by?(tuples, & &1),
      do: :ok,
      else: {:error, :duplicate_callback_target}
  end

  defp validate_awx_target_equality(grant, targets) do
    awx = value(grant, :awx_scope_snapshot) || %{}
    awx_targets = value(awx, :targets)

    with true <- is_list(awx_targets) || {:error, :awx_target_snapshot_required},
         {:ok, awx_keys} <- awx_target_keys(awx_targets, []),
         response_keys = Enum.map(targets, &response_target_key/1),
         true <-
           Enum.sort(awx_keys) == Enum.sort(response_keys) ||
             {:error, :callback_awx_target_mismatch} do
      :ok
    else
      false -> {:error, :awx_target_snapshot_required}
      {:error, _} = error -> error
    end
  end

  defp awx_target_keys([], keys), do: {:ok, Enum.reverse(keys)}

  defp awx_target_keys([target | rest], keys) when is_map(target) do
    identity = %{
      "controller_id" => value(target, :controller_id),
      "inventory_id" => value(target, :inventory_id),
      "awx_host_id" => value(target, :awx_host_id),
      "canonical_device_uid" => value(target, :canonical_device_uid) || value(target, :device_uid)
    }

    with {:ok, identity} <- identity(identity),
         :ok <-
           nonempty_string(
             value(target, :host_name) || value(target, :awx_host_name),
             :invalid_awx_host_name
           ),
         :ok <- nonempty_string(value(target, :ansible_host), :invalid_ansible_host) do
      key =
        {identity_key(identity),
         to_string(value(target, :host_name) || value(target, :awx_host_name)),
         to_string(value(target, :ansible_host))}

      awx_target_keys(rest, [key | keys])
    end
  end

  defp awx_target_keys(_targets, _keys), do: {:error, :invalid_awx_target_snapshot}

  defp response_target_key(target) do
    {identity_key(target["target_identity"]), target["inventory_hostname"],
     target["inventory_address"]}
  end

  defp identity_key(identity) do
    {
      to_string(identity["controller_id"]),
      to_string(identity["inventory_id"]),
      to_string(identity["awx_host_id"]),
      identity["canonical_device_uid"]
    }
  end

  defp target_sort_key(target), do: response_target_key(target)

  defp validate_request_shape(request) do
    cond do
      request["action"] != @action ->
        {:error, :unsupported_callback_action}

      request["schema_version"] != @schema ->
        {:error, :invalid_response_schema}

      not digest?(request["manifest_sha256"], 64) ->
        {:error, :invalid_manifest_digest}

      not positive_integer?(request["job_id"]) ->
        {:error, :invalid_callback_job_id}

      request["phase"] not in @phases ->
        {:error, :invalid_callback_phase}

      request["operation"] not in @operations ->
        {:error, :invalid_callback_operation}

      request["state"] not in @states ->
        {:error, :invalid_callback_state}

      request["operation"] == "remove" != (request["state"] == "absent") ->
        {:error, :invalid_operation_state}

      true ->
        :ok
    end
  end

  defp string_map(map) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key

      cond do
        not is_binary(key) -> {:halt, {:error, :map_keys_must_be_strings}}
        Map.has_key?(acc, key) -> {:halt, {:error, {:duplicate_map_key, key}}}
        true -> {:cont, {:ok, Map.put(acc, key, value)}}
      end
    end)
  end

  defp string_map(_map), do: {:error, :object_required}

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp exact_keys(map, expected, reason) do
    if MapSet.new(Map.keys(map)) == expected, do: :ok, else: {:error, reason}
  end

  defp exact_optional_keys(map, allowed, reason) do
    if MapSet.subset?(MapSet.new(Map.keys(map)), allowed), do: :ok, else: {:error, reason}
  end

  defp enforce_size(bytes, maximum) when byte_size(bytes) <= maximum, do: :ok
  defp enforce_size(_bytes, _maximum), do: {:error, :callback_response_too_large}

  defp valid_ca_id?(value) when is_binary(value),
    do: Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/, value)

  defp valid_ca_id?(_value), do: false

  defp valid_public_key?(value) when is_binary(value) and byte_size(value) <= 16_384 do
    Regex.match?(
      ~r/\A(?:ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp(?:256|384|521)) [A-Za-z0-9+\/]+={0,3}(?: [^\r\n]+)?\z/,
      value
    ) and not String.contains?(value, "PRIVATE KEY")
  end

  defp valid_public_key?(_value), do: false

  defp valid_fingerprint?(value) when is_binary(value),
    do: Regex.match?(~r/\ASHA256:[A-Za-z0-9+\/]{20,60}\z/, value)

  defp valid_fingerprint?(_value), do: false

  defp valid_account?(value) when is_binary(value),
    do: Regex.match?(~r/\A[a-z_][a-z0-9_-]{0,31}\z/, value)

  defp valid_account?(_value), do: false

  defp valid_principal?(value) when is_binary(value),
    do: Regex.match?(~r/\Asrp_v1_[A-Za-z0-9_-]{20,96}\z/, value)

  defp valid_principal?(_value), do: false

  defp credential_reference(value, reason) when is_binary(value) do
    if Regex.match?(
         ~r/\A(?:awx|controller)-credential-ref:[A-Za-z0-9][A-Za-z0-9._\/-]{0,199}\z/,
         value
       ),
       do: :ok,
       else: {:error, reason}
  end

  defp credential_reference(_value, reason), do: {:error, reason}

  defp scalar_id(value, _reason) when is_integer(value) and value > 0, do: :ok
  defp scalar_id(value, _reason) when is_binary(value) and value != "", do: :ok
  defp scalar_id(_value, reason), do: {:error, reason}

  defp nonempty_string(value, _reason) when is_binary(value) and value != "", do: :ok
  defp nonempty_string(_value, reason), do: {:error, reason}

  defp datetime_string?(value) when is_binary(value) do
    match?({:ok, %DateTime{}, 0}, DateTime.from_iso8601(value))
  end

  defp datetime_string?(_value), do: false

  defp digest?(value, size) when is_integer(size),
    do: is_binary(value) and byte_size(value) == size and Regex.match?(~r/\A[0-9a-f]+\z/, value)

  defp digest?(value, %Range{} = size),
    do: is_binary(value) and byte_size(value) in size and Regex.match?(~r/\A[0-9a-f]+\z/, value)

  defp unique_by?(values, fun),
    do: values |> Enum.map(fun) |> Enum.uniq() |> length() == length(values)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp value(_map, _key), do: nil
end
