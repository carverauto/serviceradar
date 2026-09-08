defmodule ServiceRadar.Automation.Ansible.AwxBindingReviewTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.AwxBindingReview

  setup do
    user = %{id: Ash.UUID.generate(), status: :active, role: :admin}

    request = %{
      "controller_id" => Ash.UUID.generate(),
      "template_id" => 23,
      "project_id" => 24,
      "inventory_id" => 25,
      "credential_ids" => [26],
      "execution_environment_id" => 27,
      "membership_ids" => [Ash.UUID.generate()],
      "machine_credential_id" => 26,
      "content_sha256" => String.duplicate("7", 64),
      "review_ticket" => "SYNTHETIC-REVIEW-1"
    }

    review = %{
      "attributes" => %{"job_template_id" => 23, "content_sha256" => String.duplicate("7", 64)},
      "approval_ttl_seconds" => 3600
    }

    deps = %{
      load_user: fn id ->
        assert id == user.id
        {:ok, user}
      end,
      load_authority: fn _ ->
        {:ok, %{permissions: MapSet.new(["ansible.controllers.manage"])}}
      end,
      fetch_review: fn _ ->
        send(self(), :server_read)
        {:ok, review}
      end,
      persist_review: fn attrs, reviewer ->
        send(self(), {:persisted, attrs, reviewer.id})
        {:ok, %{id: Ash.UUID.generate()}}
      end
    }

    %{request: request, user: user, deps: deps, review: review}
  end

  test "prepare and create independently read server facts and preserve the initiating reviewer",
       c do
    assert {:ok, prepared} =
             AwxBindingReview.prepare(c.request, %{user: c.user}, dependencies: c.deps)

    assert prepared.review == c.review
    assert_receive :server_read
    request = Map.put(c.request, "expected_review_digest", prepared.review_digest)

    assert {:ok, %{id: _}} =
             AwxBindingReview.create(request, %{user: c.user}, dependencies: c.deps)

    assert_receive :server_read
    assert_receive {:persisted, review, reviewer_id}
    assert review == c.review
    assert reviewer_id == c.user.id
  end

  test "changed server facts invalidate the displayed review", c do
    {:ok, prepared} = AwxBindingReview.prepare(c.request, c.user, dependencies: c.deps)
    changed = %{c.deps | fetch_review: fn _ -> {:ok, Map.put(c.review, "changed", true)} end}

    assert {:error, :binding_review_changed} =
             AwxBindingReview.create(
               Map.put(c.request, "expected_review_digest", prepared.review_digest),
               c.user,
               dependencies: changed
             )

    refute_receive {:persisted, _, _}
  end

  test "caller snapshots, approval identities and callback contracts are rejected", c do
    for key <- ~w(reviewed_launch_snapshot approval_id reviewed_by_principal_id callback_actions) do
      assert {:error, :unreviewed_request_fields} =
               AwxBindingReview.prepare(Map.put(c.request, key, "forged"), c.user,
                 dependencies: c.deps
               )
    end

    refute_receive :server_read
  end

  test "fresh permissions and active human identity are required", c do
    revoked = %{c.deps | load_authority: fn _ -> {:ok, %{permissions: MapSet.new()}} end}

    assert {:error, :current_permission_denied} =
             AwxBindingReview.prepare(c.request, c.user, dependencies: revoked)

    assert {:error, :current_permission_denied} =
             AwxBindingReview.prepare(
               c.request,
               Map.put(c.user, :principal_type, :service_principal),
               dependencies: c.deps
             )

    refute_receive :server_read
  end

  test "permission revoked during the live reads prevents approval persistence", c do
    {:ok, prepared} = AwxBindingReview.prepare(c.request, c.user, dependencies: c.deps)

    deps = %{
      c.deps
      | load_authority: fn user ->
          if Process.get(:synthetic_review_revoked),
            do: {:ok, %{permissions: MapSet.new()}},
            else: c.deps.load_authority.(user)
        end,
        fetch_review: fn _request ->
          Process.put(:synthetic_review_revoked, true)
          {:ok, c.review}
        end
    }

    request = Map.put(c.request, "expected_review_digest", prepared.review_digest)

    assert {:error, :current_permission_denied} =
             AwxBindingReview.create(request, c.user, dependencies: deps)

    refute_receive {:persisted, _, _}
  end

  test "invalid identifiers, unbounded TTL and malformed input contracts cannot issue reads", c do
    for {key, value} <- [
          {"template_id", "023"},
          {"template_id", %{}},
          {"approval_ttl_seconds", 86_401},
          {"input_schema", []}
        ] do
      assert {:error, :invalid_binding_review_request} =
               AwxBindingReview.prepare(Map.put(c.request, key, value), c.user,
                 dependencies: c.deps
               )
    end

    refute_receive :server_read
  end
end
