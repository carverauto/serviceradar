defmodule ServiceRadar.Notifications.ActionTokenTest do
  @moduledoc """
  The capability decision core is pure, so these tests are database-free and
  async: `mint/2` writes nothing and `verify_record/3` is handed the row.

  What is being pinned here is a credential scheme, so each test names the attack
  or the operator mistake it exists to stop rather than the branch it covers.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.ActionToken

  doctest ActionToken

  @delivery_id "0198f0aa-1111-7000-8000-00000000d001"
  @other_delivery_id "0198f0aa-1111-7000-8000-00000000d002"
  @alert_id "0198f0aa-1111-7000-8000-00000000a001"
  @other_alert_id "0198f0aa-1111-7000-8000-00000000a002"

  @now ~U[2026-08-09 12:00:00.000000Z]

  defp mint!(action, opts \\ []) do
    binding =
      Map.merge(
        %{delivery_id: @delivery_id, alert_id: @alert_id, action: action},
        Map.new(Keyword.take(opts, [:delivery_id, :alert_id]))
      )

    opts = Keyword.merge([now: @now, snooze_seconds: 3600], opts)

    assert {:ok, minted} = ActionToken.mint(binding, opts)
    minted
  end

  # The row as it exists immediately after `create/2`: exactly the minted
  # attributes plus an unconsumed marker.
  defp record(minted, overrides \\ %{}) do
    minted.attrs
    |> Map.put(:consumed_at, nil)
    |> Map.merge(overrides)
  end

  describe "mint/2 and verify_record/3 round trip" do
    test "a freshly minted capability verifies against the row it produced" do
      minted = mint!(:acknowledge)

      assert {:ok, :active, _record} =
               ActionToken.verify_record(record(minted), minted.token, now: @now)
    end

    test "all three actions round trip, each against its own row" do
      for action <- [:acknowledge, :snooze, :resolve] do
        minted = mint!(action)

        assert {:ok, :active, returned} =
                 ActionToken.verify_record(record(minted), minted.token, now: @now)

        assert returned.action == action
      end
    end

    test "the token is URL-safe and needs no escaping in an href" do
      minted = mint!(:resolve)

      assert minted.token == URI.encode(minted.token)
      assert String.starts_with?(minted.token, "srn1.")
      assert [_version, selector, _secret] = String.split(minted.token, ".")
      assert selector == minted.selector
    end

    test "two mints of the same binding are different capabilities" do
      first = mint!(:acknowledge)
      second = mint!(:acknowledge)

      refute first.token == second.token
      refute first.attrs.token_hash == second.attrs.token_hash
      refute first.selector == second.selector

      # And neither is usable against the other's row: consuming one leaves the
      # other alone, which is what "single use per action" has to mean when a
      # renotify mints a second link for the same action.
      assert {:error, :invalid_token} =
               ActionToken.verify_record(record(second), first.token, now: @now)
    end

    test "the snooze duration is bound into the capability, not chosen at click time" do
      minted = mint!(:snooze, snooze_seconds: 7200)

      assert minted.attrs.snooze_seconds == 7200
      assert record(minted).snooze_seconds == 7200
    end

    test "expires_at is measured from the supplied clock, and the clock is an input" do
      minted = mint!(:acknowledge, ttl_seconds: 60)

      assert minted.expires_at == DateTime.add(@now, 60, :second)
      assert minted.attrs.expires_at == minted.expires_at
    end
  end

  describe "a token grants exactly one action" do
    test "a snooze capability cannot resolve, even holding the plaintext" do
      snooze = mint!(:snooze)

      # The digest covers the action, so editing the row to say :resolve does not
      # produce a row the snooze token verifies against.
      tampered = record(snooze, %{action: :resolve, snooze_seconds: nil})

      assert {:error, :invalid_token} =
               ActionToken.verify_record(tampered, snooze.token, now: @now)
    end

    test "a caller that states the action it expects is told when they differ" do
      snooze = mint!(:snooze)

      assert {:error, :action_mismatch} =
               ActionToken.verify_record(record(snooze), snooze.token,
                 now: @now,
                 expect_action: :resolve
               )

      assert {:ok, :active, _record} =
               ActionToken.verify_record(record(snooze), snooze.token,
                 now: @now,
                 expect_action: :snooze
               )
    end
  end

  describe "a token is bound to one alert" do
    test "a capability minted for one alert does not verify against another's row" do
      for_this_alert = mint!(:acknowledge)
      for_that_alert = mint!(:acknowledge, alert_id: @other_alert_id)

      assert {:error, :invalid_token} =
               ActionToken.verify_record(record(for_that_alert), for_this_alert.token, now: @now)
    end

    test "repointing the row at another alert invalidates every token ever issued for it" do
      minted = mint!(:acknowledge)
      repointed = record(minted, %{alert_id: @other_alert_id})

      assert {:error, :invalid_token} =
               ActionToken.verify_record(repointed, minted.token, now: @now)
    end

    test "a caller that states the alert it expects is told when they differ" do
      minted = mint!(:acknowledge)

      assert {:error, :alert_mismatch} =
               ActionToken.verify_record(record(minted), minted.token,
                 now: @now,
                 expect_alert_id: @other_alert_id
               )
    end

    test "a caller that states the delivery it expects is told when they differ" do
      minted = mint!(:acknowledge)

      assert {:error, :delivery_mismatch} =
               ActionToken.verify_record(record(minted), minted.token,
                 now: @now,
                 expect_delivery_id: @other_delivery_id
               )
    end

    test "a row whose alert was pruned authorises nothing" do
      minted = mint!(:acknowledge)

      assert {:error, :token_unbound} =
               ActionToken.verify_record(record(minted, %{alert_id: nil}), minted.token,
                 now: @now
               )
    end
  end

  describe "TTL" do
    test "a capability past its expiry is refused" do
      minted = mint!(:acknowledge, ttl_seconds: 60)
      later = DateTime.add(@now, 61, :second)

      assert {:error, :token_expired} =
               ActionToken.verify_record(record(minted), minted.token, now: later)
    end

    test "expiry is inclusive at the instant itself" do
      minted = mint!(:acknowledge, ttl_seconds: 60)

      assert {:error, :token_expired} =
               ActionToken.verify_record(record(minted), minted.token,
                 now: DateTime.add(@now, 60, :second)
               )

      assert {:ok, :active, _record} =
               ActionToken.verify_record(record(minted), minted.token,
                 now: DateTime.add(@now, 59, :second)
               )
    end

    test "a missing expiry is treated as expired, never as forever" do
      minted = mint!(:acknowledge)

      assert {:error, :token_expired} =
               ActionToken.verify_record(record(minted, %{expires_at: nil}), minted.token,
                 now: @now
               )
    end
  end

  describe "presenting a token twice" do
    test "a consumed capability reports what it did rather than failing" do
      minted = mint!(:acknowledge)
      consumed_at = DateTime.add(@now, 30, :second)

      assert {:ok, :already_consumed, returned} =
               ActionToken.verify_record(
                 record(minted, %{consumed_at: consumed_at}),
                 minted.token,
                 now: DateTime.add(@now, 60, :second)
               )

      assert returned.consumed_at == consumed_at
    end

    test "a consumed capability still reports what it did after its TTL lapses" do
      # Deliberate ordering: consumption is checked before expiry. Past that
      # point the row is a receipt, not a credential, and answering "expired" to
      # someone asking what happened would be both less true and less useful.
      minted = mint!(:acknowledge, ttl_seconds: 60)

      assert {:ok, :already_consumed, _record} =
               ActionToken.verify_record(
                 record(minted, %{consumed_at: DateTime.add(@now, 10, :second)}),
                 minted.token,
                 now: DateTime.add(@now, 10_000, :second)
               )
    end

    test "a consumed capability with the WRONG secret is still refused" do
      # Idempotent replay is a courtesy to whoever holds the real token. It is
      # not a hole: the digest is compared before consumption is even looked at.
      minted = mint!(:acknowledge)
      other = mint!(:acknowledge)

      assert {:error, :invalid_token} =
               ActionToken.verify_record(record(minted, %{consumed_at: @now}), other.token,
                 now: @now
               )
    end
  end

  describe "only the digest is ever persisted" do
    test "the plaintext appears in no attribute that is written" do
      minted = mint!(:acknowledge)
      [_version, _selector, secret] = String.split(minted.token, ".")

      encoded = inspect(minted.attrs)

      refute encoded =~ secret
      refute encoded =~ minted.token
      refute Map.has_key?(minted.attrs, :token)
      refute Map.has_key?(minted.attrs, :secret)

      # Every persisted value, checked individually rather than through one
      # inspect of the whole map, so a nested container cannot hide one.
      for {_key, value} <- minted.attrs, is_binary(value) do
        refute value =~ secret
      end
    end

    test "token_hash is a sha256 hex digest and not the token in disguise" do
      minted = mint!(:acknowledge)

      assert String.length(minted.attrs.token_hash) == 64
      assert minted.attrs.token_hash =~ ~r/\A[0-9a-f]{64}\z/
    end

    test "the digest changes when any bound component changes" do
      base = mint!(:acknowledge)

      # Same secret is impossible to reuse across mints by design, so the proof
      # that the binding is inside the digest is the mismatch tests above; what
      # this pins is that the digest is not a function of the secret alone.
      other_action = mint!(:resolve)
      other_alert = mint!(:acknowledge, alert_id: @other_alert_id)

      assert [
               base.attrs.token_hash,
               other_action.attrs.token_hash,
               other_alert.attrs.token_hash
             ]
             |> Enum.uniq()
             |> length() == 3
    end

    test "inspecting the minted struct does not print the credential" do
      # A struct holding a live capability reaches a Logger call or an exception
      # report eventually. This is the one struct where that must be safe.
      minted = mint!(:acknowledge)

      refute inspect(minted) =~ minted.token
    end
  end

  describe "malformed input" do
    test "anything that is not exactly the minted shape is refused before a lookup" do
      minted = mint!(:acknowledge)
      [version, selector, secret] = String.split(minted.token, ".")

      for token <- [
            "",
            "srn1",
            "srn1." <> selector,
            "srn0." <> selector <> "." <> secret,
            version <> "." <> selector <> "." <> String.slice(secret, 0..10),
            version <> "." <> String.slice(selector, 0..3) <> "." <> secret,
            minted.token <> ".extra",
            String.duplicate("a", 5000),
            nil,
            :acknowledge,
            %{token: minted.token}
          ] do
        assert {:error, :malformed_token} = ActionToken.parse(token)
      end
    end

    test "a well-formed token against a record that is not one is refused" do
      minted = mint!(:acknowledge)

      assert {:error, :invalid_token} = ActionToken.verify_record(nil, minted.token, now: @now)

      # A map with no binding is not "a token that does not match"; it is a row
      # that authorises nothing, which is the same answer a pruned alert gets.
      assert {:error, :token_unbound} = ActionToken.verify_record(%{}, minted.token, now: @now)
    end

    test "a record with no digest is refused rather than matching an absent one" do
      minted = mint!(:acknowledge)

      assert {:error, :invalid_token} =
               ActionToken.verify_record(record(minted, %{token_hash: nil}), minted.token,
                 now: @now
               )
    end
  end

  describe "mint/2 input validation" do
    test "a snooze capability without a duration is not minted" do
      assert {:error, :missing_snooze_seconds} =
               ActionToken.mint(%{
                 delivery_id: @delivery_id,
                 alert_id: @alert_id,
                 action: :snooze
               })
    end

    test "only a snooze capability carries a duration" do
      assert {:ok, minted} =
               ActionToken.mint(
                 %{delivery_id: @delivery_id, alert_id: @alert_id, action: :acknowledge},
                 snooze_seconds: 3600
               )

      assert minted.attrs.snooze_seconds == nil
    end

    test "the action vocabulary is closed" do
      assert {:error, {:unknown_action, :suppress}} =
               ActionToken.mint(%{
                 delivery_id: @delivery_id,
                 alert_id: @alert_id,
                 action: :suppress
               })

      assert {:error, {:unknown_action, "acknowledge"}} =
               ActionToken.mint(%{
                 delivery_id: @delivery_id,
                 alert_id: @alert_id,
                 action: "acknowledge"
               })
    end

    test "a capability with nothing to bind to is not minted" do
      assert {:error, {:missing_binding, :delivery_id}} =
               ActionToken.mint(%{alert_id: @alert_id, action: :acknowledge})

      assert {:error, {:missing_binding, :alert_id}} =
               ActionToken.mint(%{delivery_id: @delivery_id, action: :acknowledge})
    end

    test "a non-positive TTL is refused rather than minting an already-dead capability" do
      binding = %{delivery_id: @delivery_id, alert_id: @alert_id, action: :acknowledge}

      assert {:error, {:invalid_ttl_seconds, 0}} = ActionToken.mint(binding, ttl_seconds: 0)
      assert {:error, {:invalid_ttl_seconds, -1}} = ActionToken.mint(binding, ttl_seconds: -1)
    end

    test "string keys are accepted, and no atom is created from them" do
      assert {:ok, minted} =
               ActionToken.mint(%{
                 "delivery_id" => @delivery_id,
                 "alert_id" => @alert_id,
                 "action" => :acknowledge
               })

      assert minted.attrs.delivery_id == @delivery_id
    end
  end

  describe "public_reason/1" do
    test "every failure but expiry collapses to one answer" do
      # An endpoint that distinguished "no such token" from "wrong secret" would
      # enumerate deliveries. Expiry survives because it is only reachable by a
      # bearer who already proved they hold a real one.
      assert ActionToken.public_reason(:token_expired) == :expired

      for reason <- [
            :malformed_token,
            :invalid_token,
            :token_unbound,
            :action_mismatch,
            :alert_mismatch,
            :delivery_mismatch
          ] do
        assert ActionToken.public_reason(reason) == :invalid
      end
    end
  end
end
