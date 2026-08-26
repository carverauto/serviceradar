//! Diesel schema definitions for CNPG tables used by SRQL.

diesel::table! {
    use diesel::pg::sql_types::Array;
    use diesel::sql_types::*;

    /// OCSF Agent Registry (aligned with OCSF v1.7.0 Agent object)
    ocsf_agents (uid) {
        uid -> Text,
        name -> Nullable<Text>,
        type_id -> Int4,
        #[sql_name = "type"]
        agent_type -> Nullable<Text>,
        version -> Nullable<Text>,
        vendor_name -> Nullable<Text>,
        uid_alt -> Nullable<Text>,
        policies -> Nullable<Jsonb>,
        gateway_id -> Nullable<Text>,
        capabilities -> Nullable<Array<Text>>,
        host -> Nullable<Text>,
        ip -> Nullable<Text>,
        first_seen_time -> Nullable<Timestamptz>,
        last_seen_time -> Nullable<Timestamptz>,
        created_time -> Timestamptz,
        modified_time -> Timestamptz,
        metadata -> Nullable<Jsonb>,
        config_source -> Nullable<Text>,
        desired_version -> Nullable<Text>,
        release_rollout_state -> Nullable<Text>,
        last_update_at -> Nullable<Timestamptz>,
        last_update_error -> Nullable<Text>,
    }
}

diesel::table! {
    use diesel::sql_types::*;

    /// Per-agent observed native add-on status (issue 3425). `platform` schema is
    /// resolved at runtime via the Ecto search_path, like ocsf_agents.
    addon_statuses (id) {
        id -> Uuid,
        agent_uid -> Text,
        addon_id -> Text,
        state -> Text,
        active -> Bool,
        degradation_reason -> Nullable<Text>,
        pid -> Nullable<Int4>,
        restart_count -> Int4,
        last_health_at -> Nullable<Timestamptz>,
        version -> Nullable<Text>,
        arch -> Nullable<Text>,
        reported_at -> Timestamptz,
        inserted_at -> Timestamptz,
        updated_at -> Timestamptz,
    }
}

diesel::table! {
    use diesel::pg::sql_types::Array;
    use diesel::sql_types::*;

    endpoint_inventory_scans (id) {
        id -> Uuid,
        device_uid -> Nullable<Text>,
        agent_id -> Text,
        scan_id -> Text,
        collector_name -> Nullable<Text>,
        collector_version -> Nullable<Text>,
        state -> Text,
        coverage_state -> Text,
        package_count -> Int4,
        enabled_sources -> Array<Text>,
        manager_counts -> Jsonb,
        source_summaries -> Array<Jsonb>,
        artifact_count -> Int4,
        current -> Bool,
        last_successful_scan_at -> Nullable<Timestamptz>,
        last_scan_at -> Nullable<Timestamptz>,
        last_changed_scan_at -> Nullable<Timestamptz>,
        ingested_at -> Nullable<Timestamptz>,
        package_set_hash -> Nullable<Text>,
        artifact_hash -> Nullable<Text>,
        hash_algorithm -> Nullable<Text>,
        upload_reason -> Nullable<Text>,
        server_package_set_hash -> Nullable<Text>,
        package_set_hash_mismatch -> Bool,
        unchanged_scan_count -> Int4,
        reconcile_floor_due -> Bool,
        metadata -> Jsonb,
        inserted_at -> Timestamptz,
        updated_at -> Timestamptz,
    }
}

diesel::table! {
    use diesel::pg::sql_types::Array;
    use diesel::sql_types::*;

    endpoint_inventory_packages (id) {
        id -> Uuid,
        scan_ref -> Uuid,
        device_uid -> Nullable<Text>,
        agent_id -> Text,
        name -> Text,
        version -> Nullable<Text>,
        architecture -> Nullable<Text>,
        package_manager -> Text,
        ecosystem -> Nullable<Text>,
        purl -> Nullable<Text>,
        purl_canonical -> Text,
        endpoint_package_ref -> Uuid,
        cpes -> Array<Text>,
        supplier -> Nullable<Text>,
        license -> Nullable<Text>,
        source -> Nullable<Text>,
        evidence -> Jsonb,
        current -> Bool,
        metadata -> Jsonb,
        inserted_at -> Timestamptz,
        updated_at -> Timestamptz,
    }
}

