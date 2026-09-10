# Dialyzer false-positive exclusions for serviceradar_core.
#
# Adding an entry: every exclusion MUST be narrow (one file plus one warning
# class or message) and MUST carry a reason. Verify the warning is a false
# positive first: read the code, check the callers, confirm the types. Never
# add directory-wide suppressions, and never reshape production code
# (apply wrappers, opaque barriers, obscure runtime shapes) just to silence
# Dialyzer -- fix the typespec, or document the false positive here.
#
# The `{file, warning_atom}` form is what
# `mix dialyzer --format ignore_file` emits. It suppresses every warning of
# that class in that file, so only use it when each warning of that class in
# that file was inspected. The `{file, message}` form is narrower still and
# is preferred for one-off suppressions.
#
# Format notes (dialyxir 1.4.7): the default short format is authoritative
# for matching. `--format ignore_file_strict` crashes on this codebase
# (`{:error, :unknown_warning, :opaque_compare}`), so use `--format
# ignore_file` to generate candidate tuples, then curate -- never paste its
# whole output here.
#
# Unknown warning types: dialyxir 1.4.7 predates OTP 28 and does not know
# `:exact_compare` / `:opaque_compare`. `Dialyxir.Formatter.filter_warning/1`
# only attempts filtering for known warning types, so warnings of those two
# classes bypass this file entirely -- entries naming them never match and
# show up as unnecessary skips. Do not add them; upgrade dialyxir instead.
#
# Entry sections below group exclusions by false-positive class. Entries
# added or re-verified during the issue #222 cleanup carry an inline reason;
# older carried-over entries are grouped by class but individually
# unverified -- re-verify one when you touch its file and either document or
# drop it.
#
[
  # Ash/Spark framework inference. Ash builds actions, changesets, and
  # page structs dynamically, so Dialyzer's success typing for
  # AshResult/Ash.Page/Splode shapes routinely disagrees with reachable
  # defensive clauses. The actions work; most are covered by unit tests.
  {"lib/serviceradar/automation/ansible/ingestor_ash_actions.ex",
   "The pattern can never match the type \n  {:error,\n   %{\n     :__exception__ => true,\n     :__struct__ => atom(),\n     :bread_crumbs => [binary()],\n     :class => :forbidden | :framework | :invalid | :unknown,\n     :context => map(),\n     :stacktrace => nil | %Splode.Stacktrace{:stacktrace => [any()]},\n     :vars => [{_, _}],\n     atom() => _\n   }}\n  | {:ok, nil | struct()}\n."},
  {"lib/serviceradar/automation/ansible/northbound_bridge.ex",
   "The pattern can never match the type \n  {:error,\n   %{\n     :__exception__ => true,\n     :__struct__ => atom(),\n     :bread_crumbs => [binary()],\n     :class => :forbidden | :framework | :invalid | :unknown,\n     :context => map(),\n     :stacktrace => nil | %Splode.Stacktrace{:stacktrace => [any()]},\n     :vars => [{_, _}],\n     atom() => _\n   }}\n  | {:ok, nil | struct()}\n."},
  {"lib/serviceradar/automation/northbound/ansible_action_sync.ex",
   "The pattern can never match the type \n  {:error,\n   %{\n     :__exception__ => true,\n     :__struct__ => atom(),\n     :bread_crumbs => [binary()],\n     :class => :forbidden | :framework | :invalid | :unknown,\n     :context => map(),\n     :stacktrace => nil | %Splode.Stacktrace{:stacktrace => [any()]},\n     :vars => [{_, _}],\n     atom() => _\n   }}\n  | {:ok, nil | struct()}\n."},
  {"lib/serviceradar/automation/northbound/command_result_handler.ex",
   "The pattern can never match the type \n  {:error,\n   %{\n     :__exception__ => true,\n     :__struct__ => atom(),\n     :bread_crumbs => [binary()],\n     :class => :forbidden | :framework | :invalid | :unknown,\n     :context => map(),\n     :stacktrace => nil | %Splode.Stacktrace{:stacktrace => [any()]},\n     :vars => [{_, _}],\n     atom() => _\n   }}\n  | {:ok, nil | struct()}\n."},
  {"lib/serviceradar/automation/northbound/dispatcher.ex",
   "The pattern can never match the type \n  {:error,\n   %{\n     :__exception__ => true,\n     :__struct__ => atom(),\n     :bread_crumbs => [binary()],\n     :class => :forbidden | :framework | :invalid | :unknown,\n     :context => map(),\n     :stacktrace => nil | %Splode.Stacktrace{:stacktrace => [any()]},\n     :vars => [{_, _}],\n     atom() => _\n   }}\n  | {:ok, nil | struct()}\n."},
  {"lib/serviceradar/edge/agent_gateway_sync.ex",
   "The pattern can never match the type \n  {:error,\n   %{\n     :__exception__ => true,\n     :__struct__ => atom(),\n     :bread_crumbs => [any()],\n     :class => :forbidden | :framework | :invalid | :unknown,\n     :context => map(),\n     :stacktrace => nil | map(),\n     :vars => [any()],\n     atom() => _\n   }}\n  | {:ok,\n     [struct()]\n     | %{\n         :__struct__ => Ash.Page.Keyset | Ash.Page.Offset,\n         :count => integer(),\n         :limit => integer(),\n         :more? => boolean(),\n         :rerun => {map(), [any()]},\n         :results => [map()],\n         :after => nil | binary(),\n         :before => nil | binary(),\n         :offset => integer()\n       }}\n."},
  {"lib/serviceradar/edge/agent_gateway_sync.ex",
   "The pattern can never match the type \n  {:error,\n   %{\n     :__exception__ => true,\n     :__struct__ => atom(),\n     :bread_crumbs => [any()],\n     :class => :forbidden | :framework | :invalid | :unknown,\n     :context => map(),\n     :stacktrace => nil | map(),\n     :vars => [any()],\n     atom() => _\n   }}\n  | {:ok,\n     %{\n       :__struct__ => Ash.Page.Keyset | Ash.Page.Offset,\n       :count => integer(),\n       :limit => integer(),\n       :more? => boolean(),\n       :rerun => {map(), [any()]},\n       :results => [map()],\n       :after => nil | binary(),\n       :before => nil | binary(),\n       :offset => integer()\n     }}\n."},
  {"lib/serviceradar/identity/rbac.ex",
   "The pattern can never match the type \n  {:error,\n   :no_profile\n   | %{\n       :__exception__ => true,\n       :__struct__ => atom(),\n       :bread_crumbs => [binary()],\n       :class => :forbidden | :framework | :invalid | :unknown,\n       :context => map(),\n       :stacktrace => nil | %Splode.Stacktrace{:stacktrace => [any()]},\n       :vars => [{_, _}],\n       atom() => _\n     }}\n."},
  {"lib/serviceradar/inventory/identity/merge_engine.ex",
   "The pattern can never match the type \n  {:error,\n   %{\n     :__exception__ => true,\n     :__struct__ => atom(),\n     :bread_crumbs => [any()],\n     :class => :forbidden | :framework | :invalid | :unknown,\n     :context => map(),\n     :stacktrace => nil | map(),\n     :vars => [any()],\n     atom() => _\n   }}\n  | {:ok,\n     %{\n       :__struct__ => Ash.Page.Keyset | Ash.Page.Offset,\n       :count => integer(),\n       :limit => integer(),\n       :more? => boolean(),\n       :rerun => {map(), [any()]},\n       :results => [map()],\n       :after => nil | binary(),\n       :before => nil | binary(),\n       :offset => integer()\n     }}\n."},
  {"lib/serviceradar/observability/mtr_metrics_ingestor.ex",
   "The pattern can never match the type \n  {:ok, _,\n   [\n     %Ash.Notifier.Notification{\n       :action => _,\n       :actor => _,\n       :changeset => _,\n       :data => _,\n       :domain => _,\n       :for => _,\n       :from => _,\n       :metadata => _,\n       :resource => _\n     }\n   ]}\n."},
  {"lib/serviceradar/observability/mtr_metrics_ingestor.ex",
   "The pattern can never match the type \n  []\n  | %Ash.BulkResult{\n      :error_count => non_neg_integer(),\n      :errors => nil | [[any()] | map()],\n      :notifications => nil | [map()],\n      :records => nil | [map()],\n      :status => :partial_success\n    }\n."},

  # Opaque stdlib and struct types (MapSet internals, URI.authority/0).
  # Comparing or guarding on these values is correct at runtime.
  # Project rule: never work around opacity in production code.
  {"lib/serviceradar/identity/rbac.ex", "Type mismatch in call without opaque term in put."},
  {"lib/serviceradar/observability/mtr_automation_dispatcher.ex",
   "Type mismatch in call without opaque term in member?."},
  {"lib/serviceradar/observability/mtr_automation_dispatcher.ex",
   "Type mismatch in call with opaque term in collect_target_contexts."},
  {"lib/serviceradar/observability/mtr_automation_dispatcher.ex",
   "Type mismatch in call without opaque term in put."},

  # Verified (#222): is_binary/1 on URI.authority(); opaque stdlib type, never worked around per project rules.
  {"lib/serviceradar/plugins/proxmox_host_authority.ex", :opaque_guard},

  # Verified (#222): String.downcase/Regex.run on URI.authority(); same opaque-type false positive.
  {"lib/serviceradar/plugins/proxmox_host_authority.ex", :call_with_opaque},

  # Dead-code cascades. One inference failure (usually a framework
  # success-typing miss) marks a function no-return, which orphans its
  # whole call chain as unused_fun. Suppress the chain, not the code.
  {"lib/serviceradar/actors/telemetry.ex", "Function metrics/0 has no local return."},
  {"lib/serviceradar/automation/northbound/dispatcher.ex",
   "Function launch_ansible_run/4 has no local return."},
  {"lib/serviceradar/automation/northbound/dispatcher.ex",
   "The function call launch will not succeed."},
  {"lib/serviceradar/automation/northbound/dispatcher.ex",
   "Function mark_ansible_dispatched/3 will never be called."},
  {"lib/serviceradar/automation/northbound/dispatcher.ex",
   "Function mark_invocation_running/2 will never be called."},
  {"lib/serviceradar/camera/inventory_ingestor.ex",
   "Function camera_device_update_attrs/1 will never be called."},
  {"lib/serviceradar/edge/agent_gateway_sync.ex",
   "Function complete_agent_device_sync/5 has no local return."},
  {"lib/serviceradar/edge/agent_gateway_sync.ex",
   "The function call extract_strong_identifiers will not succeed."},
  {"lib/serviceradar/inventory/hypervisor_enrichment_ingestor.ex",
   "Function lookup_device_by_macs/3 has no local return."},
  {"lib/serviceradar/inventory/hypervisor_enrichment_ingestor.ex",
   "The function call extract_strong_identifiers will not succeed."},
  {"lib/serviceradar/network_discovery/mapper_results_ingestor.ex",
   "Function create_topology_candidate_device_for_ip/5 has no local return."},
  {"lib/serviceradar/network_discovery/mapper_results_ingestor.ex",
   "Function create_candidate_device_for_ip/4 has no local return."},
  {"lib/serviceradar/network_discovery/mapper_results_ingestor.ex",
   "Function create_device_for_ip/4 has no local return."},
  {"lib/serviceradar/network_discovery/mapper_results_ingestor.ex",
   "Function create_resolved_device_for_ip/8 will never be called."},
  {"lib/serviceradar/network_discovery/mapper_results_ingestor.ex",
   "Function resolve_device_uid_via_dire/4 has no local return."},
  {"lib/serviceradar/network_discovery/mapper_results_ingestor.ex",
   "The function call resolve_device_id will not succeed."},
  {"lib/serviceradar/network_discovery/mapper_results_ingestor.ex",
   "Function register_mapper_mac_identifiers/5 will never be called."},
  {"lib/serviceradar/network_discovery/mapper_results_ingestor.ex",
   "Function find_management_device_uid/3 will never be called."},
  {"lib/serviceradar/network_discovery/mapper_results_ingestor.ex",
   "Function ip_matches?/2 will never be called."},
  {"lib/serviceradar/network_discovery/mapper_results_ingestor.ex",
   "Function maybe_put/3 will never be called."},
  {"lib/serviceradar/network_discovery/mapper_results_ingestor.ex",
   "Function recover_existing_device_uid/4 will never be called."},
  {"lib/serviceradar/network_discovery/mapper_results_ingestor.ex",
   "Function recover_existing_device_uid_from_conflict/4 will never be called."},
  {"lib/serviceradar/network_discovery/mapper_results_ingestor.ex",
   "Function device_exists?/2 will never be called."},
  {"lib/serviceradar/telemetry/otel_setup.ex", "The function call add_handler will not succeed."},

  # Verified (#222): fire_schedule/2 calls the fail-closed RunLauncher seam; no-return is inferred, not real.
  {"lib/serviceradar/automation/ansible/schedule_evaluator_worker.ex", :no_return},

  # Verified (#222): RunLauncher.launch/2 spec requires a full intent; the seam accepts anything and fails closed.
  {"lib/serviceradar/automation/ansible/schedule_evaluator_worker.ex", :call},

  # Verified (#222): Dead with the contracted :proxmox_api-only mode; see Exact-comparison dead branches below.
  {"lib/serviceradar/plugins/proxmox_host_authority.ex",
   "Function int_value/2 will never be called."},

  # Defensive nil-fallback guards (`value || default`, `is_nil` checks).
  # Dialyzer narrows the value to non-nil from statically typed call
  # sites, but runtime data (DB rows, Ash structs, external payloads)
  # is still nilable. Removing the fallback would drop real nil-safety.
  {"lib/serviceradar/automation/northbound/dispatcher.ex", "The guard clause can never succeed."},
  {"lib/serviceradar/automation/northbound/plugin_action_sync.ex",
   "The guard clause can never succeed."},
  {"lib/serviceradar/cluster/cluster_health.ex", "The guard clause can never succeed."},
  {"lib/serviceradar/credentials/network_credential_rule_test_plan.ex",
   "The guard clause can never succeed."},
  {"lib/serviceradar/monitoring/alert.ex", "The guard clause can never succeed."},
  {"lib/serviceradar/monitoring/ocsf_event.ex", "The guard clause can never succeed."},
  {"lib/serviceradar/observability/threat_intel_plugin_ingestor.ex",
   "The guard clause can never succeed."},

  # Verified (#222): value/2 accepts atom and binary keys; is_binary/1 clause is defensive.
  {"lib/serviceradar/automation/ansible/awx_launch_preflight_attestation.ex", :guard_fail},

  # Verified (#222): settings.modes || [] guards a nilable Ash attribute Dialyzer narrowed from call sites.
  {"lib/serviceradar/composite_checks/validation/orchestrator.ex", :guard_fail},

  # Verified (#222): metadata || %{} guards nil metadata; defensive.
  {"lib/serviceradar/inventory/advisory_feeds/cve_priority.ex", :guard_fail},

  # Verified (#222): changeset.params || %{} guards a nilable field; defensive.
  {"lib/serviceradar/notifications/changes/apply_provider_contract.ex", :guard_fail},

  # Verified (#222): scope.alert || %{} guards a nilable field; defensive.
  {"lib/serviceradar/notifications/dispatcher.ex", :guard_fail},

  # Verified (#222): normalize_headers/1 accepts maps and lists; is_list/1 clause is live API, not dead code.
  {"lib/serviceradar/notifications/transports/http.ex", :guard_fail},

  # Verified (#222): seconds_to_ms/1 fallback clause for nil; defensive.
  {"lib/serviceradar/notifications/transports/slack.ex", :guard_fail_pat},

  # Verified (#222): `if actor` nil path is defensive; production always passes the system actor.
  {"lib/serviceradar/observability/netflow_exporter_cache_refresh_worker.ex", :guard_fail},

  # Verified (#222): credential_rule_id || "" guards a nilable rule field; defensive.
  {"lib/serviceradar/plugins/proxmox_host_authority.ex", :guard_fail},

  # Verified (#222): URI host/scheme || fallbacks; %URI{} fields are nilable, narrowed from call sites only.
  {"lib/serviceradar/prefix_tags/netbox_import_worker.ex", :guard_fail},

  # Exact-comparison dead branches. A comparison Dialyzer proves
  # constant, kept deliberately (contracted behavior or defence in
  # depth). These warnings bypass filtering; see the header note on
  # unknown warning types:
  # - device_metadata.ex:81 (`reason == :stale`; unknown/2 is never called
  #   with :stale today but resolution() admits it; defensive).
  # - proxmox_host_authority.ex:432,433,438 (`mode == :ssh`; mode is always
  #   :proxmox_api by construction, SSH keeps the PVE identity -- pinned by
  #   the "SSH console keeps the PVE controller identity" test).

  # Unreachable-clause narrowing. Dialyzer proves a later clause is
  # covered by earlier ones given inferred Ash/domain types. These are
  # carried over from the pre-#222 list; re-verify when touching the
  # file (many are defensive fallbacks for untyped runtime data).
  {"lib/serviceradar/actors/device.ex",
   "The pattern pattern {'error', _reason@1} can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/agent_config/compilers/mapper_compiler.ex",
   "The pattern pattern <__payload@1, __payload_keys@1> can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/automation/ansible/event_ingestor.ex",
   "The pattern variable _ can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/automation/ansible/retention_worker.ex",
   "The pattern can never match the type \n  {:ok,\n   %{:detail_runs_pruned => non_neg_integer(), :summary_runs_pruned => non_neg_integer()}}\n."},
  {"lib/serviceradar/automation/ansible/schedule_evaluator_worker.ex",
   "The pattern variable _other@1 can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/automation/northbound/command_result_handler.ex",
   "The pattern can never match the type true."},
  {"lib/serviceradar/automation/northbound/dispatcher.ex",
   "The pattern pattern <__invocation@1, __reason@1, __actor@1> can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/automation/northbound/event_handler_runner.ex",
   "The pattern pattern <__resolver@1, __context@1> can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/automation/northbound/event_handler_runner.ex",
   "The pattern pattern <__context@1, __path@1> can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/automation/northbound/invocation_service.ex",
   "The pattern pattern <__map@1, __key@1> can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/automation/northbound/poll_worker.ex",
   "The pattern can never match the type \n  {:error,\n   :canceled\n   | :expired\n   | %{\n       :__exception__ => true,\n       :__struct__ => atom(),\n       :bread_crumbs => [any()],\n       :class => :forbidden | :framework | :invalid | :unknown,\n       :context => map(),\n       :stacktrace => nil | map(),\n       :vars => [any()],\n       atom() => _\n     }}\n."},
  {"lib/serviceradar/camera/inventory_ingestor.ex",
   "The pattern pattern {_device@3 = \#{'__struct__':='Elixir.ServiceRadar.Inventory.Device'}, _target_uid@1} can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/camera/inventory_ingestor.ex",
   "The pattern variable _ can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/camera/inventory_ingestor.ex",
   "The pattern pattern <__device@1, __attrs@1> can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/camera/inventory_ingestor.ex",
   "The pattern variable __value@1 can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/camera/inventory_ingestor.ex",
   "The pattern variable __mac@1 can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/camera/inventory_ingestor.ex",
   "The pattern pattern <__descriptor@1, __actor@1> can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/cluster/coordinator_manager.ex",
   "The pattern can never match the type :ok | {:error, :not_found}."},
  {"lib/serviceradar/cluster/coordinator_manager.ex",
   "The pattern pattern {'error', __reason@1} can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/cluster/gateway_registration_worker.ex",
   "The pattern variable _error@1 can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/cluster/registration_worker.ex",
   "The pattern pattern {'error', _reason@2} can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/cluster/registration_worker.ex",
   "The pattern variable _ can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/cluster/startup_migrations.ex",
   "The pattern can never match the type {:error, _}."},
  {"lib/serviceradar/cluster/startup_migrations.ex",
   "The pattern can never match the type {:error, _} | {:ok, :ok | {:retry, map()}}."},
  {"lib/serviceradar/cluster/startup_migrations.ex",
   "The pattern variable _other@1 can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/cluster/startup_migrations.ex",
   "The pattern can never match the type {:error, _} | {:ok, {:retry, map()}}."},
  {"lib/serviceradar/core/result_processor.ex", "The pattern can never match the type true."},
  {"lib/serviceradar/credentials/ssh_private_key_credential.ex",
   "The pattern variable __value@1 can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/dashboards/package_import.ex",
   "The pattern can never match the type {:error, [binary()]}."},
  {"lib/serviceradar/dashboards/validations/manifest.ex",
   "The pattern can never match the type {:error, [binary()]}."},
  {"lib/serviceradar/edge/agent_config_generator.ex",
   "The pattern variable _ can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/edge/agent_config_generator.ex",
   "The pattern pattern <__map@1, __key@1> can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/edge/agent_config_generator.ex",
   "The pattern can never match the type map()."},
  {"lib/serviceradar/edge/agent_gateway_sync.ex",
   "The pattern pattern <__metadata@1, __key@1> can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/edge/agent_release_manager.ex",
   "The pattern variable __version@1 can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/edge/remote_access_broker.ex",
   "The pattern variable _frame_type@1 can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/edge/remote_access_file_transfers.ex",
   "The pattern variable _key@1 can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/edge/remote_access_file_transfers.ex",
   "The pattern variable _action@1 can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/edge/remote_access_host_keys.ex",
   "The pattern pattern <__map@1, __key@1> can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/edge/remote_access_requests.ex",
   "The pattern variable _action@1 can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/edge/remote_access_sessions.ex",
   "The pattern variable _error@2 can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/edge/remote_access_sessions.ex",
   "The pattern can never match the type \n  :remote_access_session_active\n  | :remote_access_session_attach\n  | :remote_access_session_close_requested\n  | :remote_access_session_closed\n  | :remote_access_session_create\n  | :remote_access_session_expired\n  | :remote_access_session_opening\n."},
  {"lib/serviceradar/edge/remote_access_sessions.ex",
   "The pattern can never match the type \n  :remote_access_session_active\n  | :remote_access_session_close_requested\n  | :remote_access_session_closed\n  | :remote_access_session_expired\n  | :remote_access_session_failed\n  | :remote_access_session_opening\n."},
  {"lib/serviceradar/edge/remote_access_sessions.ex",
   "The pattern variable _action@1 can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/edge/remote_access_ssh_identity_issuer.ex",
   "The pattern pattern <__container@1, __key@1> can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/edge/remote_access_ssh_principal_mapper.ex",
   "The pattern pattern <__map@1, __key@1> can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/edge/remote_access_ssh_session_credentials.ex",
   "The pattern pattern <__container@1, __key@1> can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/edge/remote_access_target_policy.ex",
   "The pattern variable __other@1 can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/edge/remote_access_target_policy.ex",
   "The pattern pattern <__map@1, __key@1> can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/event_writer/pipeline.ex",
   "The pattern pattern <_links@1, __link@1> can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/event_writer/pipeline.ex",
   "The pattern variable _ can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/event_writer/processors/default.ex",
   "The pattern can never match the type true."},
  {"lib/serviceradar/event_writer/processors/logs.ex",
   "The pattern pattern <__json@1, __resource_attributes@1> can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/event_writer/processors/sweep.ex",
   "The pattern variable _other@1 can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/events/health_writer.ex",
   "The pattern can never match the type 1 | 2 | 3 | 4."},
  {"lib/serviceradar/events/health_writer.ex",
   "The pattern variable _ can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/events/health_writer.ex",
   "The pattern variable _value@1 can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/events/internal_log_publisher.ex",
   "The pattern variable _value@1 can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/events/onboarding_writer.ex", "The pattern can never match the type 1 | 3."},
  {"lib/serviceradar/events/onboarding_writer.ex", "The pattern can never match the type 1."},
  {"lib/serviceradar/events/onboarding_writer.ex",
   "The pattern variable _ can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/inventory/active_fingerprint_payload.ex",
   "The pattern pattern <__map@1, __keys@1> can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/inventory/bumblebee_catalog_refresh_worker.ex",
   "The pattern can never match the type \n  {:error,\n   %{\n     :__exception__ => true,\n     :__struct__ => atom(),\n     :bread_crumbs => _,\n     :class => _,\n     :stacktrace => _,\n     :vars => _,\n     :context => map(),\n     atom() => _\n   }}\n  | {:ok, struct()}\n  | {:ok, struct(), [map()]}\n."},
  {"lib/serviceradar/inventory/bumblebee_catalog_refresh_worker.ex",
   "The pattern variable _key@1 can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/inventory/bumblebee_catalog_refresh_worker.ex",
   "The pattern variable __key@1 can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/inventory/bumblebee_ingestor.ex",
   "The pattern pattern <__map@1, __key@1, _default@1> can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/inventory/bumblebee_ingestor.ex",
   "The pattern pattern <__map@1, __key@1> can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/inventory/bumblebee_ingestor.ex",
   "The pattern variable __map@1 can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/inventory/device_enrichment_rules.ex",
   "The pattern variable _parsed@2 can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/inventory/device_enrichment_rules.ex",
   "The pattern variable _ can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/inventory/device_enrichment_rules.ex",
   "The pattern pattern <__branch@1, _label@1> can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/inventory/device_enrichment_rules.ex",
   "The pattern pattern <__ctx@1, _> can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/inventory/device_enrichment_rules.ex",
   "The pattern variable _value@1 can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/inventory/dpi_payload.ex",
   "The pattern pattern <__map@1, __keys@1> can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/inventory/endpoint_inventory_artifact_store.ex",
   "The pattern pattern <__map@1, __key@1> can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/inventory/endpoint_inventory_ingestor_queue.ex",
   "The pattern can never match the type {:ok, pid()}."},
  {"lib/serviceradar/inventory/endpoint_inventory_retention.ex",
   "The pattern can never match the type {:error, _}."},
  {"lib/serviceradar/inventory/hypervisor_enrichment_ingestor.ex",
   "The pattern variable __role@1 can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/inventory/hypervisor_enrichment_ingestor.ex",
   "The pattern pattern <__map@1, __key@1> can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/inventory/hypervisor_enrichment_ingestor.ex",
   "The pattern variable __value@1 can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/inventory/identity/ids.ex",
   "The pattern variable __metadata@1 can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/inventory/passive_fingerprint_payload.ex",
   "The pattern pattern <__metadata@1, __protocol@1> can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/inventory/passive_fingerprint_payload.ex",
   "The pattern pattern <__map@1, __keys@1> can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/inventory/sync/identifier_records.ex",
   "The pattern variable _ can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/inventory/sync/normalize.ex",
   "The pattern pattern <__metadata@1, __update@1> can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/inventory/sync_ingestor.ex",
   "The pattern pattern <__result@1, __resolved_updates@1, __actor@1> can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/inventory/sync_ingestor.ex",
   "The pattern can never match the type {:ok, :ok, :ok, :ok, :ok}."},
  {"lib/serviceradar/inventory/sync_ingestor_queue.ex",
   "The pattern can never match the type {:ok, pid()}."},
  {"lib/serviceradar/inventory/vulnerability_advisory_ingestor.ex",
   "The pattern variable __payload@1 can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/jobs/schedule_health_check.ex",
   "The pattern variable _other@1 can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/network_discovery/mapper_results_ingestor.ex",
   "The pattern can never match the type {:ok, _}."},
  {"lib/serviceradar/network_discovery/mapper_results_ingestor.ex",
   "The pattern can never match the type {:ok, binary()}."},
  {"lib/serviceradar/network_discovery/mapper_results_ingestor.ex",
   "The pattern variable __record@1 can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/observability/log_promotion.ex",
   "The pattern variable _ can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/observability/mtr_graph.ex",
   "The pattern pattern <__value@1, _default@1> can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/observability/netflow_oui_dataset_refresh_worker.ex",
   "The pattern can never match the type true."},
  {"lib/serviceradar/observability/stateful_alert_evaluation_queue.ex",
   "The pattern can never match the type {:ok, pid()}."},
  {"lib/serviceradar/observability/threat_intel_plugin_ingestor.ex",
   "The pattern pattern <__page@1, __payload@1, __actor@1, __observed_at@1> can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/observability/threat_intel_plugin_ingestor.ex",
   "The pattern pattern <__page@1, __indicator_attrs@1, __actor@1> can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/observability/zen_rule_seeder.ex",
   "The pattern variable _updated@2 can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/observability/zen_rule_sync.ex",
   "The pattern variable _unexpected@1 can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/otel/propagation.ex",
   "The pattern can never match the type %{\n  :attributes =>\n    [{_, _}] | %{atom() | binary() => atom() | binary() | [any()] | number() | tuple()},\n  :span_id => non_neg_integer(),\n  :trace_id => non_neg_integer(),\n  :tracestate => {:tracestate, [any()]}\n}."},
  {"lib/serviceradar/plugins/addon_profile_ops.ex",
   "The pattern variable _error@1 can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/plugins/native_addon_importer.ex",
   "The pattern variable _bytes@1 can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/plugins/secret_refs.ex",
   "The pattern variable __params@1 can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/plugins/secret_refs.ex",
   "The pattern variable __value@1 can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/snmp_profiles/credential_resolver.ex",
   "The pattern pattern <__payload@1, __record@1, __secret@1> can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/spiffe/workload_api.ex",
   "The pattern variable _other@1 can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/sweep_jobs/sweep_results_ingestor.ex",
   "The pattern variable __message@1 can never match the type, because it is covered by previous clauses."},
  {"lib/serviceradar/wifi_map/batch_ingestor.ex", "The pattern can never match the type :ok."},
  {"lib/serviceradar/wifi_map/batch_ingestor.ex",
   "The pattern variable _other@1 can never match the type, because it is covered by previous clauses."},

  # Vendored Erlang OTLP exporter code (src/). Not ours to fix; the
  # warnings come from generated protobuf/OTLP shapes.
  {"src/otel_exporter_logs_otlp.erl",
   "The pattern variable Batch can never match the type, because it is covered by previous clauses."},
  {"src/otel_exporter_logs_otlp.erl",
   "The pattern variable Req can never match the type, because it is covered by previous clauses."},
  {"src/otel_exporter_logs_otlp.erl",
   "The pattern variable _ can never match the type, because it is covered by previous clauses."},
  {"src/otel_exporter_logs_otlp.erl",
   "The pattern can never match the type {:grpc_status, binary()} | {:http_error, integer()} | {:export_error, _, _}."},
  {"src/otel_exporter_logs_otlp.erl",
   "The pattern can never match the type {:grpc_status, binary()} | {:export_error, _, _}."},
  {"src/otel_exporter_logs_otlp.erl",
   "The pattern can never match the type \n  {:grpc_status, binary()} | {:http_error, integer()} | {:export_error, _, _},\n  _,\n  [\n    %{\n      :host => binary() | maybe_improper_list(any(), binary() | []),\n      :scheme => binary() | maybe_improper_list(any(), binary() | []),\n      :path => binary() | maybe_improper_list(any(), binary() | []),\n      :port => integer(),\n      :ssl_options => []\n    }\n  ],\n  :gzip | :undefined\n."},
  {"src/serviceradar_otel_exporter_traces_otlp.erl",
   "The pattern variable _ can never match the type, because it is covered by previous clauses."}
]
