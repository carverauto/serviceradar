defmodule ServiceRadarWebNGWeb.Auth.SAMLAssertionValidatorTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Auth.SAMLAssertionValidator

  @moduletag :db_free

  @valid_now ~U[2026-03-02 12:00:00Z]

  @config %{
    idp_entity_id: "https://idp.example.com",
    sp_entity_id: "https://sp.example.com",
    acs_url: "https://sp.example.com/auth/saml/consume",
    assertion_max_validity_seconds: 300
  }

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

  test "rejects an assertion without an ID, which could not be recorded as used" do
    for id <- [nil, "", "   "] do
      assert {:error, :missing_assertion_id} =
               SAMLAssertionValidator.validate(assertion_fixture(id: id), @config, @valid_now)
    end
  end

  test "rejects an assertion without an issuer" do
    assert {:error, :missing_issuer} =
             SAMLAssertionValidator.validate(assertion_fixture(issuer: ""), @config, @valid_now)
  end

  test "rejects an assertion without a NotOnOrAfter bound" do
    assert {:error, :invalid_assertion_time} =
             SAMLAssertionValidator.validate(assertion_fixture(not_on_or_after: ""), @config, @valid_now)
  end

  test "rejects an expired bearer subject confirmation" do
    assertion = assertion_fixture(subject_not_on_or_after: "2026-03-02T11:59:30Z")

    assert {:error, :subject_confirmation_expired} =
             SAMLAssertionValidator.validate(assertion, @config, @valid_now)

    assertion = assertion_fixture(subject_not_on_or_after: "2026-03-02T12:01:00Z")
    assert :ok = SAMLAssertionValidator.validate(assertion, @config, @valid_now)
  end

  describe "validate_in_response_to/2" do
    test "accepts an assertion answering the stored request" do
      assertion = assertion_fixture(in_response_to: "_req-1", response_in_response_to: "_req-1")
      assert :ok = SAMLAssertionValidator.validate_in_response_to(assertion, "_req-1")

      assertion = assertion_fixture(in_response_to: "_req-1")
      assert :ok = SAMLAssertionValidator.validate_in_response_to(assertion, "_req-1")
    end

    test "rejects an assertion answering a different request" do
      assertion = assertion_fixture(in_response_to: "_req-other")

      assert {:error, :in_response_to_mismatch} =
               SAMLAssertionValidator.validate_in_response_to(assertion, "_req-1")
    end

    test "rejects a response whose own InResponseTo names a different request" do
      assertion = assertion_fixture(in_response_to: "_req-1", response_in_response_to: "_req-other")

      assert {:error, :in_response_to_mismatch} =
               SAMLAssertionValidator.validate_in_response_to(assertion, "_req-1")
    end

    test "rejects a solicited flow whose assertion names no request" do
      assert {:error, :missing_in_response_to} =
               SAMLAssertionValidator.validate_in_response_to(assertion_fixture([]), "_req-1")
    end

    test "unsolicited: accepts only an assertion that answers no request" do
      assert :ok = SAMLAssertionValidator.validate_in_response_to(assertion_fixture([]), :unsolicited)

      for overrides <- [[in_response_to: "_req-1"], [response_in_response_to: "_req-1"]] do
        assert {:error, :unexpected_in_response_to} =
                 SAMLAssertionValidator.validate_in_response_to(assertion_fixture(overrides), :unsolicited)
      end
    end

    test "rejects a missing expected request" do
      assertion = assertion_fixture(in_response_to: "_req-1")

      for expected <- [nil, ""] do
        assert {:error, :missing_authn_request} =
                 SAMLAssertionValidator.validate_in_response_to(assertion, expected)
      end
    end
  end

  defp assertion_fixture(overrides) do
    base = %{
      id: "_assertion-1",
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

      {:id, value}, acc ->
        Map.put(acc, :id, value)

      {:subject_not_on_or_after, value}, acc ->
        put_in(acc, [:subject_confirmation, :not_on_or_after], value)

      {:in_response_to, value}, acc ->
        put_in(acc, [:subject_confirmation, :in_response_to], value)

      {:response_in_response_to, value}, acc ->
        Map.put(acc, :response_in_response_to, value)

      _, acc ->
        acc
    end)
  end
end