diesel::table! {
    use diesel::pg::sql_types::Array;
    use diesel::sql_types::*;

    endpoint_packages (id) {
        id -> Uuid,
        coordinate_key -> Text,
        purl_canonical -> Nullable<Text>,
        primary_cpe -> Nullable<Text>,
        cpes -> Array<Text>,
        package_manager -> Text,
        name -> Text,
        version -> Nullable<Text>,
        architecture -> Nullable<Text>,
        ecosystem -> Nullable<Text>,
        source_scope -> Text,
        metadata -> Jsonb,
        inserted_at -> Timestamptz,
        updated_at -> Timestamptz,
    }
}

diesel::table! {
    use diesel::pg::sql_types::Array;
    use diesel::sql_types::*;

    /// OCSF Device Inventory (aligned with OCSF v1.7.0 Device object)
    ocsf_devices (uid) {
        // OCSF Core Identity
        uid -> Text,
        type_id -> Int4,
        #[sql_name = "type"]
        device_type -> Nullable<Text>,
        name -> Nullable<Text>,
        hostname -> Nullable<Text>,
        ip -> Nullable<Text>,
        mac -> Nullable<Text>,

        // OCSF Extended Identity
        uid_alt -> Nullable<Text>,
        vendor_name -> Nullable<Text>,
        model -> Nullable<Text>,
        domain -> Nullable<Text>,
        zone -> Nullable<Text>,
        subnet_uid -> Nullable<Text>,
        vlan_uid -> Nullable<Text>,
        region -> Nullable<Text>,

        // OCSF Temporal
        first_seen_time -> Nullable<Timestamptz>,
        last_seen_time -> Nullable<Timestamptz>,
        created_time -> Timestamptz,
        modified_time -> Timestamptz,

        // OCSF Risk and Compliance
        risk_level_id -> Nullable<Int4>,
        risk_level -> Nullable<Text>,
        risk_score -> Nullable<Int4>,
        is_managed -> Nullable<Bool>,
        is_compliant -> Nullable<Bool>,
        is_trusted -> Nullable<Bool>,

        // OCSF Nested Objects (JSONB)
        os -> Nullable<Jsonb>,
        hw_info -> Nullable<Jsonb>,
        network_interfaces -> Nullable<Jsonb>,
        owner -> Nullable<Jsonb>,
        org -> Nullable<Jsonb>,
        groups -> Nullable<Jsonb>,
        agent_list -> Nullable<Jsonb>,

        // ServiceRadar-specific fields
        gateway_id -> Nullable<Text>,
        agent_id -> Nullable<Text>,
        availability_source_agent_id -> Nullable<Text>,
        discovery_sources -> Nullable<Array<Text>>,
        is_available -> Nullable<Bool>,
        is_active -> Nullable<Bool>,
        tags -> Nullable<Jsonb>,
        metadata -> Nullable<Jsonb>,
        deleted_at -> Nullable<Timestamptz>,
        deleted_by -> Nullable<Text>,
        deleted_reason -> Nullable<Text>,
    }
}

diesel::table! {
    use diesel::pg::sql_types::Array;
    use diesel::sql_types::*;

    device_agent_availability (id) {
        id -> Uuid,
        device_uid -> Text,
        agent_id -> Text,
        agent_name -> Nullable<Text>,
        is_available -> Bool,
        checked_at -> Timestamptz,
        response_time_ms -> Nullable<Int8>,
        open_ports -> Array<Int4>,
        sweep_modes_results -> Jsonb,
        sweep_group_id -> Nullable<Uuid>,
        execution_id -> Nullable<Uuid>,
        metadata -> Jsonb,
        inserted_at -> Timestamptz,
        updated_at -> Timestamptz,
    }
}

