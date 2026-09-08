defmodule ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.Config do
  @moduledoc false

  @command_type_mtr_run "mtr.run"
  @command_type_mtr_bulk_run "mtr.bulk_run"
  @protocol_icmp "icmp"
  @protocol_udp "udp"
  @protocol_tcp "tcp"
  @execution_profile_fast "fast"
  @execution_profile_balanced "balanced"
  @execution_profile_deep "deep"
  @payload_target_key "target"
  @payload_targets_key "targets"
  @payload_agent_id_key "agent_id"
  @payload_elapsed_ms_key "elapsed_ms"
  @payload_target_ip_key "target_ip"
  @payload_check_name_key "check_name"
  @payload_ip_version_key "ip_version"
  @payload_targets_per_minute_key "targets_per_minute"
  @payload_duration_ms_key "duration_ms"
  @payload_concurrency_key "concurrency"
  @payload_max_concurrency_key "max_concurrency"
  @payload_concurrency_history_key "concurrency_history"
  @payload_total_targets_key "total_targets"
  @payload_completed_targets_key "completed_targets"
  @payload_failed_targets_key "failed_targets"
  @payload_running_targets_key "running_targets"
  @payload_timed_out_targets_key "timed_out_targets"
  @payload_protocol_key "protocol"
  @payload_execution_profile_key "execution_profile"
  @payload_target_query_key "target_query"
  @payload_selector_limit_key "selector_limit"
  @default_limit 25
  @max_limit 200

  def command_type_mtr_run, do: @command_type_mtr_run
  def command_type_mtr_bulk_run, do: @command_type_mtr_bulk_run
  def protocol_icmp, do: @protocol_icmp
  def protocol_udp, do: @protocol_udp
  def protocol_tcp, do: @protocol_tcp
  def protocols, do: [@protocol_icmp, @protocol_udp, @protocol_tcp]
  def execution_profile_fast, do: @execution_profile_fast
  def execution_profile_balanced, do: @execution_profile_balanced
  def execution_profile_deep, do: @execution_profile_deep
  def execution_profiles, do: [@execution_profile_fast, @execution_profile_balanced, @execution_profile_deep]
  def payload_target_key, do: @payload_target_key
  def payload_targets_key, do: @payload_targets_key
  def payload_agent_id_key, do: @payload_agent_id_key
  def payload_elapsed_ms_key, do: @payload_elapsed_ms_key
  def payload_target_ip_key, do: @payload_target_ip_key
  def payload_check_name_key, do: @payload_check_name_key
  def payload_ip_version_key, do: @payload_ip_version_key
  def payload_targets_per_minute_key, do: @payload_targets_per_minute_key
  def payload_duration_ms_key, do: @payload_duration_ms_key
  def payload_concurrency_key, do: @payload_concurrency_key
  def payload_max_concurrency_key, do: @payload_max_concurrency_key
  def payload_concurrency_history_key, do: @payload_concurrency_history_key
  def payload_total_targets_key, do: @payload_total_targets_key
  def payload_completed_targets_key, do: @payload_completed_targets_key
  def payload_failed_targets_key, do: @payload_failed_targets_key
  def payload_running_targets_key, do: @payload_running_targets_key
  def payload_timed_out_targets_key, do: @payload_timed_out_targets_key
  def payload_protocol_key, do: @payload_protocol_key
  def payload_execution_profile_key, do: @payload_execution_profile_key
  def payload_target_query_key, do: @payload_target_query_key
  def payload_selector_limit_key, do: @payload_selector_limit_key
  def default_limit, do: @default_limit
  def max_limit, do: @max_limit

  def empty_trace_coverage do
    %{trace_count: 0, reached_count: 0, failed_count: 0, earliest_time: nil, latest_time: nil}
  end

  def degraded_retention_status, do: %{configured_days: 30, status: :degraded, tables: %{}}

  def default_mtr_form do
    %{
      @payload_target_key => "",
      @payload_agent_id_key => "",
      @payload_protocol_key => @protocol_icmp
    }
  end

  def default_bulk_mtr_form do
    %{
      @payload_targets_key => "",
      @payload_target_query_key => "",
      @payload_selector_limit_key => "100",
      @payload_agent_id_key => "",
      @payload_protocol_key => @protocol_icmp,
      @payload_execution_profile_key => @execution_profile_fast,
      @payload_concurrency_key => "64"
    }
  end
end
