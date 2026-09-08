defmodule ServiceRadar.Automation.Ansible.FileCallbackResponsePolicyProvider do
  @moduledoc """
  Reads reviewed SSH-CA callback policy from a server-owned file.

  Policy entries are selected only by the immutable tenant/controller/inventory/
  template/binding/revision tuple. Target policy is selected only by the exact
  controller/inventory/AWX-host/canonical-device tuple. Hostnames and addresses
  are copied from the already-authorized launch snapshot and are never selectors.

  The file contains public CA keys and target-scoped policy only. Private signer
  material, passwords, bearer tokens, and reusable credentials are not accepted.
  """

  @behaviour ServiceRadar.Automation.Ansible.CallbackResponsePolicyProvider

  import Bitwise

  @schema "serviceradar.automation.callback_response_policy/v1"
  @action "remote_access.ssh_ca.bundle.read"
  @max_file_bytes 1_048_576
  @max_policies 64
  @max_ca_keys 8
  @max_targets 100

  @document_keys MapSet.new(~w(schema policies))

  @policy_keys MapSet.new(
                 ~w(enabled action action_version policy_version scope review signer_key_id ca_keys targets)
               )

  @scope_keys MapSet.new(
                ~w(tenant_id controller_id inventory_id job_template_id binding_id binding_version approval_id scm_revision content_sha256)
              )

  @review_keys MapSet.new(
                 ~w(state reviewed_by_principal_type reviewed_by_principal_id reviewed_at expires_at)
               )

  @identity_keys MapSet.new(~w(controller_id inventory_id awx_host_id canonical_device_uid))
  @ca_key_keys MapSet.new(~w(id public_key fingerprint))
  @target_keys MapSet.new(~w(state target_identity ca_key_ids accounts transaction))
  @account_keys MapSet.new(~w(name principals))

  @transaction_keys MapSet.new(
                      ~w(id stage_job_id verification_job_id generation machine_credential_ref)
                    )

  @allowed_key_types ~w(ssh-ed25519 ssh-rsa ecdsa-sha2-nistp256 ecdsa-sha2-nistp384 ecdsa-sha2-nistp521)

  @impl true
  def snapshot(context) when is_map(context) do
    with {:ok, path} <- configured_path(),
         {:ok, document} <- read_document(path),
         {:ok, policies} <- validate_document(document),
         {:ok, policy} <- select_policy(policies, context),
         :ok <- current_review(policy, context),
         {:ok, targets} <- materialize_targets(policy, context) do
      {:ok, %{"targets" => targets}}
    else
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :callback_response_policy_unavailable}
  catch
    _, _ -> {:error, :callback_response_policy_unavailable}
  end

  def snapshot(_context), do: {:error, :invalid_callback_response_policy_context}

  @doc false
  @spec snapshot_document(map(), map()) :: {:ok, map()} | {:error, term()}
  def snapshot_document(document, context) when is_map(document) and is_map(context) do
    with {:ok, policies} <- validate_document(document),
         {:ok, policy} <- select_policy(policies, context),
         :ok <- current_review(policy, context),
         {:ok, targets} <- materialize_targets(policy, context) do
      {:ok, %{"targets" => targets}}
    end
  end

  def snapshot_document(_document, _context),
    do: {:error, :invalid_callback_response_policy_document}

  @doc false
  @spec validate_file!(Path.t()) :: :ok
  def validate_file!(path) when is_binary(path) and path != "" do
    with {:ok, document} <- read_document(path),
         {:ok, _policies} <- validate_document(document) do
      :ok
    else
      _ -> raise "invalid automation callback response policy file"
    end
  end

  def validate_file!(_path), do: raise("automation callback response policy file is required")

  defp configured_path do
    path =
      :serviceradar_core
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:path)

    if is_binary(path) and path != "",
      do: {:ok, path},
      else: {:error, :callback_response_policy_file_required}
  end

  defp read_document(path) do
    with {:ok, stat} <- File.stat(path),
         true <- stat.type == :regular,
         true <- stat.size in 1..@max_file_bytes,
         true <- secure_mode?(stat.mode),
         {:ok, bytes} <- File.read(path),
         {:ok, document} <- Jason.decode(bytes),
         true <- is_map(document) do
      {:ok, document}
    else
      _ -> {:error, :callback_response_policy_file_invalid}
    end
  end

  defp validate_document(document) do
    with :ok <- exact_keys(document, @document_keys),
         true <- document["schema"] == @schema,
         policies when is_list(policies) <- document["policies"],
         true <- length(policies) in 1..@max_policies,
         {:ok, policies} <- validate_policies(policies),
         true <- unique_by?(policies, &policy_selector/1) do
      {:ok, policies}
    else
      _ -> {:error, :invalid_callback_response_policy_document}
    end
  end

  defp validate_policies(policies) do
    policies
    |> Enum.reduce_while({:ok, []}, fn policy, {:ok, validated} ->
      case validate_policy(policy) do
        {:ok, policy} -> {:cont, {:ok, [policy | validated]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, policies} -> {:ok, Enum.reverse(policies)}
      {:error, _} = error -> error
    end
  end

  defp validate_policy(policy) when is_map(policy) do
    with :ok <- exact_keys(policy, @policy_keys),
         true <- is_boolean(policy["enabled"]),
         true <- policy["action"] == @action,
         :ok <- semantic_version(policy["action_version"]),
         :ok <- bounded_text(policy["policy_version"], 255),
         {:ok, scope} <- validate_scope(policy["scope"]),
         {:ok, review} <- validate_review(policy["review"]),
         :ok <- key_id(policy["signer_key_id"]),
         {:ok, ca_keys} <- validate_ca_keys(policy["ca_keys"]),
         true <- Enum.any?(ca_keys, &(&1["id"] == policy["signer_key_id"])),
         {:ok, targets} <-
           validate_targets(policy["targets"], ca_keys, policy["signer_key_id"]) do
      {:ok,
       %{
         policy
         | "scope" => scope,
           "review" => review,
           "ca_keys" => ca_keys,
           "targets" => targets
       }}
    else
      _ -> {:error, :invalid_callback_response_policy_document}
    end
  end

  defp validate_policy(_policy), do: {:error, :invalid_callback_response_policy_document}

  defp validate_scope(scope) when is_map(scope) do
    with :ok <- exact_keys(scope, @scope_keys),
         :ok <- bounded_text(scope["tenant_id"], 255),
         :ok <- bounded_text(scope["controller_id"], 255),
         :ok <- positive_integer(scope["inventory_id"]),
         :ok <- positive_integer(scope["job_template_id"]),
         :ok <- bounded_text(scope["binding_id"], 255),
         :ok <- positive_integer(scope["binding_version"]),
         :ok <- bounded_text(scope["approval_id"], 255),
         :ok <- digest(scope["scm_revision"], 40..64),
         :ok <- digest(scope["content_sha256"], 64) do
      {:ok, scope}
    end
  end

  defp validate_scope(_scope), do: {:error, :invalid_callback_response_policy_document}

  defp validate_review(review) when is_map(review) do
    with :ok <- exact_keys(review, @review_keys),
         true <- review["state"] in ["approved", "disabled"],
         true <- review["reviewed_by_principal_type"] in ["human", "service_principal"],
         :ok <- bounded_text(review["reviewed_by_principal_id"], 255),
         {:ok, _reviewed_at} <- datetime(review["reviewed_at"]),
         {:ok, _expires_at} <- datetime(review["expires_at"]) do
      {:ok, review}
    else
      _ -> {:error, :invalid_callback_response_policy_document}
    end
  end

  defp validate_review(_review), do: {:error, :invalid_callback_response_policy_document}

  defp validate_ca_keys(keys) when is_list(keys) and length(keys) in 1..@max_ca_keys do
    keys
    |> Enum.reduce_while({:ok, []}, fn key, {:ok, validated} ->
      case validate_ca_key(key) do
        {:ok, key} -> {:cont, {:ok, [key | validated]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, keys} ->
        keys = Enum.sort_by(keys, & &1["id"])

        if unique_by?(keys, & &1["id"]) and unique_by?(keys, & &1["fingerprint"]),
          do: {:ok, keys},
          else: {:error, :invalid_callback_response_policy_document}

      {:error, _} = error ->
        error
    end
  end

  defp validate_ca_keys(_keys), do: {:error, :invalid_callback_response_policy_document}

  defp validate_ca_key(key) when is_map(key) do
    with :ok <- exact_keys(key, @ca_key_keys),
         :ok <- key_id(key["id"]),
         {:ok, blob} <- public_key_blob(key["public_key"]),
         expected = ssh_fingerprint(blob),
         true <- secure_equal(expected, key["fingerprint"]) do
      {:ok, key}
    else
      _ -> {:error, :invalid_callback_response_policy_document}
    end
  end

  defp validate_ca_key(_key), do: {:error, :invalid_callback_response_policy_document}

  defp public_key_blob(value) when is_binary(value) and byte_size(value) <= 16_384 do
    with false <- String.contains?(value, ["\n", "\r", "PRIVATE KEY"]),
         [key_type, encoded | _comment] <- String.split(value, " ", parts: 3, trim: true),
         true <- key_type in @allowed_key_types,
         {:ok, blob} <- Base.decode64(encoded),
         true <- byte_size(blob) in 16..16_384,
         true <- encoded_key_type(blob) == key_type do
      {:ok, blob}
    else
      _ -> {:error, :invalid_callback_response_policy_document}
    end
  end

  defp public_key_blob(_value), do: {:error, :invalid_callback_response_policy_document}

  defp encoded_key_type(<<size::unsigned-big-integer-size(32), rest::binary>>)
       when size > 0 and byte_size(rest) >= size do
    <<key_type::binary-size(size), _::binary>> = rest
    key_type
  end

  defp encoded_key_type(_blob), do: nil

  defp ssh_fingerprint(blob) do
    "SHA256:" <> Base.encode64(:crypto.hash(:sha256, blob), padding: false)
  end

  defp validate_targets(targets, ca_keys, signer_key_id)
       when is_list(targets) and length(targets) in 1..@max_targets do
    known_ca_ids = MapSet.new(ca_keys, & &1["id"])

    targets
    |> Enum.reduce_while({:ok, []}, fn target, {:ok, validated} ->
      case validate_target(target, known_ca_ids, signer_key_id) do
        {:ok, target} -> {:cont, {:ok, [target | validated]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, targets} ->
        targets = Enum.sort_by(targets, &identity_key(&1["target_identity"]))

        if unique_by?(targets, &identity_key(&1["target_identity"])),
          do: {:ok, targets},
          else: {:error, :invalid_callback_response_policy_document}

      {:error, _} = error ->
        error
    end
  end

  defp validate_targets(_targets, _ca_keys, _signer_key_id),
    do: {:error, :invalid_callback_response_policy_document}

  defp validate_target(target, known_ca_ids, signer_key_id) when is_map(target) do
    with :ok <- exact_keys(target, @target_keys),
         true <- target["state"] in ["ready", "disabled"],
         {:ok, identity} <- validate_identity(target["target_identity"]),
         {:ok, ca_key_ids} <- validate_ca_key_ids(target["ca_key_ids"], known_ca_ids),
         true <- signer_key_id in ca_key_ids,
         {:ok, accounts} <- validate_accounts(target["accounts"]),
         {:ok, transaction} <- validate_transaction(target["transaction"]) do
      {:ok,
       %{
         "state" => target["state"],
         "target_identity" => identity,
         "ca_key_ids" => ca_key_ids,
         "accounts" => accounts,
         "transaction" => transaction
       }}
    else
      _ -> {:error, :invalid_callback_response_policy_document}
    end
  end

  defp validate_target(_target, _known_ca_ids, _signer_key_id),
    do: {:error, :invalid_callback_response_policy_document}

  defp validate_identity(identity) when is_map(identity) do
    with :ok <- exact_keys(identity, @identity_keys),
         :ok <- bounded_text(identity["controller_id"], 255),
         :ok <- positive_integer(identity["inventory_id"]),
         :ok <- positive_integer(identity["awx_host_id"]),
         :ok <- bounded_text(identity["canonical_device_uid"], 512) do
      {:ok, identity}
    end
  end

  defp validate_identity(_identity), do: {:error, :invalid_callback_response_policy_document}

  defp validate_ca_key_ids(ids, known_ca_ids) when is_list(ids) and ids != [] do
    with true <- length(ids) <= @max_ca_keys,
         true <- Enum.all?(ids, &(is_binary(&1) and MapSet.member?(known_ca_ids, &1))),
         true <- length(ids) == length(Enum.uniq(ids)) do
      {:ok, Enum.sort(ids)}
    else
      _ -> {:error, :invalid_callback_response_policy_document}
    end
  end

  defp validate_ca_key_ids(_ids, _known_ca_ids),
    do: {:error, :invalid_callback_response_policy_document}

  defp validate_accounts(accounts) when is_list(accounts) and accounts != [] do
    accounts
    |> Enum.reduce_while({:ok, []}, fn account, {:ok, validated} ->
      case validate_account(account) do
        {:ok, account} -> {:cont, {:ok, [account | validated]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, accounts} ->
        accounts = Enum.sort_by(accounts, & &1["name"])

        if length(accounts) <= 64 and unique_by?(accounts, & &1["name"]),
          do: {:ok, accounts},
          else: {:error, :invalid_callback_response_policy_document}

      {:error, _} = error ->
        error
    end
  end

  defp validate_accounts(_accounts), do: {:error, :invalid_callback_response_policy_document}

  defp validate_account(account) when is_map(account) do
    principals = account["principals"]

    with :ok <- exact_keys(account, @account_keys),
         true <- valid_account?(account["name"]),
         true <- account["name"] != "root",
         true <- is_list(principals) and principals != [] and length(principals) <= 16,
         true <- Enum.all?(principals, &valid_principal?/1),
         true <- length(principals) == length(Enum.uniq(principals)) do
      {:ok, %{"name" => account["name"], "principals" => Enum.sort(principals)}}
    else
      _ -> {:error, :invalid_callback_response_policy_document}
    end
  end

  defp validate_account(_account), do: {:error, :invalid_callback_response_policy_document}

  defp validate_transaction(transaction) when is_map(transaction) do
    with true <- MapSet.subset?(MapSet.new(Map.keys(transaction)), @transaction_keys),
         :ok <- optional_text(transaction["id"], 255),
         :ok <- optional_scalar_id(transaction["stage_job_id"]),
         :ok <- optional_scalar_id(transaction["verification_job_id"]),
         :ok <- optional_text(transaction["generation"], 255),
         :ok <- optional_credential_reference(transaction["machine_credential_ref"]) do
      {:ok, transaction}
    else
      _ -> {:error, :invalid_callback_response_policy_document}
    end
  end

  defp validate_transaction(_transaction),
    do: {:error, :invalid_callback_response_policy_document}

  defp select_policy(policies, context) do
    matches = Enum.filter(policies, &policy_matches?(&1, context))

    case matches do
      [%{"enabled" => true} = policy] -> {:ok, policy}
      [_disabled] -> {:error, :callback_response_policy_not_ready}
      [] -> {:error, :callback_response_policy_not_found}
      _ -> {:error, :callback_response_policy_ambiguous}
    end
  end

  defp policy_matches?(policy, context) do
    policy["action"] == value(context, :action) and
      policy["action_version"] == value(context, :action_version) and
      policy["policy_version"] == value(context, :policy_version) and
      exact_scope?(policy["scope"], context)
  end

  defp exact_scope?(scope, context) do
    comparisons = [
      {scope["tenant_id"], value(context, :tenant_id)},
      {scope["controller_id"], value(context, :controller_id)},
      {scope["inventory_id"], value(context, :inventory_id)},
      {scope["job_template_id"], value(context, :job_template_id)},
      {scope["binding_id"], value(context, :binding_id)},
      {scope["binding_version"], value(context, :binding_version)},
      {scope["approval_id"], value(context, :approval_id)},
      {scope["scm_revision"], value(context, :scm_revision)},
      {scope["content_sha256"], value(context, :content_sha256)}
    ]

    Enum.all?(comparisons, fn {left, right} -> to_string(left) == to_string(right) end)
  end

  defp current_review(policy, context) do
    review = policy["review"]
    now = value(context, :now) || DateTime.utc_now()

    with true <- policy["enabled"] == true,
         true <- review["state"] == "approved",
         true <- review["reviewed_by_principal_type"] == reviewer_type(context),
         true <- review["reviewed_by_principal_id"] == value(context, :reviewed_by_principal_id),
         true <- review["reviewed_at"] == iso8601(value(context, :reviewed_at)),
         true <- review["expires_at"] == iso8601(value(context, :approval_expires_at)),
         {:ok, reviewed_at} <- datetime(review["reviewed_at"]),
         {:ok, expires_at} <- datetime(review["expires_at"]),
         true <- match?(%DateTime{}, now),
         true <- not DateTime.after?(reviewed_at, now),
         true <- DateTime.after?(expires_at, now) do
      :ok
    else
      _ -> {:error, :callback_response_policy_not_ready}
    end
  end

  defp materialize_targets(policy, context) do
    expected = List.wrap(value(context, :targets))
    configured = Map.new(policy["targets"], &{identity_key(&1["target_identity"]), &1})
    ca_keys = Map.new(policy["ca_keys"], &{&1["id"], &1})

    with true <- expected != [] and length(expected) == map_size(configured),
         {:ok, targets} <-
           Enum.reduce_while(expected, {:ok, []}, fn target, {:ok, materialized} ->
             with {:ok, identity} <- expected_identity(target),
                  true <- identity["controller_id"] == to_string(value(context, :controller_id)),
                  true <- identity["inventory_id"] == value(context, :inventory_id),
                  configured_target when is_map(configured_target) <-
                    Map.get(configured, identity_key(identity)),
                  true <- configured_target["state"] == "ready",
                  {:ok, hostname} <- required_text(value(target, :inventory_hostname), 512),
                  {:ok, address} <- required_text(value(target, :inventory_address), 512) do
               target_ca_keys =
                 Enum.map(configured_target["ca_key_ids"], &Map.fetch!(ca_keys, &1))

               result = %{
                 "inventory_hostname" => hostname,
                 "inventory_address" => address,
                 "target_identity" => identity,
                 "ca_keys" => target_ca_keys,
                 "accounts" => configured_target["accounts"],
                 "transaction" => configured_target["transaction"]
               }

               {:cont, {:ok, [result | materialized]}}
             else
               _ -> {:halt, {:error, :callback_response_target_scope_mismatch}}
             end
           end) do
      {:ok, Enum.sort_by(targets, &identity_key(&1["target_identity"]))}
    else
      _ -> {:error, :callback_response_target_scope_mismatch}
    end
  end

  defp expected_identity(target) when is_map(target) do
    identity = value(target, :target_identity)

    with true <- is_map(identity),
         {:ok, controller_id} <- required_text(value(identity, :controller_id), 255),
         inventory_id when is_integer(inventory_id) and inventory_id > 0 <-
           value(identity, :inventory_id),
         awx_host_id when is_integer(awx_host_id) and awx_host_id > 0 <-
           value(identity, :awx_host_id),
         {:ok, device_uid} <- required_text(value(identity, :canonical_device_uid), 512) do
      {:ok,
       %{
         "controller_id" => controller_id,
         "inventory_id" => inventory_id,
         "awx_host_id" => awx_host_id,
         "canonical_device_uid" => device_uid
       }}
    else
      _ -> {:error, :callback_response_target_scope_mismatch}
    end
  end

  defp expected_identity(_target), do: {:error, :callback_response_target_scope_mismatch}

  defp policy_selector(policy) do
    scope = policy["scope"]

    {
      policy["action"],
      policy["action_version"],
      policy["policy_version"],
      scope["tenant_id"],
      scope["controller_id"],
      scope["inventory_id"],
      scope["job_template_id"],
      scope["binding_id"],
      scope["binding_version"],
      scope["approval_id"],
      scope["scm_revision"],
      scope["content_sha256"]
    }
  end

  defp identity_key(identity) do
    {
      to_string(identity["controller_id"]),
      to_string(identity["inventory_id"]),
      to_string(identity["awx_host_id"]),
      identity["canonical_device_uid"]
    }
  end

  defp reviewer_type(context) do
    case value(context, :reviewed_by_principal_type) do
      value when value in [:human, "human"] -> "human"
      value when value in [:service_principal, "service_principal"] -> "service_principal"
      _ -> nil
    end
  end

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(value) when is_binary(value), do: value
  defp iso8601(_value), do: nil

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _ -> {:error, :invalid_callback_response_policy_document}
    end
  end

  defp datetime(%DateTime{} = value), do: {:ok, value}
  defp datetime(_value), do: {:error, :invalid_callback_response_policy_document}

  defp semantic_version(value) when is_binary(value) do
    if Regex.match?(~r/\A[0-9]+\.[0-9]+\.[0-9]+\z/, value),
      do: :ok,
      else: {:error, :invalid_callback_response_policy_document}
  end

  defp semantic_version(_value), do: {:error, :invalid_callback_response_policy_document}

  defp key_id(value) when is_binary(value) do
    if Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/, value),
      do: :ok,
      else: {:error, :invalid_callback_response_policy_document}
  end

  defp key_id(_value), do: {:error, :invalid_callback_response_policy_document}

  defp valid_account?(value) when is_binary(value),
    do: Regex.match?(~r/\A[a-z_][a-z0-9_-]{0,31}\z/, value)

  defp valid_account?(_value), do: false

  defp valid_principal?(value) when is_binary(value),
    do: Regex.match?(~r/\Asrp_v1_[A-Za-z0-9_-]{20,96}\z/, value)

  defp valid_principal?(_value), do: false

  defp optional_credential_reference(nil), do: :ok

  defp optional_credential_reference(value) when is_binary(value) do
    if Regex.match?(
         ~r/\A(?:awx|controller)-credential-ref:[A-Za-z0-9][A-Za-z0-9._\/-]{0,199}\z/,
         value
       ),
       do: :ok,
       else: {:error, :invalid_callback_response_policy_document}
  end

  defp optional_credential_reference(_value),
    do: {:error, :invalid_callback_response_policy_document}

  defp optional_scalar_id(nil), do: :ok
  defp optional_scalar_id(value) when is_integer(value) and value > 0, do: :ok
  defp optional_scalar_id(value) when is_binary(value) and value != "", do: :ok
  defp optional_scalar_id(_value), do: {:error, :invalid_callback_response_policy_document}

  defp optional_text(nil, _max_bytes), do: :ok
  defp optional_text(value, max_bytes), do: bounded_text(value, max_bytes)

  defp bounded_text(value, max_bytes)
       when is_binary(value) and value != "" and byte_size(value) <= max_bytes, do: :ok

  defp bounded_text(_value, _max_bytes), do: {:error, :invalid_callback_response_policy_document}

  defp required_text(value, max_bytes) do
    case bounded_text(value, max_bytes) do
      :ok -> {:ok, value}
      {:error, _} = error -> error
    end
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: :ok
  defp positive_integer(_value), do: {:error, :invalid_callback_response_policy_document}

  defp digest(value, size) when is_integer(size) do
    if is_binary(value) and byte_size(value) == size and Regex.match?(~r/\A[0-9a-f]+\z/, value),
      do: :ok,
      else: {:error, :invalid_callback_response_policy_document}
  end

  defp digest(value, %Range{} = sizes) do
    if is_binary(value) and byte_size(value) in sizes and Regex.match?(~r/\A[0-9a-f]+\z/, value),
      do: :ok,
      else: {:error, :invalid_callback_response_policy_document}
  end

  defp exact_keys(map, expected) when is_map(map) do
    if MapSet.new(Map.keys(map)) == expected,
      do: :ok,
      else: {:error, :invalid_callback_response_policy_document}
  end

  defp exact_keys(_map, _expected), do: {:error, :invalid_callback_response_policy_document}

  defp unique_by?(values, fun) do
    selected = Enum.map(values, fun)
    length(selected) == length(Enum.uniq(selected))
  end

  defp secure_equal(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: :crypto.hash_equals(left, right)

  defp secure_equal(_left, _right), do: false

  # Kubernetes projected Secrets are mounted 0440 by the chart. The owning
  # process may read and the owning group may read, but neither group nor
  # "other" may mutate policy and "other" may not observe its target mapping.
  defp secure_mode?(mode), do: (mode &&& 0o027) == 0 and (mode &&& 0o111) == 0

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp value(_map, _key), do: nil
end