diesel::table! {
    use diesel::sql_types::*;

    composite_checks (id) {
        id -> Uuid,
        name -> Text,
        slug -> Text,
        description -> Nullable<Text>,
        scope_query -> Text,
        evaluation_interval_seconds -> Int8,
        state -> Text,
        last_evaluated_at -> Nullable<Timestamptz>,
        inserted_at -> Timestamptz,
        updated_at -> Timestamptz,
    }
}

diesel::table! {
    use diesel::sql_types::*;

    device_composite_check_results (id) {
        id -> Uuid,
        device_uid -> Text,
        check_id -> Uuid,
        verdict -> Text,
        status -> Text,
        matched_rule_id -> Nullable<Uuid>,
        inputs -> Jsonb,
        evaluated_at -> Timestamptz,
        changed_at -> Timestamptz,
        inserted_at -> Timestamptz,
        updated_at -> Timestamptz,
    }
}

diesel::joinable!(device_composite_check_results -> composite_checks (check_id));
diesel::allow_tables_to_appear_in_same_query!(device_composite_check_results, composite_checks);

diesel::table! {
    use diesel::sql_types::*;

    gateways (gateway_id) {
        gateway_id -> Text,
        component_id -> Nullable<Text>,
        registration_source -> Nullable<Text>,
        status -> Nullable<Text>,
        spiffe_identity -> Nullable<Text>,
        first_registered -> Nullable<Timestamptz>,
        first_seen -> Nullable<Timestamptz>,
        last_seen -> Nullable<Timestamptz>,
        metadata -> Nullable<Jsonb>,
        created_by -> Nullable<Text>,
        is_healthy -> Nullable<Bool>,
        agent_count -> Nullable<Int4>,
        checker_count -> Nullable<Int4>,
        updated_at -> Nullable<Timestamptz>,
        partition_id -> Nullable<Uuid>,
    }
}

diesel::table! {
    use diesel::sql_types::*;

    events (event_timestamp, id) {
        event_timestamp -> Timestamptz,
        specversion -> Nullable<Text>,
        id -> Text,
        source -> Nullable<Text>,
        #[sql_name = "type"]
        event_type -> Nullable<Text>,
        datacontenttype -> Nullable<Text>,
        subject -> Nullable<Text>,
        remote_addr -> Nullable<Text>,
        host -> Nullable<Text>,
        level -> Nullable<Int4>,
        severity -> Nullable<Text>,
        short_message -> Nullable<Text>,
        version -> Nullable<Text>,
        raw_data -> Nullable<Text>,
        created_at -> Timestamptz,
    }
}

diesel::table! {
    use diesel::sql_types::*;

    bmp_routing_events (time, id) {
        time -> Timestamptz,
        id -> Uuid,
        event_type -> Text,
        severity_id -> Nullable<Int4>,
        router_id -> Nullable<Text>,
        router_ip -> Nullable<Text>,
        peer_ip -> Nullable<Text>,
        peer_asn -> Nullable<Int8>,
        local_asn -> Nullable<Int8>,
        prefix -> Nullable<Text>,
        message -> Nullable<Text>,
        metadata -> Jsonb,
        raw_data -> Nullable<Text>,
        created_at -> Timestamptz,
    }
}

