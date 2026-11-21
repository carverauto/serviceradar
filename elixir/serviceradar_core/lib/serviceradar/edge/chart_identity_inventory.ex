defmodule ServiceRadar.Edge.ChartIdentityInventory do
  @moduledoc """
  First adoption of the chart's own NATS client certificates.

  Runs independently of `ServiceRadar.NATS.ManagedCertificateAuthorization` so
  admission does not wait for inventory reads or certificate writes.
  See `docs/managed-component-certificates.md` for configuration, eligibility,
  and coverage.
  """
  use GenServer

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.ComponentCertificate
  alias ServiceRadar.Edge.ComponentCertificateAuthority, as: Authority
  alias ServiceRadar.Edge.InfrastructureCertificateAdoption, as: Adoption
  alias ServiceRadar.Edge.ManagedComponent
  alias ServiceRadar.NATS.StaticIdentityGrants

  require Ash.Query
  require Logger

  @interval_ms 30_000
  @component_type "nats-client"

  @type reason ::
          :no_inventory_certificate
          | :ambiguous_inventory_certificates
          | :untrusted_issuer
          | :certificate_not_valid
          | :no_static_user
          | :recorded_not_authorized
          | :held_unrecorded
          | :legacy_certificates_without_subject
          | {:adoption_failed, term()}

  @type identity :: %{
          optional(:fingerprints) => [String.t()],
          subject: String.t(),
          status: :adopted | :not_adopted,
          fingerprint: String.t() | nil,
          reason: reason() | nil
        }

  @type report :: %{
          identities: [identity()],
          unlisted: [%{file: String.t(), reason: :not_a_chart_identity | :invalid_certificate}],
          legacy_certificates: non_neg_integer()
        }

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Returns the inventory inputs, or nil if any of its three paths is unset or empty."
  def configured do
    with dir when is_binary(dir) and dir != "" <-
           Application.get_env(:serviceradar, :nats_infrastructure_certs_dir),
         identities when is_binary(identities) and identities != "" <-
           Application.get_env(:serviceradar, :nats_chart_identities_file),
         root when is_binary(root) and root != "" <-
           Application.get_env(:serviceradar, :nats_infrastructure_root_file) do
      %{
        certificates_dir: dir,
        identities_file: identities,
        root_file: root,
        static_users_file: Application.get_env(:serviceradar, :nats_static_users_file),
        partition_id:
          Application.get_env(:serviceradar, :nats_chart_identity_partition_id, "default")
      }
    else
      _ -> nil
    end
  end

  @doc """
  Adopts what the rule allows and returns the coverage report.

  An unreadable identities file, static users file or root certificate is an
  error and nothing is written.
  """
  @spec reconcile(map() | nil) :: {:ok, report()} | {:error, term()}
  def reconcile(inputs \\ configured())

  def reconcile(nil), do: {:ok, %{identities: [], unlisted: [], legacy_certificates: 0}}

  def reconcile(%{} = inputs) do
    with {:ok, subjects} <- chart_subjects(inputs.identities_file),
         {:ok, grants} <- static_grants(inputs.static_users_file),
         {:ok, root} <- root_certificate(inputs.root_file),
         {:ok, legacy} <- legacy_certificates() do
      {listed, unlisted} = inventory(inputs.certificates_dir, root, subjects)

      attempts =
        Enum.map(subjects, fn subject ->
          attempt(subject, Map.get(listed, subject, []), grants, legacy, inputs.partition_id)
        end)

      with {:ok, authorized} <- authorized_fingerprints(listed) do
        identities = Enum.map(attempts, &cover(&1, authorized))
        {:ok, %{identities: identities, unlisted: unlisted, legacy_certificates: legacy}}
      end
    end
  end

  @impl true
  def init(_opts) do
    send(self(), :tick)
    {:ok, %{report: nil}}
  end

  @impl true
  def handle_info(:tick, state) do
    state = tick(state)
    Process.send_after(self(), :tick, @interval_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp tick(state) do
    case reconcile() do
      {:ok, report} ->
        log(state.report, report)
        %{state | report: report}

      {:error, reason} ->
        Logger.warning("Chart identity inventory was not reconciled: #{inspect(reason)}")
        state
    end
  rescue
    exception ->
      Logger.warning(
        "Chart identity inventory was not reconciled: #{Exception.message(exception)}"
      )

      state
  catch
    :exit, _reason -> state
  end

  # One line per identity whose state changed, so an unchanged install is quiet.
  defp log(previous, report) do
    before = if previous, do: Map.new(previous.identities, &{&1.subject, &1}), else: %{}

    Enum.each(report.identities, fn identity ->
      if Map.get(before, identity.subject) != identity, do: log_identity(identity)
    end)
  end

  defp log_identity(%{status: :adopted, subject: subject} = identity) do
    fingerprints = Map.get(identity, :fingerprints, [identity.fingerprint])

    Logger.info(
      "Chart identity #{subject} is adopted with certificates #{Enum.join(fingerprints, ", ")}"
    )
  end

  defp log_identity(%{status: :not_adopted, subject: subject, reason: reason}) do
    Logger.warning("Chart identity #{subject} is not adopted: #{inspect(reason)}")
  end

  # --- inputs

  defp chart_subjects(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, subjects} when is_list(subjects) <- YamlElixir.read_from_string(contents),
         {:ok, canonical} <- canonical_subjects(subjects) do
      {:ok, canonical}
    else
      _ -> {:error, :invalid_chart_identities}
    end
  end

  defp canonical_subjects(subjects) do
    Enum.reduce_while(subjects, {:ok, []}, fn subject, {:ok, acc} ->
      with true <- is_binary(subject),
           {:ok, canonical} <- StaticIdentityGrants.configured_subject(subject) do
        {:cont, {:ok, acc ++ [canonical]}}
      else
        _ -> {:halt, :error}
      end
    end)
  end

  defp static_grants(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} -> StaticIdentityGrants.parse(contents)
      {:error, _reason} -> {:error, :invalid_static_users}
    end
  end

  defp static_grants(_path), do: {:error, :invalid_static_users}

  defp root_certificate(path) do
    case read_certificate_file(path) do
      {:ok, %{leaf: root}} -> {:ok, root}
      _ -> {:error, :invalid_root_certificate}
    end
  end

  defp read_certificate_file(path) do
    with {:ok, pem} <- File.read(path),
         {:ok, presented} <- Adoption.read_certificate(%{certificate_pem: pem}) do
      Enum.each([presented.leaf | presented.chain], &:public_key.pkix_decode_cert(&1, :otp))
      {:ok, presented}
    end
  rescue
    _ -> {:error, :invalid_certificate}
  end

  # The inventory's certificates by chart subject, and the files that name no
  # chart identity. A file that is not a certificate is reported, not fatal.
  defp inventory(dir, root, subjects) do
    dir
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
    |> Enum.reduce({%{}, []}, fn path, {listed, unlisted} ->
      case read_inventory_certificate(path, root) do
        {:ok, certificate} ->
          if certificate.subject in subjects do
            {Map.update(listed, certificate.subject, [certificate], &[certificate | &1]),
             unlisted}
          else
            {listed, unlisted ++ [%{file: Path.basename(path), reason: :not_a_chart_identity}]}
          end

        :error ->
          {listed, unlisted ++ [%{file: Path.basename(path), reason: :invalid_certificate}]}
      end
    end)
  end

  defp read_inventory_certificate(path, root) do
    case read_certificate_file(path) do
      {:ok, presented} ->
        path = [presented.leaf | presented.chain]

        {:ok,
         %{
           subject: presented.fields.subject,
           fingerprint: presented.fields.fingerprint,
           leaf: presented.leaf,
           pem:
             :public_key.pem_encode(Enum.map(path ++ [root], &{:Certificate, &1, :not_encrypted})),
           verification: verify_path(root, Enum.reverse(path))
         }}

      _ ->
        :error
    end
  end

  defp verify_path(root, path) do
    case :public_key.pkix_path_validation(root, path, []) do
      {:ok, _} -> :ok
      {:error, {:bad_cert, :cert_expired}} -> {:error, :certificate_not_valid}
      {:error, _reason} -> {:error, :untrusted_issuer}
    end
  rescue
    _ -> {:error, :untrusted_issuer}
  end

  defp attempt(subject, [], _grants, _legacy, _partition_id),
    do: {subject, nil, :no_inventory_certificate}

  defp attempt(subject, certificates, grants, legacy, partition_id) do
    case Enum.uniq(Enum.map(certificates, & &1.fingerprint)) do
      [fingerprint] ->
        certificate = Enum.min_by(certificates, &{&1.verification != :ok, &1.pem})
        {subject, fingerprint, first_adoption(certificate, grants, legacy, partition_id)}

      fingerprints ->
        {subject, Enum.sort(fingerprints), :ambiguous_inventory_certificates}
    end
  end

  defp first_adoption(%{verification: {:error, reason}}, _grants, _legacy, _partition_id),
    do: reason

  defp first_adoption(certificate, grants, legacy, partition_id) do
    grant = StaticIdentityGrants.grant(grants, @component_type, certificate.leaf)

    cond do
      is_nil(grant) ->
        :no_static_user

      recorded?(certificate.fingerprint) ->
        :recorded

      held?(certificate.subject) ->
        :held

      legacy > 0 ->
        :legacy_certificates_without_subject

      true ->
        adopt(certificate, grant, partition_id)
    end
  end

  defp adopt(certificate, grant, partition_id) do
    attrs = %{
      component_id: component_id(certificate.subject),
      component_type: @component_type,
      partition_id: partition_id,
      certificate_pem: certificate.pem,
      permissions: %{
        publish: %{allow: grant.publish, deny: grant.publish_deny},
        subscribe: %{allow: grant.subscribe, deny: grant.subscribe_deny}
      }
    }

    # The authority repeats the held check under the subject's lock, so a
    # certificate recorded for this subject since the check above is not
    # joined by a second one.
    case Authority.adopt_unheld_certificate(attrs, system()) do
      {:ok, _adopted} -> :recorded
      {:error, :subject_held} -> :held
      {:error, reason} -> {:adoption_failed, reason}
    end
  end

  defp cover({subject, nil, reason}, _authorized), do: not_adopted(subject, nil, reason)

  defp cover({subject, fingerprints, :ambiguous_inventory_certificates}, authorized) do
    identity =
      if Enum.all?(fingerprints, &MapSet.member?(authorized, &1)) do
        adopted(subject, nil)
      else
        not_adopted(subject, nil, :ambiguous_inventory_certificates)
      end

    Map.put(identity, :fingerprints, fingerprints)
  end

  defp cover({subject, fingerprint, outcome}, authorized) do
    cond do
      fingerprint in authorized ->
        adopted(subject, fingerprint)

      outcome == :recorded or recorded?(fingerprint) ->
        not_adopted(subject, fingerprint, :recorded_not_authorized)

      outcome == :held or held?(subject) ->
        not_adopted(subject, fingerprint, :held_unrecorded)

      true ->
        not_adopted(subject, fingerprint, outcome)
    end
  end

  defp component_id(subject) do
    digest = :sha256 |> :crypto.hash(subject) |> Base.encode16(case: :lower)
    "chart-identity-" <> binary_part(digest, 0, 32)
  end

  defp adopted(subject, fingerprint),
    do: %{subject: subject, status: :adopted, fingerprint: fingerprint, reason: nil}

  defp not_adopted(subject, fingerprint, reason),
    do: %{subject: subject, status: :not_adopted, fingerprint: fingerprint, reason: reason}

  # --- stored state

  defp system, do: [actor: SystemActor.system(:chart_identity_inventory)]

  defp legacy_certificates do
    types = ManagedComponent.infrastructure_types()

    ComponentCertificate
    |> Ash.Query.filter(is_nil(subject) and component.component_type in ^types)
    |> Ash.count(system())
  end

  defp recorded?(fingerprint) do
    ComponentCertificate
    |> Ash.Query.filter(fingerprint == ^fingerprint)
    |> Ash.exists?(system())
  end

  defp held?(subject) do
    ComponentCertificate
    |> Ash.Query.filter(subject == ^subject)
    |> Ash.exists?(system())
  end

  defp authorized_fingerprints(listed) when map_size(listed) == 0, do: {:ok, MapSet.new()}

  defp authorized_fingerprints(_listed) do
    with {:ok, snapshot} <- Authority.snapshot() do
      {:ok, MapSet.new(snapshot.allowed_fingerprints)}
    end
  end
end
