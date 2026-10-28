defmodule ServiceRadar.Edge.CertificateLifetimePolicyTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.CertificateLifetimePolicy

  test "defines 90-day default, 7-day minimum, 365-day maximum, and 30-day (2/3) renewal policy" do
    assert CertificateLifetimePolicy.default_validity_days() == 90
    assert CertificateLifetimePolicy.min_validity_days() == 7
    assert CertificateLifetimePolicy.max_validity_days() == 365
    assert CertificateLifetimePolicy.renewal_lead_days() == 30
    assert CertificateLifetimePolicy.renewal_fraction() == {2, 3}
    assert CertificateLifetimePolicy.seconds_per_day() == 86_400
  end

  test "resolves default validity days and seconds when omitted" do
    assert CertificateLifetimePolicy.resolve_validity_days() == {:ok, 90}
    assert CertificateLifetimePolicy.resolve_validity_seconds() == {:ok, 90 * 86_400}
  end

  test "rejects validity below 7 days or above 365 days unless allow_short_test_lifetime is enabled" do
    for invalid <- [0, 1, 6, 366, -5, "90"] do
      assert {:error, {:invalid_certificate_validity_days, ^invalid}} =
               CertificateLifetimePolicy.resolve_validity_days(validity_days: invalid)
    end

    assert {:ok, 1} =
             CertificateLifetimePolicy.resolve_validity_days(
               validity_days: 1,
               allow_short_test_lifetime: true
             )

    assert {:ok, 86_400} =
             CertificateLifetimePolicy.resolve_validity_seconds(
               validity_days: 1,
               allow_short_test_lifetime: true
             )

    assert {:error, {:invalid_certificate_validity_days, 0}} =
             CertificateLifetimePolicy.resolve_validity_days(
               validity_days: 0,
               allow_short_test_lifetime: true
             )
  end

  test "parses the AGENT_CERT_VALIDITY_DAYS deployment default and refuses values outside 7..365" do
    assert CertificateLifetimePolicy.parse_default_validity_days!(nil) == 90
    assert CertificateLifetimePolicy.parse_default_validity_days!("  ") == 90
    assert CertificateLifetimePolicy.parse_default_validity_days!("7") == 7
    assert CertificateLifetimePolicy.parse_default_validity_days!(" 365 ") == 365

    for invalid <- ["6", "366", "0", "-30", "90d", "1.5", "ninety"] do
      assert_raise ArgumentError,
                   ~r/AGENT_CERT_VALIDITY_DAYS must be an integer from 7 to 365 days/,
                   fn ->
                     CertificateLifetimePolicy.parse_default_validity_days!(invalid)
                   end
    end
  end

  test "reads notAfter from UTCTime and GeneralizedTime certificates" do
    for not_after <- [~D[2027-03-04], ~D[2051-01-02]] do
      %{cert: der} =
        :public_key.pkix_test_root_cert(~c"policy-test",
          validity: {{2026, 1, 1}, Date.to_erl(not_after)}
        )

      pem = :public_key.pem_encode([{:Certificate, der, :not_encrypted}])

      assert CertificateLifetimePolicy.certificate_not_after(pem) ==
               {:ok, DateTime.new!(not_after, ~T[13:00:00], "Etc/UTC")}
    end

    assert CertificateLifetimePolicy.certificate_not_after(
             "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n"
           ) ==
             :error
  end
end