diesel::table! {
    use diesel::sql_types::*;

    ocsf_events (time, id) {
        time -> Timestamptz,
        id -> Uuid,
        class_uid -> Int4,
        category_uid -> Int4,
        type_uid -> Int4,
        activity_id -> Int4,
        activity_name -> Nullable<Text>,
        severity_id -> Nullable<Int4>,
        severity -> Nullable<Text>,
        message -> Nullable<Text>,
        status_id -> Nullable<Int4>,
        status -> Nullable<Text>,
        status_code -> Nullable<Text>,
        status_detail -> Nullable<Text>,
        metadata -> Jsonb,
        observables -> Jsonb,
        trace_id -> Nullable<Text>,
        span_id -> Nullable<Text>,
        actor -> Jsonb,
        device -> Jsonb,
        src_endpoint -> Jsonb,
        dst_endpoint -> Jsonb,
        log_name -> Nullable<Text>,
        log_provider -> Nullable<Text>,
        log_level -> Nullable<Text>,
        log_version -> Nullable<Text>,
        unmapped -> Jsonb,
        raw_data -> Nullable<Text>,
        created_at -> Timestamptz,
    }
}

diesel::table! {
    use diesel::sql_types::*;

    logs (timestamp, id) {
        timestamp -> Timestamptz,
        observed_timestamp -> Nullable<Timestamptz>,
        id -> Uuid,
        trace_id -> Nullable<Text>,
        span_id -> Nullable<Text>,
        trace_flags -> Nullable<Int4>,
        severity_text -> Nullable<Text>,
        severity_number -> Nullable<Int4>,
        body -> Nullable<Text>,
        event_name -> Nullable<Text>,
        source -> Nullable<Text>,
        service_name -> Nullable<Text>,
        service_version -> Nullable<Text>,
        service_instance -> Nullable<Text>,
        scope_name -> Nullable<Text>,
        scope_version -> Nullable<Text>,
        scope_attributes -> Nullable<Text>,
        attributes -> Nullable<Text>,
        resource_attributes -> Nullable<Text>,
        created_at -> Timestamptz,
        ingest_identity -> Text,
        ingest_agent_id -> Text,
        ingest_partition -> Text,
        source_ip -> Nullable<Text>,
    }
}

diesel::table! {
    use diesel::sql_types::*;

    service_status (timestamp, gateway_id, service_name) {
        timestamp -> Timestamptz,
        gateway_id -> Text,
        agent_id -> Nullable<Text>,
        service_id -> Nullable<Uuid>,
        service_name -> Text,
        service_type -> Nullable<Text>,
        available -> Bool,
        message -> Nullable<Text>,
        details -> Nullable<Text>,
        partition -> Nullable<Text>,
        created_at -> Timestamptz,
    }
}

diesel::table! {
    use diesel::pg::sql_types::Array;
    use diesel::sql_types::*;

    discovered_interfaces (device_id, interface_uid) {
        timestamp -> Timestamptz,
        agent_id -> Nullable<Text>,
        gateway_id -> Nullable<Text>,
        device_ip -> Nullable<Text>,
        device_id -> Nullable<Text>,
        interface_uid -> Text,
        if_index -> Nullable<Int4>,
        if_name -> Nullable<Text>,
        if_descr -> Nullable<Text>,
        if_alias -> Nullable<Text>,
        if_speed -> Nullable<Int8>,
        speed_bps -> Nullable<Int8>,
        mtu -> Nullable<Int4>,
        duplex -> Nullable<Text>,
        if_type -> Nullable<Int4>,
        if_type_name -> Nullable<Text>,
        interface_kind -> Nullable<Text>,
        if_phys_address -> Nullable<Text>,
        ip_addresses -> Nullable<Array<Text>>,
        if_admin_status -> Nullable<Int4>,
        if_oper_status -> Nullable<Int4>,
        metadata -> Nullable<Jsonb>,
        available_metrics -> Nullable<Jsonb>,
        created_at -> Timestamptz,
    }
}

