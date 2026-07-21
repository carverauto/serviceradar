defmodule ServiceRadar.Automation.Ansible.AwxLaunchPreflightAttestation do
  @moduledoc """
  Canonical immutable evidence linking a live AWX preflight to one launch.

  A preflight attestation carries identifiers, digests, and bounded timestamps
  only. It deliberately excludes the raw command result, live AWX projection,
  controller bearer, and target variables. The same canonical map is copied
  into both the operation and child execution, then revalidated before an AWX
  mutation is dispatched.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.AutomationAwxLaunchPreflightEvidence
  alias ServiceRadar.Automation.Ansible.ControllerSecuritySnapshot
  alias ServiceRadar.Automation.CallbackGrants.CanonicalJSON

  @schema "serviceradar.awx_live_launch_preflight_attestation.v1"
  @sha256_hex ~r/\A[0-9a-f]{64}\z/
  @forbidden_text_codepoints ~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u
  @max_dispatch_identifier_bytes 255

  @keys MapSet.new([
          "schema",
          "evidence_id",
          "command_id",
          "controller_id",
          "dispatch_agent_id",
          "dispatch_partition_id",
          "binding_id",
          "binding_version",
          "approval_id",
          "reviewed_launch_snapshot_digest",
          "preflight_request_digest",
          "target_snapshot_digest",
          "controller_security_snapshot_digest",
          "live_launch_snapshot_digest",
          "command_result_digest",
          "verified_at",
          "expires_at"
        ])

  @digest_keys [
    "reviewed_launch_snapshot_digest",
    "preflight_request_digest",
    "target_snapshot_digest",
    "controller_security_snapshot_digest",
    "live_launch_snapshot_digest",
    "command_result_digest"
  ]

  @evidence_digest_attrs %{
    "reviewed_launch_snapshot_digest" => :reviewed_launch_snapshot_digest,
    "preflight_request_digest" => :preflight_request_digest,
    "target_snapshot_digest" => :target_snapshot_digest,
    "controller_security_snapshot_digest" => :controller_security_snapshot_digest,
    "live_launch_snapshot_digest" => :live_launch_snapshot_digest,
    "command_result_digest" => :command_result_digest
  }

  @id_keys ["evidence_id", "command_id", "controller_id", "binding_id", "approval_id"]

  @system_actor SystemActor.system(:awx_launch_preflight_attestation)

  @doc "The only canonical immutable launch-preflight attestation schema."
  @spec schema() :: String.t()
  def schema, do: @schema

  @doc """
  Validates and canonicalizes a preflight attestation to a string-keyed map.

  The live gate may return atom keys, while persisted JSON maps use string
  keys. Both forms are accepted only when they have exactly the documented
  fields and canonical values.
  """
  @spec normalize(term()) :: {:ok, map()} | {:error, atom() | term()}
  def normalize(attestation) when is_map(attestation) do
    with {:ok, attestation} <- stringify_keys(attestation),
         :ok <- exact_keys(attestation),
         :ok <- equals(attestation["schema"], @schema, :awx_preflight_attestation_schema),
         :ok <- validate_ids(attestation),
         {:ok, binding_version} <- positive_integer(attestation["binding_version"]),
         :ok <- bounded_identifier(attestation["dispatch_agent_id"]),
         :ok <- bounded_identifier(attestation["dispatch_partition_id"]),
         :ok <- validate_digests(attestation),
         {:ok, verified_at} <- parse_datetime(attestation["verified_at"]),
         {:ok, expires_at} <- parse_datetime(attestation["expires_at"]),
         true <-
           DateTime.after?(expires_at, verified_at) or {:error, :awx_preflight_expiry_invalid} do
      {:ok,
       attestation
       |> Map.put("binding_version", binding_version)
       |> Map.put("verified_at", DateTime.to_iso8601(verified_at))
       |> Map.put("expires_at", DateTime.to_iso8601(expires_at))}
    else
      false -> {:error, :awx_preflight_attestation_invalid}
      {:error, _reason} = error -> error
      _ -> {:error, :awx_preflight_attestation_invalid}
    end
  end

  def normalize(_attestation), do: {:error, :awx_preflight_attestation_required}

  @doc "Returns the canonical digest of a valid immutable preflight attestation."
  @spec digest(term()) :: {:ok, String.t()} | {:error, atom() | term()}
  def digest(attestation) do
    with {:ok, snapshot} <- normalize(attestation) do
      CanonicalJSON.digest(snapshot)
    end
  end

  @doc """
  Builds the create-only operation/execution attributes for a valid attestation.
  """
  @spec attrs(term()) :: {:ok, map()} | {:error, atom() | term()}
  def attrs(attestation) do
    with {:ok, snapshot} <- normalize(attestation),
         {:ok, digest} <- CanonicalJSON.digest(snapshot) do
      {:ok,
       %{
         preflight_evidence_id: snapshot["evidence_id"],
         immutable_launch_snapshot: snapshot,
         immutable_launch_snapshot_digest: digest
       }}
    end
  end

  @doc "Verifies a canonical attestation against the current controller boundary."
  @spec verify_controller(term(), map() | struct()) :: :ok | {:error, atom() | term()}
  def verify_controller(attestation, controller) when is_map(controller) do
    with {:ok, snapshot} <- normalize(attestation),
         controller_id when is_binary(controller_id) <- value(controller, :id),
         agent_id when is_binary(agent_id) <- value(controller, :agent_id),
         true <-
           controller_id == snapshot["controller_id"] || {:error, :awx_preflight_controller_drift},
         true <- agent_id == snapshot["dispatch_agent_id"] || {:error, :awx_preflight_agent_drift},
         {:ok, current_snapshot} <- ControllerSecuritySnapshot.capture(controller),
         {:ok, current_digest} <- ControllerSecuritySnapshot.digest(current_snapshot),
         true <-
           secure_equal(current_digest, snapshot["controller_security_snapshot_digest"]) ||
             {:error, :awx_preflight_controller_drift} do
      :ok
    else
      false -> {:error, :awx_preflight_controller_drift}
      {:error, _reason} = error -> error
      _ -> {:error, :awx_preflight_controller_drift}
    end
  end

  def verify_controller(_attestation, _controller), do: {:error, :awx_preflight_controller_drift}

  @doc "Verifies the exact edge principal tuple selected by the preflight."
  @spec verify_dispatch_principal(term(), term(), term()) :: :ok | {:error, atom()}
  def verify_dispatch_principal(attestation, agent_id, partition_id) do
    with {:ok, snapshot} <- normalize(attestation),
         :ok <- bounded_identifier(agent_id),
         :ok <- bounded_identifier(partition_id),
         true <- agent_id == snapshot["dispatch_agent_id"] || {:error, :awx_preflight_agent_drift},
         true <-
           partition_id == snapshot["dispatch_partition_id"] ||
             {:error, :awx_preflight_partition_drift} do
      :ok
    else
      false -> {:error, :awx_preflight_dispatch_principal_drift}
      {:error, _reason} = error -> error
      _ -> {:error, :awx_preflight_dispatch_principal_drift}
    end
  end

  @doc "Verifies binding identity, approval, and reviewed snapshot digest."
  @spec verify_binding(term(), map() | struct()) :: :ok | {:error, atom()}
  def verify_binding(attestation, binding) when is_map(binding) do
    with {:ok, snapshot} <- normalize(attestation),
         true <-
           value(binding, :id) == snapshot["binding_id"] || {:error, :awx_preflight_binding_drift},
         true <-
           value(binding, :binding_version) == snapshot["binding_version"] ||
             {:error, :awx_preflight_binding_drift},
         true <-
           value(binding, :approval_id) == snapshot["approval_id"] ||
             {:error, :awx_preflight_approval_drift},
         true <-
           value(binding, :controller_id) == snapshot["controller_id"] ||
             {:error, :awx_preflight_binding_drift},
         true <- value(binding, :current) == true || {:error, :awx_preflight_binding_drift},
         true <-
           value(binding, :approval_state) in [:approved, "approved"] ||
             {:error, :awx_preflight_approval_drift},
         true <-
           secure_equal(
             to_string(value(binding, :reviewed_launch_snapshot_digest)),
             snapshot["reviewed_launch_snapshot_digest"]
           ) || {:error, :awx_preflight_binding_drift} do
      :ok
    else
      false -> {:error, :awx_preflight_binding_drift}
      {:error, _reason} = error -> error
      _ -> {:error, :awx_preflight_binding_drift}
    end
  end

  def verify_binding(_attestation, _binding), do: {:error, :awx_preflight_binding_drift}

  @doc "Requires an attestation to be usable at `now`; expiry is fail closed."
  @spec verify_fresh(term(), DateTime.t()) :: :ok | {:error, atom()}
  def verify_fresh(attestation, %DateTime{} = now) do
    with {:ok, snapshot} <- normalize(attestation),
         {:ok, verified_at} <- parse_datetime(snapshot["verified_at"]),
         {:ok, expires_at} <- parse_datetime(snapshot["expires_at"]),
         true <-
           DateTime.compare(now, verified_at) in [:eq, :gt] ||
             {:error, :awx_preflight_timestamp_invalid},
         true <- DateTime.before?(now, expires_at) || {:error, :awx_preflight_evidence_expired} do
      :ok
    else
      false -> {:error, :awx_preflight_timestamp_invalid}
      {:error, _reason} = error -> error
      _ -> {:error, :awx_preflight_timestamp_invalid}
    end
  end

  def verify_fresh(_attestation, _now), do: {:error, :awx_preflight_timestamp_invalid}

  @doc """
  Verifies that an independently persisted evidence record exactly backs the
  immutable snapshot. The evidence does not point back to an operation or
  execution, preserving denied-preflight audit records.
  """
  @spec verify_evidence(term(), map() | struct()) :: :ok | {:error, atom()}
  def verify_evidence(attestation, evidence) when is_map(evidence) do
    with {:ok, snapshot} <- normalize(attestation),
         true <-
           value(evidence, :id) == snapshot["evidence_id"] ||
             {:error, :awx_preflight_evidence_mismatch},
         true <-
           value(evidence, :command_id) == snapshot["command_id"] ||
             {:error, :awx_preflight_evidence_mismatch},
         true <-
           value(evidence, :controller_id) == snapshot["controller_id"] ||
             {:error, :awx_preflight_evidence_mismatch},
         true <-
           value(evidence, :dispatch_agent_id) == snapshot["dispatch_agent_id"] ||
             {:error, :awx_preflight_evidence_mismatch},
         true <-
           value(evidence, :dispatch_partition_id) == snapshot["dispatch_partition_id"] ||
             {:error, :awx_preflight_evidence_mismatch},
         true <-
           value(evidence, :binding_id) == snapshot["binding_id"] ||
             {:error, :awx_preflight_evidence_mismatch},
         true <-
           value(evidence, :binding_version) == snapshot["binding_version"] ||
             {:error, :awx_preflight_evidence_mismatch},
         true <-
           value(evidence, :approval_id) == snapshot["approval_id"] ||
             {:error, :awx_preflight_evidence_mismatch},
         :ok <- exact_evidence_digests(snapshot, evidence),
         true <-
           iso8601(value(evidence, :verified_at)) == snapshot["verified_at"] ||
             {:error, :awx_preflight_evidence_mismatch},
         true <-
           iso8601(value(evidence, :expires_at)) == snapshot["expires_at"] ||
             {:error, :awx_preflight_evidence_mismatch} do
      :ok
    else
      false -> {:error, :awx_preflight_evidence_mismatch}
      {:error, _reason} = error -> error
      _ -> {:error, :awx_preflight_evidence_mismatch}
    end
  end

  def verify_evidence(_attestation, _evidence), do: {:error, :awx_preflight_evidence_unavailable}

  @doc """
  Validates matching, create-only operation/execution copies and their
  independent evidence before a new privileged AWX mutation.

  This verifier always requires a currently fresh preflight. Callers that
  only reconcile or remove work that was already sent to AWX must use
  `verify_persisted_for_cleanup/5` and force their continuation into a
  cleanup-only path.
  """
  @spec verify_persisted(
          map() | struct(),
          map() | struct(),
          map() | struct(),
          DateTime.t(),
          keyword()
        ) ::
          {:ok, map()} | {:error, atom() | term()}
  def verify_persisted(operation, execution, controller, now, opts \\ [])

  def verify_persisted(operation, execution, controller, %DateTime{} = now, opts)
      when is_map(operation) and is_map(execution) and is_map(controller) and is_list(opts) do
    verify_persisted_internal(operation, execution, controller, now, opts, :fresh)
  end

  def verify_persisted(_operation, _execution, _controller, _now, _opts),
    do: {:error, :awx_preflight_attestation_required}

  @doc """
  Validates the durable attestation/evidence/controller boundary for a
  cleanup-only callback continuation without requiring that the original
  preflight TTL is still open.

  It is intentionally a separate API rather than a caller-controlled option:
  it may only be used where the caller will not create a credential or launch
  a job. Callers must still bind the returned snapshot to their exact edge
  principal with `verify_dispatch_principal/3` before acting.
  """
  @spec verify_persisted_for_cleanup(
          map() | struct(),
          map() | struct(),
          map() | struct(),
          DateTime.t(),
          keyword()
        ) ::
          {:ok, map()} | {:error, atom() | term()}
  def verify_persisted_for_cleanup(operation, execution, controller, now, opts \\ [])

  def verify_persisted_for_cleanup(operation, execution, controller, %DateTime{} = now, opts)
      when is_map(operation) and is_map(execution) and is_map(controller) and is_list(opts) do
    verify_persisted_internal(operation, execution, controller, now, opts, :cleanup)
  end

  def verify_persisted_for_cleanup(_operation, _execution, _controller, _now, _opts),
    do: {:error, :awx_preflight_attestation_required}

  defp verify_persisted_internal(operation, execution, controller, now, opts, freshness)
       when freshness in [:fresh, :cleanup] do
    with {:ok, operation_snapshot} <- persisted_snapshot(operation),
         {:ok, execution_snapshot} <- persisted_snapshot(execution),
         {:ok, operation_digest} <- digest(operation_snapshot),
         {:ok, execution_digest} <- digest(execution_snapshot),
         true <-
           operation_snapshot == execution_snapshot || {:error, :awx_preflight_snapshot_mismatch},
         true <-
           secure_equal(operation_digest, execution_digest) ||
             {:error, :awx_preflight_snapshot_mismatch},
         true <-
           secure_equal(
             operation_digest,
             to_string(value(operation, :immutable_launch_snapshot_digest))
           ) || {:error, :awx_preflight_snapshot_digest_mismatch},
         true <-
           secure_equal(
             execution_digest,
             to_string(value(execution, :immutable_launch_snapshot_digest))
           ) || {:error, :awx_preflight_snapshot_digest_mismatch},
         true <-
           value(operation, :preflight_evidence_id) == operation_snapshot["evidence_id"] ||
             {:error, :awx_preflight_evidence_mismatch},
         true <-
           value(execution, :preflight_evidence_id) == operation_snapshot["evidence_id"] ||
             {:error, :awx_preflight_evidence_mismatch},
         {:ok, evidence} <- load_evidence(operation_snapshot["evidence_id"], opts),
         :ok <- verify_evidence(operation_snapshot, evidence),
         :ok <- verify_freshness(operation_snapshot, now, freshness),
         :ok <- verify_controller(operation_snapshot, controller) do
      {:ok, operation_snapshot}
    else
      false -> {:error, :awx_preflight_snapshot_mismatch}
      {:error, _reason} = error -> error
      _ -> {:error, :awx_preflight_attestation_required}
    end
  end

  defp verify_freshness(attestation, now, :fresh), do: verify_fresh(attestation, now)

  # Cleanup is allowed after the expiry boundary, but never before the
  # evidenced preflight occurred. Keeping this not-before check prevents an
  # independently persisted future record from selecting a cleanup path early.
  defp verify_freshness(attestation, %DateTime{} = now, :cleanup) do
    with {:ok, snapshot} <- normalize(attestation),
         {:ok, verified_at} <- parse_datetime(snapshot["verified_at"]),
         true <-
           DateTime.compare(now, verified_at) in [:eq, :gt] ||
             {:error, :awx_preflight_timestamp_invalid} do
      :ok
    else
      false -> {:error, :awx_preflight_timestamp_invalid}
      {:error, _reason} = error -> error
      _ -> {:error, :awx_preflight_timestamp_invalid}
    end
  end

  defp persisted_snapshot(resource) when is_map(resource) do
    with snapshot when is_map(snapshot) <- value(resource, :immutable_launch_snapshot),
         {:ok, snapshot} <- normalize(snapshot) do
      {:ok, snapshot}
    else
      _ -> {:error, :awx_preflight_attestation_required}
    end
  end

  defp persisted_snapshot(_resource), do: {:error, :awx_preflight_attestation_required}

  defp load_evidence(id, opts) do
    reader =
      Keyword.get(opts, :evidence_reader, fn evidence_id ->
        AutomationAwxLaunchPreflightEvidence.get_by_id(evidence_id, actor: @system_actor)
      end)

    if is_function(reader, 1) do
      case reader.(id) do
        {:ok, evidence} when is_map(evidence) -> {:ok, evidence}
        _ -> {:error, :awx_preflight_evidence_unavailable}
      end
    else
      {:error, :awx_preflight_evidence_unavailable}
    end
  end

  defp validate_ids(attestation) do
    Enum.reduce_while(@id_keys, :ok, fn key, :ok ->
      case valid_uuid(attestation[key]) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_digests(attestation) do
    if Enum.all?(
         @digest_keys,
         &(is_binary(attestation[&1]) and Regex.match?(@sha256_hex, attestation[&1]))
       ),
       do: :ok,
       else: {:error, :awx_preflight_digest_invalid}
  end

  defp exact_evidence_digests(snapshot, evidence) do
    if Enum.all?(@digest_keys, fn key ->
         case value(evidence, Map.fetch!(@evidence_digest_attrs, key)) do
           value when is_binary(value) -> secure_equal(value, snapshot[key])
           _ -> false
         end
       end) do
      :ok
    else
      {:error, :awx_preflight_evidence_mismatch}
    end
  end

  defp exact_keys(attestation) do
    if MapSet.new(Map.keys(attestation)) == @keys,
      do: :ok,
      else: {:error, :awx_preflight_attestation_fields_invalid}
  end

  defp stringify_keys(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn
      {key, value}, {:ok, acc} when is_binary(key) ->
        if Map.has_key?(acc, key),
          do: {:halt, {:error, :awx_preflight_attestation_keys_invalid}},
          else: {:cont, {:ok, Map.put(acc, key, value)}}

      {key, value}, {:ok, acc} when is_atom(key) ->
        normalized = Atom.to_string(key)

        if Map.has_key?(acc, normalized),
          do: {:halt, {:error, :awx_preflight_attestation_keys_invalid}},
          else: {:cont, {:ok, Map.put(acc, normalized, value)}}

      _entry, _acc ->
        {:halt, {:error, :awx_preflight_attestation_keys_invalid}}
    end)
  end

  defp valid_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, ^value} -> :ok
      _ -> {:error, :awx_preflight_uuid_invalid}
    end
  end

  defp valid_uuid(_value), do: {:error, :awx_preflight_uuid_invalid}

  defp positive_integer(value) when is_integer(value) and value > 0 and value <= 2_147_483_647,
    do: {:ok, value}

  defp positive_integer(_value), do: {:error, :awx_preflight_binding_version_invalid}

  defp bounded_identifier(value) when is_binary(value) do
    if byte_size(value) in 1..@max_dispatch_identifier_bytes and String.valid?(value) and
         String.trim(value) == value and not Regex.match?(@forbidden_text_codepoints, value) do
      :ok
    else
      {:error, :awx_preflight_dispatch_identity_invalid}
    end
  end

  defp bounded_identifier(_value), do: {:error, :awx_preflight_dispatch_identity_invalid}

  defp parse_datetime(%DateTime{} = value), do: {:ok, value}

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _ -> {:error, :awx_preflight_timestamp_invalid}
    end
  end

  defp parse_datetime(_value), do: {:error, :awx_preflight_timestamp_invalid}

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(value) when is_binary(value), do: value
  defp iso8601(_value), do: nil

  defp equals(left, right, _error) when left == right, do: :ok
  defp equals(_left, _right, error), do: {:error, error}

  defp secure_equal(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: :crypto.hash_equals(left, right)

  defp secure_equal(_left, _right), do: false

  defp value(map, key) when is_map(map) and is_binary(key), do: Map.get(map, key)

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp value(_map, _key), do: nil
end
