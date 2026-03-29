defmodule ServiceRadarWebNGWeb.Auth.SAMLAssertionValidatorTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Auth.SAMLAssertionValidator

  @valid_now ~U[2026-03-02 12:00:00Z]

  test "accepts valid assertion" do
    assertion =
      assertion_fixture(
        not_before: "2026-03-02T11:59:00Z",
        not_on_or_after: "2026-03-02T12:02:00Z",
        issuer: "https://idp.example.com",
        audience: "https://sp.example.com",
        recipient: "https://sp.example.com/auth/saml/consume"
      )

    config = %{
      idp_entity_id: "https://idp.example.com",
      sp_entity_id: "https://sp.example.com",
      acs_url: "https://sp.example.com/auth/saml/consume",
      assertion_max_validity_seconds: 300
    }

    assert :ok = SAMLAssertionValidator.validate(assertion, config, @valid_now)
  end

  test "rejects mismatched issuer" do
    assertion =
      assertion_fixture(
        issuer: "https://evil-idp.example.com",
        not_before: "2026-03-02T11:59:00Z",
        not_on_or_after: "2026-03-02T12:02:00Z"
      )

    config = %{
      idp_entity_id: "https://idp.example.com",
      sp_entity_id: "https://sp.example.com",
      acs_url: "https://sp.example.com/auth/saml/consume",
      assertion_max_validity_seconds: 300
    }

    assert {:error, :invalid_issuer} =
             SAMLAssertionValidator.validate(assertion, config, @valid_now)
  end

  test "rejects mismatched audience" do
    assertion =
      assertion_fixture(
        audience: "https://other-sp.example.com",
        not_before: "2026-03-02T11:59:00Z",
        not_on_or_after: "2026-03-02T12:02:00Z"
      )

    config = %{
      idp_entity_id: nil,
      sp_entity_id: "https://sp.example.com",
      acs_url: "https://sp.example.com/auth/saml/consume",
      assertion_max_validity_seconds: 300
    }

    assert {:error, :invalid_audience} =
             SAMLAssertionValidator.validate(assertion, config, @valid_now)
  end

  test "rejects missing audience when SP entity id is configured" do
    assertion =
      assertion_fixture(
        audience: nil,
        not_before: "2026-03-02T11:59:00Z",
        not_on_or_after: "2026-03-02T12:02:00Z"
      )

    config = %{
      idp_entity_id: nil,
      sp_entity_id: "https://sp.example.com",
      acs_url: "https://sp.example.com/auth/saml/consume",
      assertion_max_validity_seconds: 300
    }

    assert {:error, :invalid_audience} =
             SAMLAssertionValidator.validate(assertion, config, @valid_now)
  end

  test "rejects mismatched recipient" do
    assertion =
      assertion_fixture(
        recipient: "https://other-sp.example.com/auth/saml/consume",
        not_before: "2026-03-02T11:59:00Z",
        not_on_or_after: "2026-03-02T12:02:00Z"
      )

    config = %{
      idp_entity_id: nil,
      sp_entity_id: "https://sp.example.com",
      acs_url: "https://sp.example.com/auth/saml/consume",
      assertion_max_validity_seconds: 300
    }

    assert {:error, :invalid_recipient} =
             SAMLAssertionValidator.validate(assertion, config, @valid_now)
  end

  test "rejects missing recipient when ACS URL is configured" do
    assertion =
      assertion_fixture(
        recipient: nil,
        not_before: "2026-03-02T11:59:00Z",
        not_on_or_after: "2026-03-02T12:02:00Z"
      )

    config = %{
      idp_entity_id: nil,
      sp_entity_id: "https://sp.example.com",
      acs_url: "https://sp.example.com/auth/saml/consume",
      assertion_max_validity_seconds: 300
    }

    assert {:error, :invalid_recipient} =
             SAMLAssertionValidator.validate(assertion, config, @valid_now)
  end

  test "rejects overly large assertion window" do
    assertion =
      assertion_fixture(
        not_before: "2026-03-02T11:00:00Z",
        not_on_or_after: "2026-03-02T12:10:00Z"
      )

    config = %{
      idp_entity_id: nil,
      sp_entity_id: "https://sp.example.com",
      acs_url: "https://sp.example.com/auth/saml/consume",
      assertion_max_validity_seconds: 300
    }

    assert {:error, :assertion_window_too_large} =
             SAMLAssertionValidator.validate(assertion, config, @valid_now)
  end

  test "rejects expired assertion" do
    assertion =
      assertion_fixture(
        not_before: "2026-03-02T11:40:00Z",
        not_on_or_after: "2026-03-02T11:59:59Z"
      )

    config = %{
      idp_entity_id: nil,
      sp_entity_id: "https://sp.example.com",
      acs_url: "https://sp.example.com/auth/saml/consume",
      assertion_max_validity_seconds: 300
    }

    assert {:error, :assertion_expired} =
             SAMLAssertionValidator.validate(assertion, config, @valid_now)
  end

  defp assertion_fixture(overrides) do
    base = %{
      issuer: "https://idp.example.com",
      conditions: %{
        not_before: "2026-03-02T11:59:00Z",
        not_on_or_after: "2026-03-02T12:02:00Z",
        audience: "https://sp.example.com"
      },
      subject_confirmation: %{
        recipient: "https://sp.example.com/auth/saml/consume"
      }
    }

    Enum.reduce(overrides, base, fn
      {:not_before, value}, acc ->
        put_in(acc, [:conditions, :not_before], value)

      {:not_on_or_after, value}, acc ->
        put_in(acc, [:conditions, :not_on_or_after], value)

      {:audience, value}, acc ->
        put_in(acc, [:conditions, :audience], value)

      {:recipient, value}, acc ->
        put_in(acc, [:subject_confirmation, :recipient], value)

      {:issuer, value}, acc ->
        Map.put(acc, :issuer, value)

      _, acc ->
        acc
    end)
  end
end