diesel::table! {
    use diesel::sql_types::*;

    otel_traces (timestamp, trace_id, span_id) {
        timestamp -> Timestamptz,
        trace_id -> Nullable<Text>,
        span_id -> Text,
        parent_span_id -> Nullable<Text>,
        trace_state -> Nullable<Text>,
        name -> Nullable<Text>,
        kind -> Nullable<Int4>,
        start_time_unix_nano -> Nullable<Int8>,
        end_time_unix_nano -> Nullable<Int8>,
        service_name -> Nullable<Text>,
        service_version -> Nullable<Text>,
        service_instance -> Nullable<Text>,
        service_namespace -> Text,
        deployment_environment -> Text,
        scope_name -> Nullable<Text>,
        scope_version -> Nullable<Text>,
        scope_attributes -> Nullable<Text>,
        status_code -> Nullable<Int4>,
        status_message -> Nullable<Text>,
        attributes -> Nullable<Text>,
        resource_attributes -> Nullable<Text>,
        events -> Nullable<Text>,
        links -> Nullable<Text>,
        dropped_attributes_count -> Int4,
        dropped_events_count -> Int4,
        dropped_links_count -> Int4,
        created_at -> Timestamptz,
        ingest_identity -> Text,
        ingest_agent_id -> Text,
        ingest_partition -> Text,
    }
}

diesel::table! {
    use diesel::sql_types::*;

    otel_metrics (timestamp, span_name, service_name, span_id) {
        timestamp -> Timestamptz,
        trace_id -> Nullable<Text>,
        span_id -> Nullable<Text>,
        service_name -> Nullable<Text>,
        span_name -> Nullable<Text>,
        span_kind -> Nullable<Text>,
        duration_ms -> Nullable<Float8>,
        duration_seconds -> Nullable<Float8>,
        metric_type -> Nullable<Text>,
        http_method -> Nullable<Text>,
        http_route -> Nullable<Text>,
        http_status_code -> Nullable<Text>,
        grpc_service -> Nullable<Text>,
        grpc_method -> Nullable<Text>,
        grpc_status_code -> Nullable<Text>,
        is_slow -> Nullable<Bool>,
        component -> Nullable<Text>,
        level -> Nullable<Text>,
        unit -> Nullable<Text>,
        created_at -> Timestamptz,
        ingest_identity -> Text,
        ingest_agent_id -> Text,
        ingest_partition -> Text,
    }
}

diesel::table! {
    use diesel::sql_types::*;

    otel_metric_points (timestamp, metric_name, service_name, attributes_hash) {
        timestamp -> Timestamptz,
        metric_name -> Text,
        metric_type -> Nullable<Text>,
        unit -> Nullable<Text>,
        temporality -> Nullable<Text>,
        is_monotonic -> Nullable<Bool>,
        service_name -> Text,
        attributes -> Nullable<Text>,
        attributes_hash -> Text,
        value -> Nullable<Float8>,
        count -> Nullable<Int8>,
        sum -> Nullable<Float8>,
        bucket_counts -> Nullable<Text>,
        explicit_bounds -> Nullable<Text>,
        start_time_unix_nano -> Nullable<Int8>,
        scope_name -> Text,
        service_instance_id -> Text,
        created_at -> Timestamptz,
        ingest_identity -> Text,
        ingest_agent_id -> Text,
        ingest_partition -> Text,
    }
}

diesel::table! {
    use diesel::sql_types::*;

    timeseries_metrics (timestamp, gateway_id, series_key) {
        timestamp -> Timestamptz,
        gateway_id -> Text,
        agent_id -> Nullable<Text>,
        series_key -> Text,
        metric_name -> Text,
        metric_type -> Text,
        device_id -> Nullable<Text>,
        value -> Float8,
        unit -> Nullable<Text>,
        tags -> Nullable<Jsonb>,
        partition -> Nullable<Text>,
        scale -> Nullable<Float8>,
        is_delta -> Nullable<Bool>,
        target_device_ip -> Nullable<Text>,
        if_index -> Nullable<Int4>,
        metadata -> Nullable<Jsonb>,
        created_at -> Timestamptz,
    }
}

