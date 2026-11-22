defmodule ServiceRadar.NATS.HubReadinessTest do
  @moduledoc """
  Unit tests for core hub certificate-authorization readiness reporting
  (Task 3.5 of add-zero-touch-hub-certificate-authorization).
  """
  use ExUnit.Case, async: false

  alias ServiceRadar.NATS.CertificateAuthorizationToken, as: Token
  alias ServiceRadar.NATS.HubReadiness
  alias ServiceRadar.NATS.ManagedCertificateConfiguration, as: Configuration

  @moduletag :tmp_dir

  test "reports ready hub when enforcement, signing seeds, authorizer, and leaf listener are active" do
    report = %{
      identities: [
        %{
          subject: "CN=serviceradar-core,O=ServiceRadar",
          status: :adopted,
          fingerprint: "aaa",
          reason: nil
        },
        %{
          subject: "CN=serviceradar-web-ng,O=ServiceRadar",
          status: :adopted,
          fingerprint: "bbb",
          reason: nil
        }
      ],
      unlisted: [],
      legacy_certificates: 0
    }

    hub =
      HubReadiness.build(
        enforcement_configured: true,
        leaf_listener: true,
        mounted_seeds_status: :ok,
        readiness: %{
          auth_mode: "static_mtls",
          account_name: "SERVICERADAR",
          ready: true,
          reason: nil
        },
        inventory_report: report,
        rotation_refusals: %{}
      )

    assert hub == %{
             enforcement_configured: true,
             authorizer_answering: true,
             authorizer_reason: nil,
             signing_keys_provisioned: true,
             leaf_listener: true,
             chart_identities: %{
               total: 2,
               adopted: 2,
               legacy_certificates: 0,
               not_adopted: [],
               unlisted: []
             }
           }
  end

  test "missing mounted seeds always report signing_keys_not_provisioned even during a broker outage" do
    hub =
      HubReadiness.build(
        enforcement_configured: true,
        leaf_listener: true,
        mounted_seeds_status: {:error, :signing_keys_not_provisioned},
        readiness: %{
          auth_mode: nil,
          account_name: nil,
          ready: false,
          reason: "auth_connection_unavailable"
        },
        inventory_report: nil,
        rotation_refusals: %{}
      )

    assert hub.enforcement_configured == true
    assert hub.signing_keys_provisioned == false
    assert hub.authorizer_answering == false
    assert hub.authorizer_reason == "signing_keys_not_provisioned"
    assert hub.leaf_listener == true
  end

  test "reports authorizer_reason when seeds are mounted but authorizer is disconnected" do
    hub =
      HubReadiness.build(
        enforcement_configured: true,
        leaf_listener: false,
        mounted_seeds_status: :ok,
        readiness: %{
          auth_mode: "static_mtls",
          account_name: "SERVICERADAR",
          ready: false,
          reason: "auth_connection_unavailable"
        },
        inventory_report: nil,
        rotation_refusals: %{}
      )

    assert hub.signing_keys_provisioned == true
    assert hub.authorizer_answering == false
    assert hub.authorizer_reason == "auth_connection_unavailable"
    assert hub.leaf_listener == false
  end

  test "formats uncovered chart identities with remedies and rotation refusal reason when present" do
    report = %{
      identities: [
        %{
          subject: "CN=serviceradar-core,O=ServiceRadar",
          status: :adopted,
          fingerprint: "aaa",
          reason: nil
        },
        %{
          subject: "CN=serviceradar-agent-gateway,O=ServiceRadar",
          status: :not_adopted,
          fingerprint: "bbb111",
          reason: :held_unrecorded
        },
        %{
          subject: "CN=serviceradar-web-ng,O=ServiceRadar",
          status: :not_adopted,
          fingerprint: "ccc222",
          reason: :held_unrecorded
        },
        %{
          subject: "CN=serviceradar-sync,O=ServiceRadar",
          status: :not_adopted,
          fingerprint: nil,
          reason: :no_inventory_certificate
        },
        %{
          subject: "CN=serviceradar-datasvc,O=ServiceRadar",
          status: :not_adopted,
          fingerprint: "ddd333",
          reason: :legacy_certificates_without_subject
        }
      ],
      unlisted: [%{file: "extra.pem", reason: :not_a_chart_identity}],
      legacy_certificates: 1
    }

    hub =
      HubReadiness.build(
        enforcement_configured: false,
        leaf_listener: false,
        mounted_seeds_status: :not_configured,
        readiness: %{auth_mode: nil, account_name: nil, ready: false, reason: "not_configured"},
        inventory_report: report,
        rotation_refusals: %{"bbb111" => "untrusted_issuer"}
      )

    assert hub.chart_identities.total == 5
    assert hub.chart_identities.adopted == 1
    assert hub.chart_identities.legacy_certificates == 1
    assert hub.chart_identities.unlisted == [%{file: "extra.pem", reason: "not_a_chart_identity"}]

    by_subject = Map.new(hub.chart_identities.not_adopted, &{&1.subject, &1})

    gateway = by_subject["CN=serviceradar-agent-gateway,O=ServiceRadar"]
    assert gateway.reason == "held_unrecorded"
    assert gateway.rotation_reason == "untrusted_issuer"
    assert gateway.remedy =~ "POST /api/admin/managed-components/<id>/certificates"

    web_ng = by_subject["CN=serviceradar-web-ng,O=ServiceRadar"]
    assert web_ng.reason == "held_unrecorded"
    refute Map.has_key?(web_ng, :rotation_reason)
    assert web_ng.remedy =~ "POST /api/admin/managed-components/<id>/certificates"

    sync = by_subject["CN=serviceradar-sync,O=ServiceRadar"]
    assert sync.reason == "no_inventory_certificate"
    refute Map.has_key?(sync, :remedy)

    datasvc = by_subject["CN=serviceradar-datasvc,O=ServiceRadar"]
    assert datasvc.reason == "legacy_certificates_without_subject"
    assert datasvc.remedy =~ "POST /api/admin/managed-components/adopt"
  end

  test "mounted_seeds_status checks all three seed files without touching the database", %{
    tmp_dir: dir
  } do
    previous_dir = Application.get_env(:serviceradar, :nats_callout_seeds_dir)

    on_exit(fn ->
      if is_nil(previous_dir),
        do: Application.delete_env(:serviceradar, :nats_callout_seeds_dir),
        else: Application.put_env(:serviceradar, :nats_callout_seeds_dir, previous_dir)
    end)

    Application.delete_env(:serviceradar, :nats_callout_seeds_dir)
    assert Configuration.mounted_seeds_status() == :not_configured

    Application.put_env(:serviceradar, :nats_callout_seeds_dir, dir)
    assert Configuration.mounted_seeds_status() == {:error, :signing_keys_not_provisioned}

    File.write!(Path.join(dir, "nats-callout-issuer.seed"), Token.new_key(:account).seed <> "\n")
    File.write!(Path.join(dir, "nats-callout-auth.seed"), Token.new_key(:user).seed <> "\n")
    File.write!(Path.join(dir, "nats-callout-system.seed"), Token.new_key(:user).seed <> "\n")

    assert Configuration.mounted_seeds_status() == :ok

    File.rm!(Path.join(dir, "nats-callout-auth.seed"))
    assert Configuration.mounted_seeds_status() == {:error, :signing_keys_not_provisioned}
  end
end
