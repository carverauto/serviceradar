defmodule ServiceRadar.NATS.HubReadiness do
  @moduledoc """
  Hub certificate-authorization readiness reported by core.

  Combines the chart-rendered enforcement and leafnodes listener settings with
  the live authorizer status, mounted signing seed status, chart identity
  coverage, and any rotation refusal reasons. Web-ng augments this map with
  `leaf_upstream_url` (which only web-ng receives) when serving the bootstrap
  and control-plane readiness routes.
  """

  alias ServiceRadar.Edge.ChartIdentityInventory
  alias ServiceRadar.Edge.RuntimeCertificateRotation
  alias ServiceRadar.NATS.ManagedCertificateAuthorization, as: Authorization
  alias ServiceRadar.NATS.ManagedCertificateConfiguration, as: Configuration

  @type identity_warning :: %{
          required(:subject) => String.t(),
          required(:reason) => String.t(),
          required(:fingerprint) => String.t() | nil,
          optional(:fingerprints) => [String.t()],
          optional(:remedy) => String.t(),
          optional(:rotation_reason) => String.t()
        }

  @type chart_identities :: %{
          total: non_neg_integer(),
          adopted: non_neg_integer(),
          legacy_certificates: non_neg_integer(),
          not_adopted: [identity_warning()],
          unlisted: [%{file: String.t(), reason: String.t()}]
        }

  @type t :: %{
          enforcement_configured: boolean(),
          authorizer_answering: boolean(),
          authorizer_reason: String.t() | nil,
          signing_keys_provisioned: boolean(),
          leaf_listener: boolean(),
          chart_identities: chart_identities()
        }

  @doc """
  Returns the current hub readiness from core's configuration and processes.
  """
  @spec status() :: t()
  def status do
    build(
      enforcement_configured:
        Application.get_env(:serviceradar, :nats_certificate_authorization_enabled, false) == true,
      leaf_listener:
        Application.get_env(:serviceradar, :nats_leaf_listener_enabled, false) == true,
      mounted_seeds_status: Configuration.mounted_seeds_status(),
      readiness: Authorization.readiness(),
      inventory_report: ChartIdentityInventory.report(),
      rotation_refusals: RuntimeCertificateRotation.refusals()
    )
  end

  @doc """
  Builds the hub readiness map from explicit inputs.
  """
  @spec build(keyword()) :: t()
  def build(opts) do
    enforcement_configured = Keyword.get(opts, :enforcement_configured, false) == true
    leaf_listener = Keyword.get(opts, :leaf_listener, false) == true
    mounted_seeds_status = Keyword.get(opts, :mounted_seeds_status, :not_configured)

    readiness =
      Keyword.get(opts, :readiness, %{
        ready: false,
        reason: "authorizer_unavailable",
        auth_mode: nil
      })

    inventory_report = Keyword.get(opts, :inventory_report)
    rotation_refusals = Keyword.get(opts, :rotation_refusals, %{})

    signing_keys_provisioned = signing_keys_provisioned?(mounted_seeds_status, readiness)

    {authorizer_answering, authorizer_reason} =
      authorizer_status(mounted_seeds_status, readiness)

    %{
      enforcement_configured: enforcement_configured,
      authorizer_answering: authorizer_answering,
      authorizer_reason: authorizer_reason,
      signing_keys_provisioned: signing_keys_provisioned,
      leaf_listener: leaf_listener,
      chart_identities: format_chart_identities(inventory_report, rotation_refusals)
    }
  end

  defp signing_keys_provisioned?(:ok, _readiness), do: true
  defp signing_keys_provisioned?({:error, :signing_keys_not_provisioned}, _readiness), do: false

  defp signing_keys_provisioned?(:not_configured, readiness) do
    readiness[:ready] == true or is_binary(readiness[:auth_mode])
  end

  # Missing mounted seeds always take precedence over broker/connection failures
  # so operators see signing_keys_not_provisioned even during a broker outage.
  defp authorizer_status({:error, :signing_keys_not_provisioned}, _readiness) do
    {false, "signing_keys_not_provisioned"}
  end

  defp authorizer_status(_mounted_seeds_status, %{ready: true}) do
    {true, nil}
  end

  defp authorizer_status(_mounted_seeds_status, readiness) do
    {false, readiness[:reason] || "authorizer_unavailable"}
  end

  defp format_chart_identities(nil, _rotation_refusals) do
    %{
      total: 0,
      adopted: 0,
      legacy_certificates: 0,
      not_adopted: [],
      unlisted: []
    }
  end

  defp format_chart_identities(report, rotation_refusals) do
    identities = Map.get(report, :identities, [])
    adopted = Enum.count(identities, &(&1.status == :adopted))

    not_adopted =
      identities
      |> Enum.filter(&(&1.status != :adopted))
      |> Enum.map(&format_uncovered_identity(&1, rotation_refusals))

    unlisted =
      report
      |> Map.get(:unlisted, [])
      |> Enum.map(fn item ->
        %{file: item.file, reason: format_reason(item.reason)}
      end)

    %{
      total: length(identities),
      adopted: adopted,
      legacy_certificates: Map.get(report, :legacy_certificates, 0),
      not_adopted: not_adopted,
      unlisted: unlisted
    }
  end

  defp format_uncovered_identity(identity, rotation_refusals) do
    entry = %{
      subject: identity.subject,
      reason: format_reason(identity.reason),
      fingerprint: identity.fingerprint
    }

    entry =
      case Map.get(identity, :fingerprints) do
        fingerprints when is_list(fingerprints) -> Map.put(entry, :fingerprints, fingerprints)
        _ -> entry
      end

    entry =
      case remedy_for(identity.reason) do
        nil -> entry
        remedy -> Map.put(entry, :remedy, remedy)
      end

    maybe_put_rotation_reason(entry, identity, rotation_refusals)
  end

  defp maybe_put_rotation_reason(
         entry,
         %{reason: :held_unrecorded, fingerprint: fingerprint},
         rotation_refusals
       )
       when is_binary(fingerprint) and is_map(rotation_refusals) do
    case Map.get(rotation_refusals, String.downcase(fingerprint)) do
      reason when is_binary(reason) and reason != "" ->
        Map.put(entry, :rotation_reason, reason)

      _ ->
        entry
    end
  end

  defp maybe_put_rotation_reason(entry, _identity, _rotation_refusals), do: entry

  defp remedy_for(:held_unrecorded) do
    "Subject is held and the current inventory certificate is unrecorded; record it through the successor API (POST /api/admin/managed-components/<id>/certificates)."
  end

  defp remedy_for(:legacy_certificates_without_subject) do
    "An infrastructure component has a recorded certificate without a stored subject; record those certificates again through POST /api/admin/managed-components/adopt or remove the component."
  end

  defp remedy_for(_reason), do: nil

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason({:adoption_failed, inner}), do: "adoption_failed:#{format_reason(inner)}"
  defp format_reason(other), do: inspect(other)
end