diesel::table! {
    use diesel::sql_types::*;

    capacity_forecasts (forecasted_at, resource_key, metric_name, horizon_seconds) {
        forecasted_at -> Timestamptz,
        resource_key -> Text,
        resource_type -> Text,
        resource_id -> Text,
        resource_label -> Nullable<Text>,
        metric_class -> Text,
        metric_name -> Text,
        horizon_seconds -> Int8,
        horizon_ends_at -> Timestamptz,
        window_started_at -> Nullable<Timestamptz>,
        window_ended_at -> Nullable<Timestamptz>,
        sample_count -> Int4,
        model -> Text,
        status -> Text,
        skip_reason -> Nullable<Text>,
        current_value -> Nullable<Float8>,
        slope_per_second -> Nullable<Float8>,
        intercept -> Nullable<Float8>,
        projected_value -> Nullable<Float8>,
        projected_exhaustion_at -> Nullable<Timestamptz>,
        exhaustion_threshold -> Nullable<Float8>,
        confidence -> Nullable<Float8>,
        lower_bound -> Nullable<Float8>,
        upper_bound -> Nullable<Float8>,
        metadata -> Jsonb,
        inserted_at -> Timestamptz,
        updated_at -> Timestamptz,
    }
}

diesel::table! {
    use diesel::sql_types::*;

    cpu_metrics (timestamp, gateway_id, core_id) {
        timestamp -> Timestamptz,
        gateway_id -> Text,
        agent_id -> Nullable<Text>,
        host_id -> Nullable<Text>,
        core_id -> Nullable<Int4>,
        usage_percent -> Nullable<Float8>,
        frequency_hz -> Nullable<Float8>,
        label -> Nullable<Text>,
        cluster -> Nullable<Text>,
        device_id -> Nullable<Text>,
        partition -> Nullable<Text>,
        created_at -> Timestamptz,
    }
}

diesel::table! {
    use diesel::sql_types::*;

    disk_metrics (timestamp, gateway_id, mount_point) {
        timestamp -> Timestamptz,
        gateway_id -> Nullable<Text>,
        agent_id -> Nullable<Text>,
        host_id -> Nullable<Text>,
        mount_point -> Nullable<Text>,
        device_name -> Nullable<Text>,
        total_bytes -> Nullable<Int8>,
        used_bytes -> Nullable<Int8>,
        available_bytes -> Nullable<Int8>,
        usage_percent -> Nullable<Float8>,
        device_id -> Nullable<Text>,
        partition -> Nullable<Text>,
        created_at -> Timestamptz,
    }
}

diesel::table! {
    use diesel::sql_types::*;

    memory_metrics (timestamp, gateway_id) {
        timestamp -> Timestamptz,
        gateway_id -> Nullable<Text>,
        agent_id -> Nullable<Text>,
        host_id -> Nullable<Text>,
        total_bytes -> Nullable<Int8>,
        used_bytes -> Nullable<Int8>,
        available_bytes -> Nullable<Int8>,
        usage_percent -> Nullable<Float8>,
        device_id -> Nullable<Text>,
        partition -> Nullable<Text>,
        created_at -> Timestamptz,
    }
}

diesel::table! {
    use diesel::sql_types::*;

    process_metrics (timestamp, gateway_id, pid) {
        timestamp -> Timestamptz,
        gateway_id -> Nullable<Text>,
        agent_id -> Nullable<Text>,
        host_id -> Nullable<Text>,
        pid -> Nullable<Int4>,
        name -> Nullable<Text>,
        cpu_usage -> Nullable<Float4>,
        memory_usage -> Nullable<Int8>,
        status -> Nullable<Text>,
        start_time -> Nullable<Text>,
        device_id -> Nullable<Text>,
        partition -> Nullable<Text>,
        created_at -> Timestamptz,
    }
}

