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
end
