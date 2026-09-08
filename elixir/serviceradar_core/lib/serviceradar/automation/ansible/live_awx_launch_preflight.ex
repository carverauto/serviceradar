defmodule ServiceRadar.Automation.Ansible.LiveAwxLaunchPreflight do
  @moduledoc """
  Fail-closed, read-only AWX launch-preflight attestation.

  This is deliberately a narrow boundary between the reviewed ServiceRadar
  binding and the later mutable launch path. It builds the preflight request
  only from already-authorized current membership tuples, asks the controller's
  assigned edge principal for one read-only preflight, and writes independent
  digest-only evidence before an operation or execution exists.

  The module does not create an operation, execution, PlaybookRun, or AWX
  launch command. Callers must re-read authorization and mutable state after
  this returns and before handing its attestation to `HardenedLaunchPlan`.
  Neither the request nor the live AWX projection is returned or persisted here.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.AutomationAwxLaunchPreflightEvidence
  alias ServiceRadar.Automation.Ansible.AwxLaunchContract
  alias ServiceRadar.Automation.Ansible.ControllerProvenance
  alias ServiceRadar.Automation.Ansible.ControllerSecuritySnapshot

  @attestation_schema "serviceradar.awx_live_launch_preflight_attestation.v1"
  @controller_security_schema "serviceradar.awx_controller_security_snapshot.v1"
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @sha256_hex ~r/\A[0-9a-f]{64}\z/
  @source_fingerprint ~r/\Asha256:[0-9a-f]{64}\z/
  @canonical_positive_id ~r/\A[1-9][0-9]*\z/
  @forbidden_text_codepoints ~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u
  @max_awx_id 2_147_483_647
  @max_binding_version 2_147_483_647
  @max_dispatch_identity_bytes 255
  @default_evidence_ttl_seconds 60
  @max_evidence_ttl_seconds 60

  @controller_security_keys MapSet.new([
                              "schema",
                              "controller_id",
                              "name",
                              "base_url",
                              "agent_id",
                              "enabled",
                              "insecure_skip_verify",
                              "credential_refs"
                            ])
  @credential_reference_keys MapSet.new(["sync", "execution", "callback"])
  @provenance_result_keys MapSet.new([
                            :command_id,
                            :preflight,
                            :request_digest,
                            :preflight_digest,
                            :command_result_digest
                          ])

  @typedoc """
  Digest-only evidence suitable for inclusion in a later immutable launch
  snapshot. It intentionally contains neither a preflight projection nor an
  AWX request payload.
  """
  @type attestation :: %{
          required(:schema) => String.t(),
          required(:evidence_id) => String.t(),
          required(:command_id) => String.t(),
          required(:controller_id) => String.t(),
          required(:dispatch_agent_id) => String.t(),
          required(:dispatch_partition_id) => String.t(),
          required(:binding_id) => String.t(),
          required(:binding_version) => pos_integer(),
          required(:approval_id) => String.t(),
          required(:reviewed_launch_snapshot_digest) => String.t(),
          required(:preflight_request_digest) => String.t(),
          required(:target_snapshot_digest) => String.t(),
          required(:controller_security_snapshot_digest) => String.t(),
          required(:live_launch_snapshot_digest) => String.t(),
          required(:command_result_digest) => String.t(),
          required(:verified_at) => DateTime.t(),
          required(:expires_at) => DateTime.t()
        }

  @doc """
  Attests one read-only live AWX preflight.

  `context` must provide `:controller`, `:binding`, and the exact selected
  current `:memberships`. It must also provide a frozen
  `:controller_security_snapshot` and `:dispatcher_identity` (with `agent_id`
  and `partition_id`), either directly or through the matching options. The
  passed dispatcher agent must exactly equal both the controller and frozen
  snapshot agent.

  Options are intentionally dependency injection points for tests and the
  existing controller command path, not alternate controller transports:

    * `:controller_provenance` — a module exporting
      `fetch_launch_preflight/3`, or a function of arity three;
    * `:controller_provenance_opts` — forwarded only after this module pins the
      frozen controller snapshot and partition;
    * `:evidence_resource` — a module exporting `record/2`, or a function of
      arity two;
    * `:clock` — a zero-arity function returning a UTC `DateTime`;
    * `:preflight_ttl_seconds` — from one through sixty seconds.

  `ControllerProvenance` owns calculation of `command_result_digest` from the
  exact persisted, redacted command result envelope. This gate never accepts a
  raw result envelope and therefore never recomputes that digest from arbitrary
  caller data.
  """
  @spec attest(map(), keyword()) :: {:ok, attestation()} | {:error, term()}
  def attest(context, opts \\ [])

  def attest(context, opts) when is_map(context) and is_list(opts) do
    with {:ok, requested_at} <- now(opts),
         {:ok, controller} <- controller(context),
         {:ok, binding} <- launch_binding(context),
         {:ok, dispatcher} <- dispatcher_identity(context, opts),
         {:ok, security_snapshot} <- controller_security_snapshot(context, opts),
         {:ok, binding_info} <- validate_binding(binding, controller.id, requested_at),
         {:ok, reviewed} <- reviewed_contract(binding),
         :ok <- reviewed_controller_matches(reviewed, controller.id),
         {:ok, reviewed_digest} <- reviewed_digest(reviewed, binding_info.reviewed_digest),
         {:ok, security_digest} <-
           validate_controller_security_snapshot(
             security_snapshot,
             controller,
             dispatcher.agent_id
           ),
         {:ok, selected_hosts} <- selected_hosts(context, controller.id, reviewed),
         {:ok, request} <- request_for(binding, selected_hosts),
         {:ok, request_digest} <- AwxLaunchContract.request_digest(request),
         {:ok, target_digest} <- AwxLaunchContract.target_snapshot_digest(request),
         {:ok, provenance_result} <-
           fetch_preflight(controller.raw, request, security_snapshot, dispatcher, opts),
         {:ok, live_result} <-
           verify_live_result(provenance_result, request, reviewed, request_digest),
         {:ok, verified_at} <- now(opts),
         {:ok, expires_at} <-
           evidence_expiry(binding_info.approval_expires_at, verified_at, opts),
         attrs =
           evidence_attrs(
             provenance_result,
             controller.id,
             dispatcher,
             binding_info,
             reviewed_digest,
             request_digest,
             target_digest,
             security_digest,
             live_result,
             verified_at,
             expires_at
           ),
         {:ok, evidence_id} <- record_evidence(attrs, opts) do
      {:ok,
       attestation(
         evidence_id,
         provenance_result.command_id,
         controller.id,
         dispatcher,
         binding_info,
         reviewed_digest,
         request_digest,
         target_digest,
         security_digest,
         live_result,
         verified_at,
         expires_at
       )}
    end
  end

  def attest(_context, _opts), do: {:error, :invalid_live_awx_preflight_context}

  defp controller(context) do
    case value(context, :controller) do
      raw when is_map(raw) ->
        id = value(raw, :id)
        agent_id = value(raw, :agent_id)

        cond do
          value(raw, :enabled) != true ->
            {:error, :controller_disabled}

          not canonical_uuid?(id) ->
            {:error, :invalid_preflight_controller}

          not dispatch_identity?(agent_id) ->
            {:error, :invalid_preflight_controller}

          true ->
            {:ok, %{id: id, agent_id: agent_id, raw: raw}}
        end

      _ ->
        {:error, :invalid_preflight_controller}
    end
  end

  defp launch_binding(context) do
    case value(context, :binding) do
      raw when is_map(raw) -> {:ok, raw}
      _ -> {:error, :binding_required}
    end
  end

  defp dispatcher_identity(context, opts) do
    source =
      value(context, :dispatcher_identity) ||
        Keyword.get(opts, :dispatcher_identity) ||
        %{
          agent_id: value(context, :dispatch_agent_id) || Keyword.get(opts, :dispatch_agent_id),
          partition_id:
            value(context, :dispatch_partition_id) || Keyword.get(opts, :dispatch_partition_id)
        }

    agent_id = value(source, :agent_id) || value(source, :dispatch_agent_id)
    partition_id = value(source, :partition_id) || value(source, :dispatch_partition_id)

    if dispatch_identity?(agent_id) and dispatch_identity?(partition_id),
      do: {:ok, %{agent_id: agent_id, partition_id: partition_id}},
      else: {:error, :dispatcher_identity_required}
  end

  defp controller_security_snapshot(context, opts) do
    snapshot =
      value(context, :controller_security_snapshot) ||
        Keyword.get(opts, :controller_security_snapshot)

    if is_map(snapshot),
      do: {:ok, snapshot},
      else: {:error, :controller_security_snapshot_required}
  end

  defp validate_binding(binding, controller_id, requested_at) do
    id = value(binding, :id)
    binding_controller_id = value(binding, :controller_id)
    binding_version = value(binding, :binding_version)
    approval_id = value(binding, :approval_id)
    approval_expires_at = value(binding, :approval_expires_at)
    reviewed_digest = value(binding, :reviewed_launch_snapshot_digest)

    cond do
      value(binding, :current) != true ->
        {:error, :binding_not_current}

      not approved?(value(binding, :approval_state)) ->
        {:error, :binding_not_approved}

      not canonical_uuid?(id) ->
        {:error, :binding_id_required}

      binding_controller_id != controller_id ->
        {:error, :binding_controller_mismatch}

      not canonical_uuid?(approval_id) ->
        {:error, :binding_approval_required}

      not is_integer(binding_version) or binding_version not in 1..@max_binding_version ->
        {:error, :binding_version_required}

      not valid_digest?(reviewed_digest) ->
        {:error, :reviewed_launch_contract_required}

      not valid_utc_datetime?(approval_expires_at) ->
        {:error, :binding_approval_expiry_required}

      DateTime.compare(approval_expires_at, requested_at) != :gt ->
        {:error, :binding_approval_expired}

      true ->
        {:ok,
         %{
           id: id,
           binding_version: binding_version,
           approval_id: approval_id,
           approval_expires_at: approval_expires_at,
           reviewed_digest: reviewed_digest
         }}
    end
  end

  defp reviewed_contract(binding) do
    case AwxLaunchContract.from_binding(binding) do
      {:ok, reviewed} -> {:ok, reviewed}
      {:error, _reason} -> {:error, :reviewed_launch_contract_required}
    end
  end

  defp reviewed_controller_matches(reviewed, controller_id) do
    if reviewed["controller_id"] == controller_id,
      do: :ok,
      else: {:error, :reviewed_launch_controller_mismatch}
  end

  defp reviewed_digest(reviewed, expected_digest) do
    with {:ok, digest} <- AwxLaunchContract.digest(reviewed),
         true <- digest == expected_digest || {:error, :reviewed_launch_digest_mismatch} do
      {:ok, digest}
    else
      false -> {:error, :reviewed_launch_digest_mismatch}
      {:error, _reason} = error -> error
      _ -> {:error, :reviewed_launch_digest_mismatch}
    end
  end

  defp validate_controller_security_snapshot(snapshot, controller, dispatch_agent_id) do
    with :ok <- exact_string_keys(snapshot, @controller_security_keys),
         true <-
           snapshot["schema"] == @controller_security_schema ||
             {:error, :invalid_controller_security_snapshot},
         true <-
           snapshot["controller_id"] == controller.id ||
             {:error, :controller_security_snapshot_mismatch},
         true <-
           snapshot["agent_id"] == controller.agent_id ||
             {:error, :controller_security_snapshot_mismatch},
         true <- snapshot["agent_id"] == dispatch_agent_id || {:error, :dispatcher_agent_mismatch},
         true <- snapshot["enabled"] == true || {:error, :controller_security_snapshot_mismatch},
         true <-
           (is_binary(snapshot["name"]) and byte_size(snapshot["name"]) in 1..255) ||
             {:error, :invalid_controller_security_snapshot},
         true <-
           (is_binary(snapshot["base_url"]) and byte_size(snapshot["base_url"]) in 1..2_048) ||
             {:error, :invalid_controller_security_snapshot},
         true <-
           is_boolean(snapshot["insecure_skip_verify"]) ||
             {:error, :invalid_controller_security_snapshot},
         :ok <- validate_credential_references(snapshot["credential_refs"]),
         {:ok, digest} <- ControllerSecuritySnapshot.digest(snapshot) do
      {:ok, digest}
    else
      false -> {:error, :invalid_controller_security_snapshot}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_controller_security_snapshot}
    end
  end

  defp validate_credential_references(references) when is_map(references) do
    with :ok <- exact_string_keys(references, @credential_reference_keys),
         true <-
           bounded_reference?(references["sync"]) ||
             {:error, :invalid_controller_security_snapshot},
         true <-
           bounded_reference?(references["execution"]) ||
             {:error, :invalid_controller_security_snapshot},
         true <-
           (is_nil(references["callback"]) or bounded_reference?(references["callback"])) ||
             {:error, :invalid_controller_security_snapshot} do
      :ok
    else
      false -> {:error, :invalid_controller_security_snapshot}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_controller_security_snapshot}
    end
  end

  defp selected_hosts(context, controller_id, reviewed) do
    inventory_id = reviewed["inventory"]["id"]

    case value(context, :memberships) do
      memberships when is_list(memberships) and length(memberships) in 1..128 ->
        memberships
        |> Enum.reduce_while({:ok, []}, fn membership, {:ok, acc} ->
          case membership_request_host(membership, controller_id, inventory_id) do
            {:ok, host} -> {:cont, {:ok, [host | acc]}}
            {:error, _reason} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, hosts} ->
            hosts
            |> Enum.reverse()
            |> Enum.sort_by(&String.to_integer(&1["awx_host_id"]))
            |> then(&{:ok, &1})

          {:error, _reason} = error ->
            error
        end

      _ ->
        {:error, :awx_preflight_targets_required}
    end
  end

  defp membership_request_host(membership, controller_id, inventory_id) when is_map(membership) do
    membership_id = value(membership, :id) || value(membership, :membership_id)
    membership_controller_id = value(membership, :controller_id)
    membership_inventory_id = value(membership, :inventory_id)
    awx_host_id = value(membership, :awx_host_id) || value(membership, :host_id)

    canonical_device_uid =
      value(membership, :canonical_device_uid) || value(membership, :device_uid)

    host_name = value(membership, :host_name) || value(membership, :awx_host_name)
    ansible_host = value(membership, :ansible_host)

    membership_generation =
      value(membership, :source_generation) || value(membership, :membership_generation)

    source_fingerprint = value(membership, :source_fingerprint)

    with true <- value(membership, :current) == true || {:error, :stale_awx_membership},
         true <- value(membership, :enabled) == true || {:error, :disabled_awx_membership},
         true <-
           approved?(value(membership, :link_disposition)) || {:error, :unapproved_awx_membership},
         true <- canonical_uuid?(membership_id) || {:error, :invalid_awx_preflight_membership},
         true <-
           membership_controller_id == controller_id || {:error, :awx_preflight_target_mismatch},
         {:ok, canonical_inventory_id} <- canonical_awx_id(membership_inventory_id),
         true <-
           canonical_inventory_id == inventory_id || {:error, :awx_preflight_target_mismatch},
         {:ok, canonical_host_id} <- canonical_awx_id(awx_host_id),
         {:ok, canonical_generation} <- canonical_awx_id(membership_generation),
         true <- is_binary(canonical_device_uid) || {:error, :invalid_awx_preflight_membership},
         true <- is_binary(host_name) || {:error, :invalid_awx_preflight_membership},
         true <- is_binary(ansible_host) || {:error, :invalid_awx_preflight_membership},
         true <-
           valid_source_fingerprint?(source_fingerprint) ||
             {:error, :invalid_awx_preflight_membership} do
      {:ok,
       %{
         "membership_id" => membership_id,
         "controller_id" => controller_id,
         "inventory_id" => canonical_inventory_id,
         "awx_host_id" => canonical_host_id,
         "canonical_device_uid" => canonical_device_uid,
         "host_name" => host_name,
         "ansible_host" => ansible_host,
         "enabled" => true,
         "membership_generation" => canonical_generation,
         "source_fingerprint" => source_fingerprint
       }}
    else
      false -> {:error, :invalid_awx_preflight_membership}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_awx_preflight_membership}
    end
  end

  defp membership_request_host(_membership, _controller_id, _inventory_id),
    do: {:error, :invalid_awx_preflight_membership}

  defp request_for(binding, selected_hosts) do
    case AwxLaunchContract.request_from(binding, selected_hosts) do
      {:ok, request} -> {:ok, request}
      {:error, _reason} -> {:error, :invalid_awx_preflight_request}
    end
  end

  defp fetch_preflight(controller, request, security_snapshot, dispatcher, opts) do
    provenance = Keyword.get(opts, :controller_provenance, ControllerProvenance)

    provenance_opts =
      opts
      |> Keyword.get(:controller_provenance_opts, [])
      |> normalize_keyword_options()
      |> Keyword.put(:expected_controller_snapshot, security_snapshot)
      |> Keyword.put(:expected_partition_id, dispatcher.partition_id)

    result =
      case provenance do
        fun when is_function(fun, 3) ->
          fun.(controller, request, provenance_opts)

        module when is_atom(module) ->
          apply(module, :fetch_launch_preflight, [controller, request, provenance_opts])

        _ ->
          {:error, :controller_launch_preflight_unavailable}
      end

    case result do
      {:ok, result} when is_map(result) -> {:ok, result}
      _ -> {:error, :controller_launch_preflight_unavailable}
    end
  rescue
    UndefinedFunctionError -> {:error, :controller_launch_preflight_unavailable}
  end

  defp verify_live_result(result, request, reviewed, expected_request_digest) do
    with {:ok, result} <- normalize_provenance_result(result),
         true <-
           result.request_digest == expected_request_digest ||
             {:error, :awx_preflight_request_digest_mismatch},
         {:ok, live_preflight} <-
           AwxLaunchContract.verify(result.preflight, result.preflight_digest),
         :ok <- verify_static_contract(reviewed, live_preflight),
         :ok <- normalize_target_result(AwxLaunchContract.verify_targets(request, live_preflight)) do
      {:ok,
       %{
         preflight_digest: result.preflight_digest,
         command_result_digest: result.command_result_digest
       }}
    else
      false -> {:error, :awx_preflight_result_invalid}
      {:error, _reason} = error -> error
      _ -> {:error, :awx_preflight_result_invalid}
    end
  end

  defp verify_static_contract(reviewed, live_preflight) do
    case AwxLaunchContract.static_drift_reason(reviewed, live_preflight) do
      :none -> :ok
      reason -> {:error, reason}
    end
  end

  defp normalize_provenance_result(result) when is_map(result) do
    if MapSet.new(Map.keys(result)) == @provenance_result_keys do
      command_id = result.command_id
      request_digest = result.request_digest
      preflight_digest = result.preflight_digest
      command_result_digest = result.command_result_digest

      if canonical_uuid?(command_id) and valid_digest?(request_digest) and
           valid_digest?(preflight_digest) and valid_digest?(command_result_digest) and
           is_map(result.preflight) do
        {:ok,
         %{
           command_id: command_id,
           request_digest: request_digest,
           preflight: result.preflight,
           preflight_digest: preflight_digest,
           command_result_digest: command_result_digest
         }}
      else
        {:error, :awx_preflight_result_invalid}
      end
    else
      {:error, :awx_preflight_result_invalid}
    end
  end

  defp normalize_provenance_result(_result), do: {:error, :awx_preflight_result_invalid}

  defp normalize_target_result(:ok), do: :ok
  defp normalize_target_result({:error, _reason}), do: {:error, :awx_preflight_target_drift}
  defp normalize_target_result(_result), do: {:error, :awx_preflight_target_drift}

  defp evidence_expiry(approval_expires_at, verified_at, opts) do
    with {:ok, ttl_seconds} <- evidence_ttl_seconds(opts),
         true <-
           valid_utc_datetime?(approval_expires_at) || {:error, :binding_approval_expiry_required},
         true <- valid_utc_datetime?(verified_at) || {:error, :invalid_preflight_clock} do
      expiry =
        verified_at
        |> DateTime.add(ttl_seconds, :second)
        |> earliest(approval_expires_at)

      if DateTime.after?(expiry, verified_at),
        do: {:ok, expiry},
        else: {:error, :binding_approval_expired}
    else
      false -> {:error, :invalid_preflight_clock}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_preflight_clock}
    end
  end

  defp evidence_attrs(
         result,
         controller_id,
         dispatcher,
         binding,
         reviewed_digest,
         request_digest,
         target_digest,
         security_digest,
         live_result,
         verified_at,
         expires_at
       ) do
    %{
      command_id: result.command_id,
      controller_id: controller_id,
      dispatch_agent_id: dispatcher.agent_id,
      dispatch_partition_id: dispatcher.partition_id,
      binding_id: binding.id,
      binding_version: binding.binding_version,
      approval_id: binding.approval_id,
      reviewed_launch_snapshot_digest: reviewed_digest,
      preflight_request_digest: request_digest,
      target_snapshot_digest: target_digest,
      controller_security_snapshot_digest: security_digest,
      live_launch_snapshot_digest: live_result.preflight_digest,
      command_result_digest: live_result.command_result_digest,
      verified_at: verified_at,
      expires_at: expires_at
    }
  end

  defp record_evidence(attrs, opts) do
    resource = Keyword.get(opts, :evidence_resource, AutomationAwxLaunchPreflightEvidence)
    record_opts = [actor: SystemActor.system(:ansible_live_awx_launch_preflight)]

    result =
      case resource do
        fun when is_function(fun, 2) -> fun.(attrs, record_opts)
        module when is_atom(module) -> apply(module, :record, [attrs, record_opts])
        _ -> {:error, :awx_preflight_evidence_unavailable}
      end

    case result do
      {:ok, evidence} when is_map(evidence) ->
        evidence_id = value(evidence, :id)

        if canonical_uuid?(evidence_id),
          do: {:ok, evidence_id},
          else: {:error, :awx_preflight_evidence_unavailable}

      _ ->
        {:error, :awx_preflight_evidence_unavailable}
    end
  rescue
    UndefinedFunctionError -> {:error, :awx_preflight_evidence_unavailable}
  end

  defp attestation(
         evidence_id,
         command_id,
         controller_id,
         dispatcher,
         binding,
         reviewed_digest,
         request_digest,
         target_digest,
         security_digest,
         live_result,
         verified_at,
         expires_at
       ) do
    %{
      schema: @attestation_schema,
      evidence_id: evidence_id,
      command_id: command_id,
      controller_id: controller_id,
      dispatch_agent_id: dispatcher.agent_id,
      dispatch_partition_id: dispatcher.partition_id,
      binding_id: binding.id,
      binding_version: binding.binding_version,
      approval_id: binding.approval_id,
      reviewed_launch_snapshot_digest: reviewed_digest,
      preflight_request_digest: request_digest,
      target_snapshot_digest: target_digest,
      controller_security_snapshot_digest: security_digest,
      live_launch_snapshot_digest: live_result.preflight_digest,
      command_result_digest: live_result.command_result_digest,
      verified_at: verified_at,
      expires_at: expires_at
    }
  end

  defp now(opts) do
    clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)

    case clock do
      fun when is_function(fun, 0) ->
        case fun.() do
          %DateTime{} = value ->
            if valid_utc_datetime?(value),
              do: {:ok, value},
              else: {:error, :invalid_preflight_clock}

          _ ->
            {:error, :invalid_preflight_clock}
        end

      _ ->
        {:error, :invalid_preflight_clock}
    end
  end

  defp evidence_ttl_seconds(opts) do
    case Keyword.get(opts, :preflight_ttl_seconds, @default_evidence_ttl_seconds) do
      seconds when is_integer(seconds) and seconds in 1..@max_evidence_ttl_seconds ->
        {:ok, seconds}

      _ ->
        {:error, :invalid_preflight_evidence_ttl}
    end
  end

  defp canonical_awx_id(value) when is_integer(value) and value in 1..@max_awx_id,
    do: {:ok, Integer.to_string(value)}

  defp canonical_awx_id(value) when is_binary(value) do
    if Regex.match?(@canonical_positive_id, value) do
      case Integer.parse(value) do
        {parsed, ""} when parsed in 1..@max_awx_id -> {:ok, value}
        _ -> {:error, :invalid_awx_preflight_membership}
      end
    else
      {:error, :invalid_awx_preflight_membership}
    end
  end

  defp canonical_awx_id(_value), do: {:error, :invalid_awx_preflight_membership}

  defp exact_string_keys(map, expected) when is_map(map) do
    if Enum.all?(Map.keys(map), &is_binary/1) and MapSet.new(Map.keys(map)) == expected,
      do: :ok,
      else: {:error, :invalid_controller_security_snapshot}
  end

  defp exact_string_keys(_map, _expected), do: {:error, :invalid_controller_security_snapshot}

  defp approved?(value), do: value in [:approved, "approved"]

  defp canonical_uuid?(value) when is_binary(value) do
    Regex.match?(@uuid, value) and Ecto.UUID.cast(value) == {:ok, value}
  end

  defp canonical_uuid?(_value), do: false

  defp valid_digest?(value) when is_binary(value), do: Regex.match?(@sha256_hex, value)
  defp valid_digest?(_value), do: false

  defp valid_source_fingerprint?(value) when is_binary(value),
    do: Regex.match?(@source_fingerprint, value)

  defp valid_source_fingerprint?(_value), do: false

  defp dispatch_identity?(value) when is_binary(value) do
    byte_size(value) in 1..@max_dispatch_identity_bytes and String.valid?(value) and
      String.trim(value) == value and
      not String.match?(value, @forbidden_text_codepoints)
  end

  defp dispatch_identity?(_value), do: false

  defp bounded_reference?(value) when is_binary(value) do
    byte_size(value) in 1..255 and String.valid?(value) and String.trim(value) == value and
      not String.match?(value, @forbidden_text_codepoints)
  end

  defp bounded_reference?(_value), do: false

  defp valid_utc_datetime?(%DateTime{utc_offset: 0, std_offset: 0}), do: true
  defp valid_utc_datetime?(_value), do: false

  defp earliest(left, right) do
    if DateTime.after?(left, right), do: right, else: left
  end

  defp normalize_keyword_options(options) when is_list(options) do
    if Keyword.keyword?(options), do: options, else: []
  end

  defp normalize_keyword_options(_options), do: []

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key))
    end
  end

  defp value(_map, _key), do: nil
end