diesel::table! {
    use diesel::pg::sql_types::Array;
    use diesel::sql_types::*;

    alerts (id) {
        id -> Uuid,
        title -> Text,
        description -> Nullable<Text>,
        severity -> Text,
        status -> Text,
        source_type -> Nullable<Text>,
        source_id -> Nullable<Text>,
        service_check_id -> Nullable<Uuid>,
        device_uid -> Nullable<Text>,
        agent_uid -> Nullable<Text>,
        event_id -> Nullable<Uuid>,
        event_time -> Nullable<Timestamptz>,
        metric_name -> Nullable<Text>,
        metric_value -> Nullable<Float8>,
        threshold_value -> Nullable<Float8>,
        comparison -> Nullable<Text>,
        triggered_at -> Nullable<Timestamptz>,
        acknowledged_at -> Nullable<Timestamptz>,
        acknowledged_by -> Nullable<Text>,
        resolved_at -> Nullable<Timestamptz>,
        resolved_by -> Nullable<Text>,
        resolution_note -> Nullable<Text>,
        escalated_at -> Nullable<Timestamptz>,
        escalation_level -> Nullable<Int8>,
        escalation_reason -> Nullable<Text>,
        notification_count -> Nullable<Int8>,
        last_notification_at -> Nullable<Timestamptz>,
        suppressed_until -> Nullable<Timestamptz>,
        metadata -> Nullable<Jsonb>,
        tags -> Nullable<Array<Text>>,
        created_at -> Timestamptz,
        updated_at -> Timestamptz,
    }
}

diesel::table! {
    use diesel::pg::sql_types::Array;
    use diesel::sql_types::*;

    ocsf_network_activity (time) {
        time -> Timestamptz,
        class_uid -> Int4,
        category_uid -> Int4,
        activity_id -> Int4,
        type_uid -> Int4,
        severity_id -> Int4,
        start_time -> Nullable<Timestamptz>,
        end_time -> Nullable<Timestamptz>,
        src_endpoint_ip -> Nullable<Text>,
        src_endpoint_port -> Nullable<Int4>,
        src_as_number -> Nullable<Int4>,
        dst_endpoint_ip -> Nullable<Text>,
        dst_endpoint_port -> Nullable<Int4>,
        dst_as_number -> Nullable<Int4>,
        protocol_num -> Nullable<Int4>,
        protocol_name -> Nullable<Text>,
        protocol_source -> Nullable<Text>,
        tcp_flags -> Nullable<Int4>,
        tcp_flags_labels -> Nullable<Array<Text>>,
        tcp_flags_source -> Nullable<Text>,
        dst_service_label -> Nullable<Text>,
        dst_service_source -> Nullable<Text>,
        bytes_total -> Int8,
        packets_total -> Int8,
        bytes_in -> Nullable<Int8>,
        bytes_out -> Nullable<Int8>,
        packets_in -> Nullable<Int8>,
        packets_out -> Nullable<Int8>,
        sampling_rate -> Int8,
        direction_label -> Nullable<Text>,
        direction_source -> Nullable<Text>,
        src_hosting_provider -> Nullable<Text>,
        src_hosting_provider_source -> Nullable<Text>,
        dst_hosting_provider -> Nullable<Text>,
        dst_hosting_provider_source -> Nullable<Text>,
        src_mac -> Nullable<Text>,
        dst_mac -> Nullable<Text>,
        src_mac_vendor -> Nullable<Text>,
        src_mac_vendor_source -> Nullable<Text>,
        dst_mac_vendor -> Nullable<Text>,
        dst_mac_vendor_source -> Nullable<Text>,
        src_prefix_tags -> Nullable<Jsonb>,
        dst_prefix_tags -> Nullable<Jsonb>,
        src_prefix_tags_source -> Nullable<Text>,
        dst_prefix_tags_source -> Nullable<Text>,
        sampler_address -> Nullable<Text>,
        ocsf_payload -> Jsonb,
        partition -> Nullable<Text>,
        created_at -> Timestamptz,
    }
}
