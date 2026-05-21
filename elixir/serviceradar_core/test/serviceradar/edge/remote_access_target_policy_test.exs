defmodule ServiceRadar.Edge.RemoteAccessTargetPolicyTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.RemoteAccessApplicationTarget
  alias ServiceRadar.Edge.RemoteAccessTargetPolicy
  alias ServiceRadar.Edge.RemoteAccessTcpTarget

  test "normalizes registered application target policy defaults and operator settings" do
    target = %RemoteAccessApplicationTarget{
      upstream_scheme: :https,
      upstream_host: "10.0.10.20",
      upstream_port: 8443,
      tls_policy: %{"verify" => "ca_bundle", "ca_bundle_ref" => "ca:internal"},
      allowed_methods: ["get", "HEAD", "GET"],
      allowed_path_prefixes: ["/admin", "/api"],
      header_policy: %{
        "allow" => ["accept"],
        "drop" => ["authorization"],
        "inject" => %{"x-serviceradar-target" => "internal"},
        "redirects" => %{"mode" => "same_origin", "max_hops" => 1}
      },
      cookie_policy: %{"isolation" => "session"},
      quota_policy: %{"max_request_bytes" => "1024", "max_response_bytes" => 2048},
      recording_policy: %{"enabled" => true}
    }

    assert {:ok, policy} = RemoteAccessTargetPolicy.evaluate_application(target)

    assert policy["allowed_methods"] == ["GET", "HEAD"]
    assert policy["allowed_path_prefixes"] == ["/admin", "/api"]
    assert policy["tls_policy"] == %{"verify" => "ca_bundle", "ca_bundle_ref" => "ca:internal"}
    assert policy["redirect_policy"] == %{"mode" => "same_origin", "max_hops" => 1}

    assert policy["header_policy"] == %{
             "allow" => ["accept"],
             "drop" => ["authorization"],
             "inject" => %{"x-serviceradar-target" => "internal"}
           }

    assert policy["cookie_policy"] == %{"isolation" => "session", "store" => false}
    assert policy["quota_policy"]["max_request_bytes"] == 1024
    assert policy["quota_policy"]["max_response_bytes"] == 2048
    assert policy["recording_policy"]["metadata_only"] == true
    assert policy["recording_policy"]["capture_bodies"] == false
    assert policy["approval_policy"]["required"] == false
  end

  test "rejects app policy that would create SSRF or open-proxy behavior" do
    assert {:error, :invalid_remote_access_target_policy} =
             RemoteAccessTargetPolicy.evaluate_application(%RemoteAccessApplicationTarget{
               upstream_scheme: :https,
               allowed_path_prefixes: ["http://169.254.169.254/latest/meta-data"]
             })

    assert {:error, :invalid_remote_access_target_policy} =
             RemoteAccessTargetPolicy.evaluate_application(%RemoteAccessApplicationTarget{
               upstream_scheme: :https,
               allowed_methods: ["CONNECT"]
             })

    assert {:error, :invalid_remote_access_target_policy} =
             RemoteAccessTargetPolicy.evaluate_application(%RemoteAccessApplicationTarget{
               upstream_scheme: :https,
               header_policy: %{"redirects" => %{"mode" => "policy_allowed", "max_hops" => 99}}
             })

    for prefix <- [
          "/allowed/../admin",
          "/allowed/%2e%2e/admin",
          "/allowed%2f..%2fadmin",
          "/allowed\\admin"
        ] do
      assert {:error, :invalid_remote_access_target_policy} =
               RemoteAccessTargetPolicy.evaluate_application(%RemoteAccessApplicationTarget{
                 upstream_scheme: :https,
                 allowed_path_prefixes: [prefix]
               })
    end
  end

  test "marks risky application policy as approval-required" do
    target = %RemoteAccessApplicationTarget{
      upstream_scheme: :https,
      tls_policy: %{"verify" => "insecure_skip_verify"},
      allowed_methods: ["GET", "POST"],
      allowed_path_prefixes: ["/"],
      recording_policy: %{"capture_bodies" => true},
      approval_policy: %{"sensitive" => true, "reason" => "break glass"}
    }

    assert {:ok, policy} = RemoteAccessTargetPolicy.evaluate_application(target)

    assert policy["approval_policy"]["required"] == true

    assert Enum.sort(policy["approval_policy"]["reasons"]) == [
             "body_recording",
             "broad_path_access",
             "insecure_upstream_tls",
             "sensitive_application",
             "upload_enabled"
           ]

    assert policy["approval_policy"]["reason"] == "break glass"
    assert policy["recording_policy"]["capture_bodies"] == true
  end

  test "normalizes TCP target quotas and approval policy" do
    target = %RemoteAccessTcpTarget{
      quota_policy: %{"max_rx_bytes" => "4096", "max_tx_bytes" => 8192},
      approval_policy: %{"reasons" => "database\nproduction"}
    }

    assert {:ok, policy} = RemoteAccessTargetPolicy.evaluate_tcp(target)

    assert policy["quota_policy"] == %{"max_rx_bytes" => 4096, "max_tx_bytes" => 8192}
    assert policy["approval_policy"]["required"] == true

    assert Enum.sort(policy["approval_policy"]["reasons"]) == [
             "database",
             "production",
             "tcp_target"
           ]

    assert policy["recording_policy"]["metadata_only"] == true
  end

  test "rejects invalid TCP quotas" do
    assert {:error, :invalid_remote_access_target_policy} =
             RemoteAccessTargetPolicy.evaluate_tcp(%RemoteAccessTcpTarget{
               quota_policy: %{"max_rx_bytes" => 0}
             })

    assert {:error, :invalid_remote_access_target_policy} =
             RemoteAccessTargetPolicy.evaluate_tcp(%RemoteAccessTcpTarget{
               quota_policy: %{"max_tx_bytes" => "not-an-int"}
             })
  end
end
