defmodule ServiceRadar.Automation.Ansible.AutomationResultSanitizer do
  @moduledoc """
  Canonical ingress boundary for AWX command results.

  Agent command results are authenticated transport messages, but their text
  and JSON still originate outside the control plane. Hardened automation must
  never persist raw plugin envelopes, HTTP bodies, arbitrary error strings, or
  malformed bytes before the durable coordinator validates them. This module
  retains only the bounded fields required by the AWX lifecycle. Invalid or
  failed results collapse to a fixed, secret-free failure document.
  """

  alias ServiceRadar.Automation.Ansible.AWXResultProjection
  alias ServiceRadar.Automation.Ansible.Targeting

  @job_statuses ~w(new pending waiting running successful failed error canceled)
  @job_types ~w(run check)
  @credential_kind ~r/\A[a-z][a-z0-9_.-]{0,63}\z/
  @sha256 ~r/\A[0-9a-f]{64}\z/
  @scm_revision ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
  @callback_name ~r/\Asr-callback-[0-9a-f-]{36}\z/
  @max_id 2_147_483_647
  @max_recent_jobs 5_000
  @max_callback_credentials 5_000
  @max_host_summaries 10_000
  @max_projected_payload_bytes 3 * 1024 * 1024
  @summary_counter_keys ~w(changed dark failures ok processed skipped ignored rescued)

  @doc "Returns a canonical result for protected AWX verbs and leaves other commands unchanged."
  @spec sanitize(term()) :: term()
  def sanitize(data) when is_map(data) do
    command_type = value(data, :command_type)

    if protected_command?(command_type) do
      sanitize_protected(data, command_type)
    else
      data
    end
  end

  def sanitize(data), do: data

  @doc "Removes agent-controlled text from protected AWX acknowledgements."
  @spec sanitize_ack(term()) :: term()
  def sanitize_ack(data) when is_map(data) do
    if protected_command?(value(data, :command_type)) do
      data
      |> transport_projection()
      |> Map.put(:message, "automation command acknowledged")
    else
      data
    end
  end

  def sanitize_ack(data), do: data

  @doc "Removes agent-controlled text and payloads from protected AWX progress updates."
  @spec sanitize_progress(term()) :: term()
  def sanitize_progress(data) when is_map(data) do
    if protected_command?(value(data, :command_type)) do
      progress = value(data, :progress_percent)

      data
      |> transport_projection()
      |> Map.put(:message, "automation command in progress")
      |> Map.put(
        :progress_percent,
        if(is_integer(progress) and progress in 0..100, do: progress, else: 0)
      )
      |> Map.put(:payload, %{})
    else
      data
    end
  end

  def sanitize_progress(data), do: data

  @doc false
  @spec protected_command?(term()) :: boolean()
  def protected_command?(command_type) when is_binary(command_type),
    do: String.starts_with?(command_type, "awx.")

  def protected_command?(_command_type), do: false

  defp sanitize_protected(data, command_type) do
    safe_command_type = safe_awx_command_type(command_type)

    base = %{
      command_id: safe_uuid(value(data, :command_id)),
      command_type: safe_command_type,
      agent_id: safe_identifier(value(data, :agent_id)),
      partition_id: safe_identifier(value(data, :partition_id))
    }

    if value(data, :success) == true do
      case sanitize_success_payload(command_type, value(data, :payload)) do
        {:ok, payload} when is_map(payload) ->
          if within_aggregate_budget?(payload) do
            Map.merge(base, %{
              success: true,
              message: "automation command completed",
              failure_reason: nil,
              payload: payload
            })
          else
            failure(base, safe_command_type, "invalid_automation_result")
          end

        :error ->
          failure(base, safe_command_type, "invalid_automation_result")
      end
    else
      failure(base, safe_command_type, "automation_command_failed")
    end
  end

  defp within_aggregate_budget?(payload) do
    case Jason.encode_to_iodata(payload) do
      {:ok, encoded} -> IO.iodata_length(encoded) <= @max_projected_payload_bytes
      {:error, _reason} -> false
    end
  end

  defp failure(base, command_type, code) do
    Map.merge(base, %{
      success: false,
      message: "automation command failed",
      failure_reason: code,
      payload: %{"verb" => command_type, "ok" => false}
    })
  end

  defp transport_projection(data) do
    %{
      command_id: safe_uuid(value(data, :command_id)),
      command_type: safe_awx_command_type(value(data, :command_type)),
      agent_id: safe_identifier(value(data, :agent_id)),
      partition_id: safe_identifier(value(data, :partition_id)),
      gateway_id: safe_identifier(value(data, :gateway_id)),
      gateway_node: safe_identifier(value(data, :gateway_node)),
      timestamp: safe_timestamp(value(data, :timestamp))
    }
  end

  defp sanitize_success_payload("awx.create_callback_credential", payload) do
    with {:ok, credential_id} <- positive_integer(value(payload, :credential_id)),
         {:ok, credential_type_id} <- positive_integer(value(payload, :credential_type_id)),
         {:ok, organization_id} <- positive_integer(value(payload, :organization_id)),
         {:ok, credential_name} <- callback_name(value(payload, :credential_name)),
         {:ok, injector_sha256} <- digest(value(payload, :injector_sha256)) do
      exact_payload(
        payload,
        ~w(verb ok credential_id credential_type_id organization_id credential_name injector_sha256),
        %{
          "verb" => "awx.create_callback_credential",
          "ok" => true,
          "credential_id" => credential_id,
          "credential_type_id" => credential_type_id,
          "organization_id" => organization_id,
          "credential_name" => credential_name,
          "injector_sha256" => injector_sha256
        }
      )
    else
      _ -> :error
    end
  end

  defp sanitize_success_payload("awx.fetch_callback_credential", payload) do
    with {:ok, found?} <- boolean(value(payload, :found)),
         {:ok, credential_type_id} <- positive_integer(value(payload, :credential_type_id)),
         {:ok, organization_id} <- positive_integer(value(payload, :organization_id)),
         {:ok, credential_name} <- callback_name(value(payload, :credential_name)),
         {:ok, credential_id} <- optional_found_id(found?, value(payload, :credential_id)) do
      keys =
        if found?,
          do: ~w(verb ok found credential_id credential_type_id organization_id credential_name),
          else: ~w(verb ok found credential_type_id organization_id credential_name)

      safe = %{
        "verb" => "awx.fetch_callback_credential",
        "ok" => true,
        "found" => found?,
        "credential_type_id" => credential_type_id,
        "organization_id" => organization_id,
        "credential_name" => credential_name
      }

      exact_payload(payload, keys, maybe_put(safe, "credential_id", credential_id))
    else
      _ -> :error
    end
  end

  defp sanitize_success_payload("awx.verify_callback_credential", payload) do
    with {:ok, credential_id} <- positive_integer(value(payload, :credential_id)),
         {:ok, credential} <- callback_credential(value(payload, :credential)),
         true <- credential["id"] == credential_id do
      exact_payload(payload, ~w(verb ok credential_id credential), %{
        "verb" => "awx.verify_callback_credential",
        "ok" => true,
        "credential_id" => credential_id,
        "credential" => credential
      })
    else
      _ -> :error
    end
  end

  defp sanitize_success_payload("awx.list_callback_credentials", payload) do
    with {:ok, credential_type_id} <- positive_integer(value(payload, :credential_type_id)),
         {:ok, organization_id} <- positive_integer(value(payload, :organization_id)),
         {:ok, credential_name} <- callback_name(value(payload, :credential_name)),
         {:ok, max_credentials} <-
           bounded_integer(value(payload, :max_credentials), 1, @max_callback_credentials),
         true <- max_credentials == @max_callback_credentials,
         {:ok, count} <- bounded_integer(value(payload, :count), 0, max_credentials),
         {:ok, true} <- boolean(value(payload, :complete)),
         {:ok, credentials} <-
           callback_credentials(value(payload, :credentials), max_credentials),
         true <- count == length(credentials),
         true <-
           Enum.all?(credentials, fn credential ->
             credential["credential_type_id"] == credential_type_id and
               credential["organization_id"] == organization_id and
               credential["name"] == credential_name
           end) do
      exact_payload(
        payload,
        ~w(
          verb ok credential_type_id organization_id credential_name max_credentials
          count complete credentials
        ),
        %{
          "verb" => "awx.list_callback_credentials",
          "ok" => true,
          "credential_type_id" => credential_type_id,
          "organization_id" => organization_id,
          "credential_name" => credential_name,
          "max_credentials" => max_credentials,
          "count" => count,
          "complete" => true,
          "credentials" => credentials
        }
      )
    else
      _ -> :error
    end
  end

  defp sanitize_success_payload("awx.launch_job", payload) do
    with {:ok, template_id} <- positive_integer(value(payload, :template_id)),
         {:ok, job} <- job(value(payload, :job)) do
      exact_payload(payload, ~w(verb ok template_id job), %{
        "verb" => "awx.launch_job",
        "ok" => true,
        "template_id" => template_id,
        "job" => job
      })
    else
      _ -> :error
    end
  end

  defp sanitize_success_payload("awx.fetch_job", payload) do
    with {:ok, job_id} <- positive_integer(value(payload, :job_id)),
         {:ok, job} <- job(value(payload, :job)) do
      exact_payload(payload, ~w(verb ok job_id job), %{
        "verb" => "awx.fetch_job",
        "ok" => true,
        "job_id" => job_id,
        "job" => job
      })
    else
      _ -> :error
    end
  end

  defp sanitize_success_payload("awx.list_recent_jobs", payload) do
    with {:ok, template_id} <- positive_integer(value(payload, :template_id)),
         {:ok, inventory_id} <- positive_integer(value(payload, :inventory_id)),
         {:ok, created_by_id} <- positive_integer(value(payload, :created_by_id)),
         {:ok, created_after} <- timestamp(value(payload, :created_after)),
         {:ok, page_size} <- bounded_integer(value(payload, :page_size), 1, 100),
         {:ok, max_candidates} <-
           bounded_integer(value(payload, :max_candidates), 1, @max_recent_jobs),
         true <- max_candidates == @max_recent_jobs,
         {:ok, count} <- bounded_integer(value(payload, :count), 0, max_candidates),
         {:ok, true} <- boolean(value(payload, :complete)),
         {:ok, jobs} <- job_list(value(payload, :jobs), max_candidates),
         true <- count == length(jobs) do
      exact_payload(
        payload,
        ~w(
          verb ok template_id inventory_id created_by_id created_after page_size
          max_candidates count complete jobs
        ),
        %{
          "verb" => "awx.list_recent_jobs",
          "ok" => true,
          "template_id" => template_id,
          "inventory_id" => inventory_id,
          "created_by_id" => created_by_id,
          "created_after" => created_after,
          "page_size" => page_size,
          "max_candidates" => max_candidates,
          "count" => count,
          "complete" => true,
          "jobs" => jobs
        }
      )
    else
      _ -> :error
    end
  end

  defp sanitize_success_payload("awx.fetch_job_host_summaries", payload) do
    with {:ok, job_id} <- positive_integer(value(payload, :job_id)),
         {:ok, count} <- bounded_integer(value(payload, :count), 0, @max_host_summaries),
         {:ok, summaries} <- summary_list(value(payload, :summaries)),
         true <- count == length(summaries) do
      exact_payload(payload, ~w(verb ok job_id count summaries), %{
        "verb" => "awx.fetch_job_host_summaries",
        "ok" => true,
        "job_id" => job_id,
        "count" => count,
        "summaries" => summaries
      })
    else
      _ -> :error
    end
  end

  defp sanitize_success_payload("awx.delete_callback_credential", payload) do
    with {:ok, credential_id} <- positive_integer(value(payload, :credential_id)),
         {:ok, credential_type_id} <- positive_integer(value(payload, :credential_type_id)),
         cleanup_status when cleanup_status in ["deleted", "already_absent"] <-
           value(payload, :cleanup_status) do
      exact_payload(payload, ~w(verb ok credential_id credential_type_id cleanup_status), %{
        "verb" => "awx.delete_callback_credential",
        "ok" => true,
        "credential_id" => credential_id,
        "credential_type_id" => credential_type_id,
        "cleanup_status" => cleanup_status
      })
    else
      _ -> :error
    end
  end

  defp sanitize_success_payload("awx.cancel_job", payload) do
    with {:ok, job_id} <- positive_integer(value(payload, :job_id)),
         {:ok, status} <- bounded_integer(value(payload, :status), 200, 299) do
      exact_payload(payload, ~w(verb ok job_id status), %{
        "verb" => "awx.cancel_job",
        "ok" => true,
        "job_id" => job_id,
        "status" => status
      })
    else
      _ -> :error
    end
  end

  defp sanitize_success_payload(command_type, payload),
    do: AWXResultProjection.project(command_type, payload)

  defp job(payload) when is_map(payload) do
    with {:ok, id} <- positive_integer(value(payload, :id) || value(payload, :job)),
         {:ok, status} <- enum(value(payload, :status), @job_statuses),
         {:ok, created} <- timestamp(value(payload, :created)),
         {:ok, job_template} <- positive_integer(value(payload, :job_template)),
         {:ok, inventory} <- positive_integer(value(payload, :inventory)),
         {:ok, project} <- positive_integer(value(payload, :project)),
         {:ok, scm_revision} <- revision(value(payload, :scm_revision)),
         {:ok, execution_environment} <- positive_integer(value(payload, :execution_environment)),
         {:ok, job_type} <- enum(value(payload, :job_type), @job_types),
         {:ok, slice_count} <- bounded_integer(value(payload, :job_slice_count), 1, @max_id),
         {:ok, slice_number} <-
           bounded_integer(value(payload, :job_slice_number) || 0, 0, @max_id),
         {:ok, limit} <- host_limit(value(payload, :limit)),
         {:ok, launched_by} <- launched_by(value(payload, :launched_by)),
         {:ok, credentials} <- credentials(value(payload, :credentials)),
         {:ok, markers} <- dispatch_markers(value(payload, :dispatch_markers)) do
      {:ok,
       %{
         "id" => id,
         "status" => status,
         "created" => created,
         "job_template" => job_template,
         "inventory" => inventory,
         "project" => project,
         "scm_revision" => scm_revision,
         "execution_environment" => execution_environment,
         "job_type" => job_type,
         "job_slice_count" => slice_count,
         "job_slice_number" => slice_number,
         "limit" => limit,
         "launched_by" => launched_by,
         "credentials" => credentials,
         "dispatch_markers" => markers
       }}
    else
      _ -> :error
    end
  end

  defp job(_payload), do: :error

  defp job_list(jobs, max) when is_list(jobs) and length(jobs) <= max do
    reduce_list(jobs, &job/1)
  end

  defp job_list(_jobs, _max), do: :error

  defp callback_credentials(credentials, max)
       when is_list(credentials) and length(credentials) <= max do
    case reduce_list(credentials, &callback_credential/1) do
      {:ok, safe} ->
        ids = Enum.map(safe, & &1["id"])

        if ids == Enum.sort(ids) and ids == Enum.uniq(ids),
          do: {:ok, safe},
          else: :error

      :error ->
        :error
    end
  end

  defp callback_credentials(_credentials, _max), do: :error

  defp callback_credential(payload) when is_map(payload) do
    with {:ok, id} <- positive_integer(value(payload, :id)),
         {:ok, name} <- callback_name(value(payload, :name)),
         {:ok, credential_type_id} <- positive_integer(value(payload, :credential_type_id)),
         {:ok, organization_id} <- positive_integer(value(payload, :organization_id)) do
      exact_projection(payload, ~w(id name credential_type_id organization_id), %{
        "id" => id,
        "name" => name,
        "credential_type_id" => credential_type_id,
        "organization_id" => organization_id
      })
    else
      _ -> :error
    end
  end

  defp callback_credential(_payload), do: :error

  defp summary_list(summaries)
       when is_list(summaries) and length(summaries) <= @max_host_summaries do
    reduce_list(summaries, &summary/1)
  end

  defp summary_list(_summaries), do: :error

  defp summary(payload) when is_map(payload) do
    with {:ok, summary_id} <- positive_integer(value(payload, :summary_id)),
         {:ok, job_id} <- positive_integer(value(payload, :job_id)),
         {:ok, host_id} <- optional_positive_integer(value(payload, :host_id)),
         {:ok, constructed_host_id} <-
           optional_positive_integer(value(payload, :constructed_host_id)),
         true <- is_integer(host_id) or is_integer(constructed_host_id),
         {:ok, host_name} <- host_token(value(payload, :host_name)),
         {:ok, failed?} <- boolean(value(payload, :failed)),
         {:ok, counters} <- summary_counters(payload) do
      safe = %{
        "summary_id" => summary_id,
        "job_id" => job_id,
        "host_name" => host_name,
        "failed" => failed?
      }

      {:ok,
       counters
       |> Map.merge(safe)
       |> maybe_put("host_id", host_id)
       |> maybe_put("constructed_host_id", constructed_host_id)}
    else
      _ -> :error
    end
  end

  defp summary(_payload), do: :error

  defp summary_counters(payload) do
    Enum.reduce_while(@summary_counter_keys, {:ok, %{}}, fn key, {:ok, acc} ->
      case bounded_integer(value(payload, key), 0, @max_id) do
        {:ok, counter} -> {:cont, {:ok, Map.put(acc, key, counter)}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp credentials(values) when is_list(values) and length(values) in 1..128 do
    values
    |> reduce_list(fn credential ->
      with {:ok, id} <- positive_integer(value(credential, :id)),
           kind when is_binary(kind) <- value(credential, :kind),
           true <- Regex.match?(@credential_kind, kind) do
        {:ok, %{"id" => id, "kind" => kind}}
      else
        _ -> :error
      end
    end)
    |> case do
      {:ok, credentials} ->
        ids = Enum.map(credentials, & &1["id"])
        if length(ids) == MapSet.size(MapSet.new(ids)), do: {:ok, credentials}, else: :error

      :error ->
        :error
    end
  end

  defp credentials(_values), do: :error

  defp launched_by(payload) when is_map(payload) do
    case positive_integer(value(payload, :id)) do
      {:ok, id} -> {:ok, %{"id" => id}}
      :error -> :error
    end
  end

  defp launched_by(_payload), do: :error

  # Launch responses may omit dispatch markers when AWX ignores request
  # extra_vars (template ask_variables_on_launch disabled). Markers remain
  # required when present so forged partial marker maps cannot pass.
  defp dispatch_markers(nil), do: {:ok, %{}}
  defp dispatch_markers(payload) when is_map(payload) and map_size(payload) == 0, do: {:ok, %{}}

  defp dispatch_markers(payload) when is_map(payload) do
    with {:ok, dispatch_id} <- uuid(value(payload, :serviceradar_dispatch_id)),
         {:ok, snapshot_digest} <- digest(value(payload, :serviceradar_snapshot_digest)) do
      {:ok,
       %{
         "serviceradar_dispatch_id" => dispatch_id,
         "serviceradar_snapshot_digest" => snapshot_digest
       }}
    else
      _ -> :error
    end
  end

  defp dispatch_markers(_payload), do: :error

  defp host_limit(value) when is_binary(value) do
    tokens = String.split(value, ",", trim: false)

    if tokens != [] and length(tokens) <= @max_host_summaries and
         Enum.all?(tokens, &match?({:ok, _}, host_token(&1))) and Enum.join(tokens, ",") == value,
       do: {:ok, value},
       else: :error
  end

  defp host_limit(_value), do: :error

  defp host_token(value) do
    if Targeting.literal_host_token?(value), do: {:ok, value}, else: :error
  end

  defp callback_name(value) when is_binary(value) do
    if Regex.match?(@callback_name, value) and
         match?({:ok, _}, uuid(String.replace_prefix(value, "sr-callback-", ""))),
       do: {:ok, value},
       else: :error
  end

  defp callback_name(_value), do: :error

  # Pending/new launches often report an empty scm_revision before the project
  # checkout is recorded. Accept empty/absent; non-empty values must still be
  # exact 40- or 64-char hex revisions.
  defp revision(nil), do: {:ok, ""}
  defp revision(""), do: {:ok, ""}

  defp revision(value) when is_binary(value),
    do: if(Regex.match?(@scm_revision, value), do: {:ok, value}, else: :error)

  defp revision(_value), do: :error

  defp digest(value) when is_binary(value),
    do: if(Regex.match?(@sha256, value), do: {:ok, value}, else: :error)

  defp digest(_value), do: :error

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, 0} -> {:ok, value}
      _ -> :error
    end
  end

  defp timestamp(_value), do: :error

  defp uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, normalized} when normalized == value -> {:ok, normalized}
      _ -> :error
    end
  end

  defp uuid(_value), do: :error

  defp safe_uuid(value) do
    case uuid(value) do
      {:ok, normalized} -> normalized
      :error -> nil
    end
  end

  defp safe_identifier(nil), do: nil

  defp safe_identifier(value) when is_atom(value),
    do: value |> Atom.to_string() |> safe_identifier()

  defp safe_identifier(value) when is_binary(value) do
    if byte_size(value) in 1..255 and
         Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:-]*\z/, value),
       do: value
  end

  defp safe_identifier(_value), do: nil

  defp safe_timestamp(value) when is_integer(value) and value >= 0, do: value
  defp safe_timestamp(%DateTime{} = value), do: value
  defp safe_timestamp(_value), do: nil

  defp safe_awx_command_type(command_type) when is_binary(command_type) do
    if byte_size(command_type) <= 132 and
         Regex.match?(~r/\Aawx\.[a-z][a-z0-9_.-]*\z/, command_type),
       do: command_type,
       else: "awx.invalid"
  end

  defp safe_awx_command_type(_command_type), do: "awx.invalid"

  defp optional_found_id(true, value), do: positive_integer(value)
  defp optional_found_id(false, nil), do: {:ok, nil}
  defp optional_found_id(false, _value), do: :error

  defp optional_positive_integer(nil), do: {:ok, nil}
  defp optional_positive_integer(value), do: positive_integer(value)

  defp positive_integer(value), do: bounded_integer(value, 1, @max_id)

  defp bounded_integer(value, min, max) when is_integer(value) and value >= min and value <= max,
    do: {:ok, value}

  defp bounded_integer(_value, _min, _max), do: :error

  defp boolean(value) when is_boolean(value), do: {:ok, value}
  defp boolean(_value), do: :error

  defp enum(value, allowed) when is_binary(value),
    do: if(value in allowed, do: {:ok, value}, else: :error)

  defp enum(_value, _allowed), do: :error

  defp exact_payload(raw, expected_keys, safe) when is_map(raw) do
    with {:ok, keys} <- normalized_keys(raw),
         true <- length(keys) == MapSet.size(MapSet.new(keys)),
         true <- MapSet.new(keys) == MapSet.new(expected_keys),
         true <- value(raw, :verb) == safe["verb"],
         true <- value(raw, :ok) == true do
      {:ok, safe}
    else
      _ -> :error
    end
  end

  defp exact_payload(_raw, _expected_keys, _safe), do: :error

  defp exact_projection(raw, expected_keys, safe) when is_map(raw) do
    with {:ok, keys} <- normalized_keys(raw),
         true <- length(keys) == MapSet.size(MapSet.new(keys)),
         true <- MapSet.new(keys) == MapSet.new(expected_keys) do
      {:ok, safe}
    else
      _ -> :error
    end
  end

  defp exact_projection(_raw, _expected_keys, _safe), do: :error

  defp reduce_list(values, function) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case function.(value) do
        {:ok, safe} -> {:cont, {:ok, [safe | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, safe} -> {:ok, Enum.reverse(safe)}
      :error -> :error
    end
  end

  defp normalized_keys(map) do
    map
    |> Map.keys()
    |> Enum.reduce_while({:ok, []}, fn
      key, {:ok, acc} when is_binary(key) ->
        {:cont, {:ok, [key | acc]}}

      key, {:ok, acc} when is_atom(key) ->
        {:cont, {:ok, [Atom.to_string(key) | acc]}}

      _key, _acc ->
        {:halt, :error}
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key))
    end
  end

  defp value(_map, _key), do: nil
end
