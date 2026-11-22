defmodule ServiceRadar.NATS.HubReadinessTest do
  @moduledoc """
  Unit tests for core hub certificate-authorization readiness reporting
  (Task 3.5 of add-zero-touch-hub-certificate-authorization).
  """
  use ExUnit.Case, async: false

  alias ServiceRadar.Edge.ChartIdentityInventory
  alias ServiceRadar.Edge.RuntimeCertificateRotation
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
    assert hub.chart_identities == nil
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
    assert hub.chart_identities == nil
  end

  test "distinguishes an unreconciled nil inventory from a reconciled empty inventory" do
    unreconciled = HubReadiness.build(inventory_report: nil)
    assert unreconciled.chart_identities == nil

    {:ok, empty_report} = ChartIdentityInventory.reconcile(nil)
    reconciled_empty = HubReadiness.build(inventory_report: empty_report)

    assert reconciled_empty.chart_identities == %{
             total: 0,
             adopted: 0,
             legacy_certificates: 0,
             not_adopted: [],
             unlisted: []
           }
  end

  test "malformed chart identities file leaves report nil instead of zero counts", %{
    tmp_dir: dir
  } do
    previous_dir = Application.get_env(:serviceradar, :nats_infrastructure_certs_dir)
    previous_identities = Application.get_env(:serviceradar, :nats_chart_identities_file)
    previous_root = Application.get_env(:serviceradar, :nats_infrastructure_root_file)

    on_exit(fn ->
      restore_env(:nats_infrastructure_certs_dir, previous_dir)
      restore_env(:nats_chart_identities_file, previous_identities)
      restore_env(:nats_infrastructure_root_file, previous_root)
    end)

    certs_dir = Path.join(dir, "certs")
    File.mkdir_p!(certs_dir)
    identities_file = Path.join(dir, "identities.yaml")
    root_file = Path.join(dir, "root.pem")
    File.write!(identities_file, "not: a list\n")
    File.write!(root_file, "not a certificate\n")

    Application.put_env(:serviceradar, :nats_infrastructure_certs_dir, certs_dir)
    Application.put_env(:serviceradar, :nats_chart_identities_file, identities_file)
    Application.put_env(:serviceradar, :nats_infrastructure_root_file, root_file)

    start_supervised!(ChartIdentityInventory)
    _ = :sys.get_state(ChartIdentityInventory)

    assert ChartIdentityInventory.report() == nil
    assert HubReadiness.status().chart_identities == nil
  end

  test "formats uncovered chart identities without remedies and bounds error reasons" do
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
        },
        %{
          subject: "CN=serviceradar-mapper,O=ServiceRadar",
          status: :not_adopted,
          fingerprint: "eee444",
          reason: {:adoption_failed, %{internal: "secret_detail"}}
        },
        %{
          subject: "CN=serviceradar-poller,O=ServiceRadar",
          status: :not_adopted,
          fingerprint: "fff555",
          reason: {:adoption_failed, :untrusted_issuer}
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

    assert hub.chart_identities.total == 7
    assert hub.chart_identities.adopted == 1
    assert hub.chart_identities.legacy_certificates == 1
    assert hub.chart_identities.unlisted == [%{file: "extra.pem", reason: "not_a_chart_identity"}]

    by_subject = Map.new(hub.chart_identities.not_adopted, &{&1.subject, &1})

    gateway = by_subject["CN=serviceradar-agent-gateway,O=ServiceRadar"]
    assert gateway.reason == "held_unrecorded"
    assert gateway.rotation_reason == "untrusted_issuer"
    refute Map.has_key?(gateway, :remedy)

    web_ng = by_subject["CN=serviceradar-web-ng,O=ServiceRadar"]
    assert web_ng.reason == "held_unrecorded"
    refute Map.has_key?(web_ng, :rotation_reason)
    refute Map.has_key?(web_ng, :remedy)

    sync = by_subject["CN=serviceradar-sync,O=ServiceRadar"]
    assert sync.reason == "no_inventory_certificate"
    refute Map.has_key?(sync, :remedy)

    datasvc = by_subject["CN=serviceradar-datasvc,O=ServiceRadar"]
    assert datasvc.reason == "legacy_certificates_without_subject"
    refute Map.has_key?(datasvc, :remedy)

    mapper = by_subject["CN=serviceradar-mapper,O=ServiceRadar"]
    assert mapper.reason == "adoption_failed"
    refute mapper.reason =~ "secret_detail"

    poller = by_subject["CN=serviceradar-poller,O=ServiceRadar"]
    assert poller.reason == "adoption_failed:untrusted_issuer"
  end

  test "reports rotation_unavailable on held_unrecorded when rotation refusals are unavailable" do
    report = %{
      identities: [
        %{
          subject: "CN=serviceradar-agent-gateway,O=ServiceRadar",
          status: :not_adopted,
          fingerprint: "bbb111",
          reason: :held_unrecorded
        }
      ],
      unlisted: [],
      legacy_certificates: 0
    }

    hub = HubReadiness.build(inventory_report: report, rotation_refusals: nil)
    [gateway] = hub.chart_identities.not_adopted
    assert gateway.rotation_reason == "rotation_unavailable"
  end

  test "RuntimeCertificateRotation.refusals reports nil when unavailable or unreadable and bounds transient errors",
       %{tmp_dir: dir} do
    previous_file = Application.get_env(:serviceradar, :runtime_cert_rotation_file)

    on_exit(fn ->
      restore_env(:runtime_cert_rotation_file, previous_file)
    end)

    assert RuntimeCertificateRotation.refusals() == nil

    manifest_path = Path.join(dir, "runtime-cert-rotation.json")
    Application.put_env(:serviceradar, :runtime_cert_rotation_file, manifest_path)

    start_supervised!(RuntimeCertificateRotation)
    _ = :sys.get_state(RuntimeCertificateRotation)
    assert RuntimeCertificateRotation.refusals() == %{}

    %{cert: cert_der} = :public_key.pkix_test_root_cert(~c"example-rotation", [])
    cert_pem = :public_key.pem_encode([{:Certificate, cert_der, :not_encrypted}])
    prev_fp = String.duplicate("a", 64)
    invalid_fp = String.duplicate("b", 64)
    transient_fp = String.duplicate("c", 64)

    File.write!(
      manifest_path,
      Jason.encode!(%{
        "version" => 1,
        "certificates" => [
          %{
            "previous_fingerprint" => prev_fp,
            "fingerprint" => invalid_fp,
            "certificate_pem" => "not-a-pem"
          }
        ]
      })
    )

    send(RuntimeCertificateRotation, :tick)
    _ = :sys.get_state(RuntimeCertificateRotation)

    assert RuntimeCertificateRotation.refusals() == %{invalid_fp => "invalid_certificate"}

    File.write!(
      manifest_path,
      Jason.encode!(%{
        "version" => 1,
        "certificates" => [
          %{
            "previous_fingerprint" => prev_fp,
            "fingerprint" => transient_fp,
            "certificate_pem" => cert_pem
          }
        ]
      })
    )

    send(RuntimeCertificateRotation, :tick)
    _ = :sys.get_state(RuntimeCertificateRotation)
    assert RuntimeCertificateRotation.refusals() == nil

    File.write!(manifest_path, "{invalid json")
    send(RuntimeCertificateRotation, :tick)
    _ = :sys.get_state(RuntimeCertificateRotation)
    assert RuntimeCertificateRotation.refusals() == nil

    assert RuntimeCertificateRotation.refusals_from_outcomes([
             {:recorded, "1111", "comp-1"},
             {:skipped, "2222", :predecessor_not_recorded},
             {:refused, "AABB", :untrusted_issuer},
             {:refused, "CCDD", {:error, %{internal: "ash_detail"}}},
             {:refused, "EEFF", "raw internal error"}
           ]) == %{
             "aabb" => "untrusted_issuer",
             "ccdd" => "transient_error",
             "eeff" => "transient_error"
           }
  end

  test "mounted_seeds_status checks all three seed files without touching the database", %{
    tmp_dir: dir
  } do
    previous_dir = Application.get_env(:serviceradar, :nats_callout_seeds_dir)

    on_exit(fn ->
      restore_env(:nats_callout_seeds_dir, previous_dir)
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

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar, key, value)
end
