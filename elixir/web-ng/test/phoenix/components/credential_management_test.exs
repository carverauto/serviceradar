defmodule ServiceRadarWebNGWeb.Components.CredentialManagementTest do
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Socket
  alias ServiceRadar.Credentials.CredentialUsage.Consumer
  alias ServiceRadar.Credentials.CredentialUsage.Result
  alias ServiceRadarWebNGWeb.Settings.NetworkCredentialRulesLive
  alias ServiceRadarWebNGWeb.Settings.NetworkCredentialRulesLive.CredentialManagement

  @moduletag :db_free

  test "opening every management flow uses fresh authority and a public reload" do
    for operation <- [:edit, :rotate, :delete] do
      assert {:ok, opened} =
               CredentialManagement.open(operation, stale_scope(), "credential-1", dependencies: dependencies())

      assert opened.secret.name == "Fresh credential"
      assert opened.scope.fresh_authority == true
    end
  end

  test "edit details forwards only name and description after a fresh reload" do
    params = %{
      "name" => "Renamed credential",
      "description" => "Safe description",
      "provider" => "forged-provider",
      "secret_payload" => "ui-secret-marker-edit"
    }

    assert {:ok, updated} =
             CredentialManagement.edit_details(stale_scope(), "credential-1", params, dependencies: dependencies())

    assert updated.name == "Renamed credential"
    assert updated.description == "Safe description"
    refute inspect(updated) =~ "ui-secret-marker-edit"
    assert updated.provider == "snmp"
  end

  test "rotation resolves the current descriptor and returns no submitted material" do
    marker = "ui-secret-marker-management-rotation"

    assert {:ok, opened} =
             CredentialManagement.open(:rotate, stale_scope(), "credential-1", dependencies: dependencies())

    assert opened.descriptor.method["id"] == "v3"

    assert {:ok, rotated} =
             CredentialManagement.rotate(
               stale_scope(),
               "credential-1",
               %{"username" => "operator", "auth_password" => marker},
               dependencies: dependencies()
             )

    assert rotated.rotation_state == :active
    refute inspect(rotated) =~ marker
  end

  test "legacy rotation infers exactly one descriptor method matching the stored kind" do
    legacy_secret = %{secret() | metadata: %{}}

    current_profile =
      put_in(profile()["auth_methods"], [
        hd(profile()["auth_methods"]),
        %{
          "id" => "api_token",
          "label" => "API token",
          "credential_kind" => "api_token",
          "fields" => []
        }
      ])

    legacy_dependencies =
      dependencies(%{
        load_secret: fn "credential-1", %{fresh_authority: true} ->
          {:ok, legacy_secret}
        end,
        profile_for: fn "snmp" -> {:ok, current_profile} end
      })

    assert {:ok, %{descriptor: %{method: %{"id" => "v3"}}}} =
             CredentialManagement.open(
               :rotate,
               stale_scope(),
               "credential-1",
               dependencies: legacy_dependencies
             )
  end

  test "ambiguous, partial, and stale legacy descriptor metadata fail closed" do
    second_snmp_method = %{
      "id" => "community",
      "label" => "Community",
      "credential_kind" => "snmp",
      "fields" => []
    }

    ambiguous_profile =
      update_in(profile()["auth_methods"], &(&1 ++ [second_snmp_method]))

    cases = [
      {%{secret() | metadata: %{}}, ambiguous_profile},
      {%{secret() | metadata: %{"auth_method" => "v3"}}, profile()},
      {%{secret() | metadata: %{"credential_descriptor" => "package_manifest.v1"}}, profile()},
      {%{
         secret()
         | metadata: %{
             "credential_descriptor" => "stale.v0",
             "auth_method" => "v3"
           }
       }, profile()}
    ]

    for {candidate_secret, candidate_profile} <- cases do
      candidate_dependencies =
        dependencies(%{
          load_secret: fn "credential-1", %{fresh_authority: true} ->
            {:ok, candidate_secret}
          end,
          profile_for: fn "snmp" -> {:ok, candidate_profile} end
        })

      assert {:error, :credential_descriptor_unavailable} =
               CredentialManagement.open(
                 :rotate,
                 stale_scope(),
                 "credential-1",
                 dependencies: candidate_dependencies
               )
    end
  end

  test "forged nested rotation values are rejected without retaining their marker" do
    marker = "ui-secret-marker-nested-rotation"
    test_pid = self()

    nested_dependencies =
      dependencies(%{
        authorize_current: fn %{fresh_authority: false} = scope, "settings.credentials.manage" ->
          send(test_pid, :nested_rotation_authorized)
          {:ok, %{scope | fresh_authority: true}}
        end,
        rotate: fn _secret, _values, _scope ->
          send(test_pid, :unexpected_nested_rotation)
          {:ok, secret()}
        end
      })

    socket = %Socket{
      assigns: %{__changed__: %{}, current_scope: stale_scope()},
      private: %{
        live_temp: %{},
        credential_management_opts: [dependencies: nested_dependencies]
      }
    }

    assert {:noreply, updated_socket} =
             NetworkCredentialRulesLive.handle_event(
               "save_credential_rotation",
               %{
                 "credential_rotation" => %{
                   "id" => "credential-1",
                   "fields" => %{"token" => %{"nested" => marker}}
                 }
               },
               socket
             )

    assert_received :nested_rotation_authorized
    refute_received :unexpected_nested_rotation
    assert updated_socket.assigns.credential_action_error == "Credential rotation failed"
    refute inspect(updated_socket.assigns) =~ marker
  end

  test "revoked permission is checked before rejecting forged nested rotation values" do
    marker = "ui-secret-marker-revoked-nested-rotation"
    test_pid = self()

    revoked_dependencies =
      dependencies(%{
        authorize_current: fn %{fresh_authority: false}, "settings.credentials.manage" ->
          send(test_pid, :fresh_authority_checked)
          {:error, :permission_revoked}
        end,
        load_secret: fn _id, _scope ->
          send(test_pid, :unexpected_secret_reload)
          {:ok, secret()}
        end,
        rotate: fn _secret, _values, _scope ->
          send(test_pid, :unexpected_rotation)
          {:ok, secret()}
        end
      })

    socket = %Socket{
      assigns: %{__changed__: %{}, current_scope: stale_scope(), flash: %{}},
      private: %{
        live_temp: %{},
        credential_management_opts: [dependencies: revoked_dependencies]
      }
    }

    assert {:noreply, updated_socket} =
             NetworkCredentialRulesLive.handle_event(
               "save_credential_rotation",
               %{
                 "credential_rotation" => %{
                   "id" => "credential-1",
                   "fields" => %{"token" => %{"nested" => marker}}
                 }
               },
               socket
             )

    assert_received :fresh_authority_checked
    refute_received :unexpected_secret_reload
    refute_received :unexpected_rotation
    assert {:redirect, %{to: "/settings/profile"}} = updated_socket.redirected
    refute inspect(updated_socket.assigns) =~ marker
  end

  test "delete opening and confirmation both fail closed on fresh usage" do
    used_dependencies =
      dependencies(%{
        usage_for_secret: fn "credential-1", %{fresh_authority: true} ->
          {:ok,
           %Result{
             consumers: [
               %Consumer{kind: :snmp_profile, id: "profile-1", label: "Default SNMP"}
             ],
             live_grants: []
           }}
        end,
        destroy: fn _secret, _confirmation_id, _scope ->
          raise "destroy must not run while usage is non-empty"
        end
      })

    assert {:ok, %{usage: %Result{consumers: [_consumer]}}} =
             CredentialManagement.open(:delete, stale_scope(), "credential-1", dependencies: used_dependencies)

    assert {:error, :credential_in_use, %{usage: %Result{consumers: [_consumer]}}} =
             CredentialManagement.delete(
               stale_scope(),
               "credential-1",
               "credential-1",
               dependencies: used_dependencies
             )
  end

  test "unused deletion passes exact identity confirmation to permanent destroy" do
    assert {:ok, :deleted} =
             CredentialManagement.delete(
               stale_scope(),
               "credential-1",
               "credential-1",
               dependencies: dependencies()
             )

    assert {:error, :credential_confirmation_mismatch} =
             CredentialManagement.delete(
               stale_scope(),
               "credential-1",
               "wrong-id",
               dependencies: dependencies()
             )
  end

  test "an unavailable fresh usage check never calls permanent destroy" do
    unavailable_dependencies =
      dependencies(%{
        usage_for_secret: fn "credential-1", %{fresh_authority: true} ->
          {:error, {:credential_usage_unavailable, :snmp_profiles}}
        end,
        destroy: fn _secret, _confirmation_id, _scope ->
          raise "destroy must not run while usage is unavailable"
        end
      })

    assert {:error, :credential_usage_unavailable, %{secret: %{id: "credential-1"}}} =
             CredentialManagement.delete(
               stale_scope(),
               "credential-1",
               "credential-1",
               dependencies: unavailable_dependencies
             )
  end

  test "transaction-time unavailable usage replaces the stale unused delete context" do
    unavailable_dependencies =
      dependencies(%{
        destroy: fn _secret, _confirmation_id, _scope ->
          {:error, RuntimeError.exception("credential_usage_unavailable")}
        end
      })

    assert {:error, :credential_usage_unavailable, %{usage: :unavailable}} =
             CredentialManagement.delete(
               stale_scope(),
               "credential-1",
               "credential-1",
               dependencies: unavailable_dependencies
             )
  end

  test "batched inventory usage preserves unavailable instead of inventing zero" do
    secrets = [%{id: "credential-1"}, %{id: "credential-2"}]

    assert {:ok, usage_by_id} =
             CredentialManagement.usage_for_secrets(stale_scope(), secrets, dependencies: dependencies())

    assert Map.keys(usage_by_id) == ["credential-1", "credential-2"]

    unavailable_dependencies =
      dependencies(%{
        usage_for_secrets: fn ["credential-1", "credential-2"], %{fresh_authority: false} ->
          {:error, {:credential_usage_unavailable, :bindings}}
        end
      })

    assert {:error, :credential_usage_unavailable} =
             CredentialManagement.usage_for_secrets(stale_scope(), secrets, dependencies: unavailable_dependencies)
  end

  defp stale_scope do
    %{user: %{id: "user-1"}, fresh_authority: false}
  end

  defp dependencies(overrides \\ %{}) do
    Map.merge(
      %{
        authorize_current: fn %{fresh_authority: false} = scope, "settings.credentials.manage" ->
          {:ok, %{scope | fresh_authority: true}}
        end,
        load_secret: fn "credential-1", %{fresh_authority: true} ->
          {:ok, secret()}
        end,
        profile_for: fn "snmp" -> {:ok, profile()} end,
        usage_for_secret: fn "credential-1", %{fresh_authority: true} ->
          {:ok, %Result{consumers: [], live_grants: []}}
        end,
        usage_for_secrets: fn ids, %{fresh_authority: false} ->
          {:ok,
           Map.new(ids, fn id ->
             {id, %Result{consumers: [], live_grants: []}}
           end)}
        end,
        edit_details: fn secret, %{name: name, description: description} = attrs, %{fresh_authority: true} ->
          if attrs |> Map.keys() |> Enum.sort() != [:description, :name] do
            raise "unsafe edit attributes"
          end

          {:ok, %{secret | name: name, description: description}}
        end,
        rotate: fn secret, %{"username" => "operator"} = attrs, %{fresh_authority: true} ->
          _replacement = Map.fetch!(attrs, "auth_password")
          {:ok, %{secret | username: "operator", rotation_state: :active}}
        end,
        destroy: fn %{id: "credential-1"}, confirmation_id, %{fresh_authority: true} ->
          if confirmation_id == "credential-1",
            do: {:ok, :deleted},
            else: {:error, :credential_confirmation_mismatch}
        end
      },
      overrides
    )
  end

  defp secret do
    %{
      id: "credential-1",
      name: "Fresh credential",
      description: nil,
      provider: "snmp",
      credential_kind: :snmp,
      source_type: :internal_encrypted,
      rotation_state: :active,
      metadata: %{"credential_descriptor" => "package_manifest.v1", "auth_method" => "v3"},
      username: nil,
      public_fingerprint: nil
    }
  end

  defp profile do
    %{
      "provider" => "snmp",
      "auth_methods" => [
        %{
          "id" => "v3",
          "label" => "SNMPv3 user",
          "credential_kind" => "snmp",
          "fields" => [
            %{
              "id" => "username",
              "label" => "Username",
              "control" => "text",
              "required" => true,
              "secret" => false
            },
            %{
              "id" => "auth_password",
              "label" => "Authentication password",
              "control" => "password",
              "required" => true,
              "secret" => true
            }
          ]
        }
      ]
    }
  end
end
