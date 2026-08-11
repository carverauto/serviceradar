defmodule ServiceRadar.Notifications.SeedFingerprintTest do
  @moduledoc """
  The divergence test is pure, so these tests are database-free and async.

  What is asserted here is the half that is easy to get subtly wrong and
  impossible to notice until an upgrade: the fingerprint has to survive the
  jsonb round-trip (atom keys and atom values go out, string keys and string
  values come back), or every managed row looks operator-edited on the very
  first boot after it was written and nothing is ever reconciled again.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.SeedFingerprint

  @fields [:display_name, :config_schema, :capabilities]

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        display_name: "Slack",
        config_schema: %{"type" => "object", "properties" => %{"mode" => %{"type" => "string"}}},
        capabilities: [:send, :test],
        default_max_attempts: 3
      },
      overrides
    )
  end

  describe "fingerprint/2" do
    test "is stable across the jsonb round-trip" do
      written = attrs()

      # What the row looks like coming back out of Postgres: the jsonb map keeps
      # string keys and the atom array casts back to atoms.
      read_back = %{
        display_name: "Slack",
        config_schema: %{"properties" => %{"mode" => %{"type" => "string"}}, "type" => "object"},
        capabilities: [:send, :test],
        default_max_attempts: 3
      }

      assert SeedFingerprint.fingerprint(written, @fields) ==
               SeedFingerprint.fingerprint(read_back, @fields)
    end

    test "hashes atom and string spellings of the same value identically" do
      assert SeedFingerprint.fingerprint(%{capabilities: [:send, :test]}, [:capabilities]) ==
               SeedFingerprint.fingerprint(%{capabilities: ["send", "test"]}, [:capabilities])
    end

    test "a missing key and an explicit nil hash identically" do
      assert SeedFingerprint.fingerprint(%{}, [:description]) ==
               SeedFingerprint.fingerprint(%{description: nil}, [:description])
    end

    test "changing a covered field changes the digest" do
      refute SeedFingerprint.fingerprint(attrs(), @fields) ==
               SeedFingerprint.fingerprint(attrs(%{display_name: "Slack (edited)"}), @fields)
    end

    test "changing a field outside the covered set does not" do
      assert SeedFingerprint.fingerprint(attrs(), @fields) ==
               SeedFingerprint.fingerprint(attrs(%{default_max_attempts: 10}), @fields)
    end

    test "list order is significant, because a reordered list is a different row" do
      refute SeedFingerprint.fingerprint(%{capabilities: [:send, :test]}, [:capabilities]) ==
               SeedFingerprint.fingerprint(%{capabilities: [:test, :send]}, [:capabilities])
    end

    test "is hex, so it fits a plain string column" do
      digest = SeedFingerprint.fingerprint(attrs(), @fields)

      assert String.length(digest) == 64
      assert digest =~ ~r/\A[0-9a-f]{64}\z/
    end
  end

  describe "diverged?/2" do
    test "a row still matching its stamp has not diverged" do
      row = Map.put(attrs(), :template_fingerprint, SeedFingerprint.fingerprint(attrs(), @fields))

      refute SeedFingerprint.diverged?(row, @fields)
    end

    test "an operator edit to a covered field diverges" do
      row =
        %{display_name: "Slack (NOC)"}
        |> attrs()
        |> Map.put(:template_fingerprint, SeedFingerprint.fingerprint(attrs(), @fields))

      assert SeedFingerprint.diverged?(row, @fields)
    end

    test "an edit outside the covered set does not diverge, so the row still reconciles" do
      row =
        %{default_max_attempts: 10}
        |> attrs()
        |> Map.put(:template_fingerprint, SeedFingerprint.fingerprint(attrs(), @fields))

      refute SeedFingerprint.diverged?(row, @fields)
    end

    test "a nil fingerprint is diverged, because nothing can be said about the row" do
      assert SeedFingerprint.diverged?(Map.put(attrs(), :template_fingerprint, nil), @fields)
    end
  end

  describe "matches_template?/3" do
    test "true when the row content already equals the shipped template" do
      assert SeedFingerprint.matches_template?(attrs(), attrs(), @fields)
    end

    test "false for a row whose covered content differs" do
      refute SeedFingerprint.matches_template?(attrs(%{display_name: "Other"}), attrs(), @fields)
    end

    test "ignores the stamp itself, so an unmanaged row can still be recognised" do
      row = Map.put(attrs(), :template_fingerprint, nil)

      assert SeedFingerprint.matches_template?(row, attrs(), @fields)
    end
  end
end
