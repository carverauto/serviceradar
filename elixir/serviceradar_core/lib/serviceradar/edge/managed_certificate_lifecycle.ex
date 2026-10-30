defmodule ServiceRadar.Edge.ManagedCertificateLifecycle do
  @moduledoc """
  Durable managed-service certificate rotation over the authenticated command bus.

  Agent receipts prove installation/activation only. A receiver must independently
  observe a successor before its predecessor may be retired. Issuance happens
  outside database locks; recording it rechecks the component generation and block.
  """
  alias Ash.Error.Query.InvalidArgument
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.AgentCommand
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Edge.ComponentCertificate
  alias ServiceRadar.Edge.ComponentCertificateAuthority, as: Authority
  alias ServiceRadar.Edge.ManagedCertificateOperation, as: Operation
  alias ServiceRadar.Edge.ManagedComponent
  alias ServiceRadar.Edge.ManagedComponentCertificateIssuer, as: Issuer

  require Ash.Query

  @active [:preparing, :issuing, :installing]
  @prepare "certificates.prepare"
  @install "certificates.install"

  def rotate(component_id, opts \\ []) do
    actor = opts[:actor] || (opts[:scope] && opts[:scope].user)

    fn ->
      with {:ok, component} <- component(component_id, opts, :for_update),
           :ok <- available(component),
           {:ok, current} <- current(component_id, system()) do
        if current && current.generation == component.generation && current.status in @active do
          {:ok, current}
        else
          with :ok <- supersede(current) do
            Operation
            |> Ash.Changeset.for_create(
              :begin,
              %{
                component_id: component_id,
                generation: component.generation,
                host_agent_id: component.host_agent_id,
                partition_id: component.partition_id,
                service: component.component_type,
                server_hosts: component.server_hosts,
                requested_by: actor.id
              },
              system()
            )
            |> Ash.create(system())
          end
        end
      end
    end
    |> transaction()
    |> schedule_operation()
  end

  defp schedule_operation({:ok, operation} = result) do
    _ = ServiceRadar.Edge.ManagedCertificateLifecycleWorker.enqueue(operation.id)
    result
  end

  defp schedule_operation(error), do: error

  def current(component_id, opts \\ []) do
    Operation
    |> Ash.Query.filter(component_id == ^component_id and status != :superseded)
    |> Ash.read_one(opts)
  end

  def component(id, opts \\ [], lock \\ nil) do
    query = Ash.Query.filter(ManagedComponent, component_id == ^id)
    query = if lock, do: Ash.Query.lock(query, lock), else: query

    case Ash.read_one(query, opts) do
      {:ok, %ManagedComponent{} = record} -> {:ok, record}
      {:ok, nil} -> {:error, :not_found}
      error -> error
    end
  end

  @doc "Records independently observed receiver use; all successor roles must be observed before retirement."
  def confirm_use(fingerprint, receiver_id, opts)
      when is_binary(receiver_id) and byte_size(receiver_id) in 1..256 do
    if SystemActor.system_actor?(opts[:actor]) do
      with {:ok, %ComponentCertificate{} = certificate} <-
             Ash.get(ComponentCertificate, fingerprint, opts),
           {:ok, %Operation{} = operation} <- current(certificate.component_id, opts) do
        transaction(fn ->
          with {:ok, current} <- locked_current(operation),
               true <- current.status == :activated,
               {role, ^fingerprint} <-
                 Enum.find(current.fingerprints, fn {_role, value} -> value == fingerprint end),
               {:ok, observed} <- observe_role(current, role, receiver_id),
               :ok <- retire_observed_predecessors(observed, opts) do
            {:ok, observed}
          else
            false -> {:error, :activation_unconfirmed}
            nil -> {:error, :successor_not_current}
            error -> error
          end
        end)
      else
        {:ok, nil} -> {:error, :not_found}
        error -> error
      end
    else
      {:error, :forbidden}
    end
  end

  def confirm_use(_, _, _), do: {:error, :invalid_receiver}

  defp observe_role(operation, role, receiver) do
    if Map.has_key?(operation.observed_roles, role),
      do: {:ok, operation},
      else:
        update(operation, %{
          observed_roles:
            Map.put(operation.observed_roles, role, %{
              receiver_id: receiver,
              observed_at: DateTime.to_iso8601(DateTime.utc_now())
            })
        })
  end

  defp successors_authorized(operation, opts) do
    fingerprints = Map.values(operation.fingerprints)

    with {:ok, certificates} <-
           ComponentCertificate
           |> Ash.Query.filter(fingerprint in ^fingerprints)
           |> Ash.read(opts),
         {:ok, revocations} <-
           ServiceRadar.Edge.RevokedComponentCertificate
           |> Ash.Query.filter(
             component_id == ^operation.component_id and generation == ^operation.generation
           )
           |> Ash.read(opts) do
      now = DateTime.utc_now()

      policy = %{
        version: 1,
        generated_at: now,
        valid_until: DateTime.shift(now, second: 30),
        components: [
          %{
            component_id: operation.component_id,
            generation: operation.generation,
            blocked: false
          }
        ],
        certificates: certificates,
        revocations: revocations
      }

      if Enum.all?(
           fingerprints,
           &(Authority.authorize(policy, operation.component_id, &1, now) == :ok)
         ),
         do: :ok,
         else: {:error, :successor_not_authorized}
    end
  end

  defp retire_observed_predecessors(operation, opts) do
    if Enum.all?(Map.keys(operation.fingerprints), &Map.has_key?(operation.observed_roles, &1)) do
      successors = Map.values(operation.fingerprints)

      with :ok <- successors_authorized(operation, opts),
           {:ok, predecessors} <-
             ComponentCertificate
             |> Ash.Query.filter(
               component_id == ^operation.component_id and generation == ^operation.generation and
                 fingerprint not in ^successors
             )
             |> Ash.read(opts) do
        Enum.reduce_while(predecessors, :ok, fn certificate, :ok ->
          case Authority.revoke_certificate(certificate.fingerprint, "successor-observed", opts) do
            {:ok, _} -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)
      end
    else
      :ok
    end
  end

  def reconcile(operation_id) do
    with {:ok, %Operation{} = operation} <- Ash.get(Operation, operation_id, system()),
         {:ok, component} <- component(operation.component_id, system()) do
      if component.blocked || component.generation != operation.generation do
        supersede(operation)
      else
        advance(operation)
      end
    end
  end

  defp advance(%{status: :preparing} = operation) do
    payload = %{
      request_id: operation.id,
      component_id: operation.component_id,
      host_agent_id: operation.host_agent_id,
      partition_id: operation.partition_id,
      generation: operation.generation,
      service: operation.service,
      server_hosts: operation.server_hosts
    }

    with {:ok, command} <- ensure_command(operation, operation.id, @prepare, payload) do
      case command.status do
        :completed ->
          case validate_preparation(operation, command.result_payload) do
            {:ok, csrs} ->
              transition(operation, %{status: :issuing, csrs: csrs})

            {:error, _} ->
              transition(operation, %{status: :failed, error: "invalid_prepare_receipt"})
          end

        :failed ->
          transition(operation, %{status: :failed, error: "prepare_failed"})

        :canceled ->
          transition(operation, %{status: :failed, error: "command_canceled"})

        _ ->
          deliver_or_wait(command)
      end
    end
  end

  defp advance(%{status: :issuing} = operation) do
    case Issuer.issue(operation) do
      {:ok, bundles} ->
        record_issued(operation, bundles)

      {:error, reason} when reason in [:gateway_unavailable, :ca_not_available] ->
        {:snooze, 30}

      {:error, {:agent_offline, _}} ->
        {:snooze, 30}

      {:error, _} ->
        transition(operation, %{status: :failed, error: "certificate_issuance_failed"})
    end
  end

  defp advance(%{status: :installing} = operation) do
    payload = %{
      request_id: operation.id,
      generation: operation.generation,
      certificates: operation.certificates
    }

    with {:ok, command} <-
           ensure_command(operation, operation.install_command_id, @install, payload) do
      if command.status in [:completed, :failed] do
        case validate_installation(operation, command.result_payload) do
          {:ok, receipt, renew_after} ->
            activated =
              command.status == :completed && receipt["installed"] == true &&
                receipt["activated"] == true &&
                receipt["rolled_back"] == false

            transition(operation, %{
              status: if(activated, do: :activated, else: :failed),
              receipt: receipt,
              renew_after: renew_after,
              error: if(activated, do: nil, else: "activation_failed")
            })

          {:error, _} ->
            transition(operation, %{status: :failed, error: "invalid_install_receipt"})
        end
      else
        if command.status == :canceled,
          do: transition(operation, %{status: :failed, error: "command_canceled"}),
          else: deliver_or_wait(command)
      end
    end
  end

  defp advance(%{status: :activated, renew_after: %DateTime{} = at} = operation) do
    if DateTime.before?(DateTime.utc_now(), at),
      do: :ok,
      else: rotate(operation.component_id, system())
  end

  defp advance(_), do: :ok

  defp validate_preparation(operation, %{
         "request_id" => id,
         "generation" => generation,
         "csrs" => csrs
       })
       when is_map(csrs) and id == operation.id and generation == operation.generation do
    roles = Issuer.roles(operation.service)

    valid =
      Enum.sort(Map.keys(csrs)) == roles &&
        Enum.all?(csrs, fn
          {_role, %{"csr_der" => encoded} = entry}
          when map_size(entry) == 1 and is_binary(encoded) ->
            case Base.decode64(encoded) do
              {:ok, der} -> byte_size(der) in 1..65_536
              _ -> false
            end

          _ ->
            false
        end)

    # A host cannot postpone renewal beyond the authority's trusted deadline.
    if valid, do: {:ok, csrs}, else: {:error, :invalid_preparation}
  end

  defp validate_preparation(_, _), do: {:error, :invalid_preparation}

  defp validate_installation(
         operation,
         %{
           "request_id" => id,
           "generation" => generation,
           "fingerprints" => fps,
           "installed" => installed,
           "activated" => activated,
           "rolled_back" => rolled_back,
           "renew_after" => renew
         } = receipt
       )
       when id == operation.id and generation == operation.generation and is_boolean(installed) and
              is_boolean(activated) and
              is_boolean(rolled_back) and is_binary(renew) do
    with true <- fps == operation.fingerprints,
         {:ok, requested, 0} <- DateTime.from_iso8601(renew),
         true <- DateTime.after?(requested, DateTime.utc_now()) do
      deadline =
        if DateTime.before?(requested, operation.renew_after),
          do: requested,
          else: operation.renew_after

      {:ok,
       Map.take(
         receipt,
         ~w(request_id generation installed activated rolled_back fingerprints renew_after policy_path)
       ), deadline}
    else
      _ -> {:error, :invalid_installation}
    end
  end

  defp validate_installation(_, _), do: {:error, :invalid_installation}

  defp record_issued(operation, bundles) do
    transaction(fn ->
      with {:ok, current} <- locked_current(operation),
           true <- current.status == :issuing,
           {:ok, records} <- record_roles(current, bundles) do
        certificates =
          Map.new(bundles, fn {role, bundle} ->
            {role, Map.take(bundle, [:certificate_pem, :ca_chain_pem])}
          end)

        fingerprints = Map.new(records, fn {role, record} -> {role, record.fingerprint} end)

        renew_after =
          records
          |> Enum.map(fn {_role, cert} ->
            DateTime.shift(cert.not_before,
              second: div(DateTime.diff(cert.not_after, cert.not_before) * 2, 3)
            )
          end)
          |> Enum.min(DateTime)

        update(current, %{
          status: :installing,
          certificates: certificates,
          fingerprints: fingerprints,
          renew_after: renew_after
        })
      else
        false -> {:ok, operation}
        error -> error
      end
    end)
  end

  defp record_roles(operation, bundles) do
    Enum.reduce_while(bundles, {:ok, %{}}, fn {role, bundle}, {:ok, records} ->
      metadata = %{
        fingerprint: bundle.certificate_fingerprint,
        issuer_fingerprint: bundle.issuer_fingerprint,
        serial_number: bundle.serial_number,
        not_before: bundle.not_before,
        not_after: bundle.not_after,
        role: role,
        host_agent_id: operation.host_agent_id,
        expected_generation: operation.generation
      }

      case Authority.record_issuance(operation.component_id, metadata, system()) do
        {:ok, record} -> {:cont, {:ok, Map.put(records, role, record)}}
        error -> {:halt, error}
      end
    end)
  end

  defp ensure_command(operation, id, type, payload) do
    transaction(fn ->
      with {:ok, current} <- locked_current(operation),
           true <- current.status == operation.status,
           {:ok, existing} <- Ash.get(AgentCommand, id, system()) do
        if existing do
          if existing.agent_id == operation.host_agent_id &&
               existing.partition_id == operation.partition_id &&
               existing.command_type == type,
             do: {:ok, existing},
             else: {:error, :command_binding_mismatch}
        else
          AgentCommand.create_command_with_id(
            %{
              command_id: id,
              command_type: type,
              agent_id: operation.host_agent_id,
              partition_id: operation.partition_id,
              payload: payload,
              context: %{
                managed_component_id: operation.component_id,
                certificate_operation_id: operation.id
              },
              ttl_seconds: 120,
              requested_by: operation.requested_by
            },
            system()
          )
        end
      else
        false -> {:error, :operation_superseded}
        error -> error
      end
    end)
  end

  defp deliver_or_wait(command) do
    if command.status in [:queued, :offline, :expired] ||
         DateTime.compare(DateTime.utc_now(), command.expires_at) != :lt do
      case AgentCommandBus.dispatch_certificate_command(command.id, system()) do
        {:ok, _} -> {:snooze, 5}
        {:error, _} -> {:snooze, 30}
      end
    else
      {:snooze, 5}
    end
  end

  defp transition(operation, attrs) do
    transaction(fn ->
      with {:ok, current} <- locked_current(operation) do
        if current.status == operation.status, do: update(current, attrs), else: {:ok, current}
      end
    end)
  end

  defp locked_current(operation) do
    with {:ok, component} <- component(operation.component_id, system(), :for_update),
         :ok <- available(component),
         true <- component.generation == operation.generation,
         {:ok, %Operation{} = current} <-
           Operation
           |> Ash.Query.filter(id == ^operation.id)
           |> Ash.Query.lock(:for_update)
           |> Ash.read_one(system()),
         true <- current.status != :superseded do
      {:ok, current}
    else
      false -> {:error, :operation_superseded}
      error -> error
    end
  end

  defp available(%{blocked: false, host_agent_id: host, component_type: type})
       when is_binary(host) do
    if Issuer.roles(type) == [], do: {:error, :unsupported_managed_service}, else: :ok
  end

  defp available(_), do: {:error, :component_unavailable}
  defp supersede(nil), do: :ok

  defp supersede(operation) do
    case operation
         |> Ash.Changeset.for_update(:supersede, %{}, system())
         |> Ash.update(system()) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp update(operation, attrs),
    do: operation |> Ash.Changeset.for_update(:progress, attrs, system()) |> Ash.update(system())

  defp system, do: [actor: SystemActor.system(:managed_certificate_lifecycle)]

  defp transaction(fun) do
    [ManagedComponent, Operation, AgentCommand]
    |> Ash.transact(fn ->
      case fun.() do
        {:error, reason} when is_atom(reason) ->
          {:error,
           InvalidArgument.exception(
             field: :certificate_lifecycle,
             value: reason,
             message: "certificate lifecycle refused"
           )}

        result ->
          result
      end
    end)
    |> case do
      {:ok, result} ->
        result

      {:error, %InvalidArgument{field: :certificate_lifecycle, value: reason}} ->
        {:error, reason}

      {:error,
       %Ash.Error.Invalid{
         errors: [%InvalidArgument{field: :certificate_lifecycle, value: reason}]
       }} ->
        {:error, reason}

      error ->
        error
    end
  end
end
