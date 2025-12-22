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
        poller_id -> Nullable<Text>,
        capabilities -> Nullable<Array<Text>>,
        ip -> Nullable<Text>,
        first_seen_time -> Nullable<Timestamptz>,
        last_seen_time -> Nullable<Timestamptz>,
        created_time -> Timestamptz,
        modified_time -> Timestamptz,
        metadata -> Nullable<Jsonb>,
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
        poller_id -> Nullable<Text>,
        agent_id -> Nullable<Text>,
        discovery_sources -> Nullable<Array<Text>>,
        is_available -> Nullable<Bool>,
        metadata -> Nullable<Jsonb>,
    }
}

diesel::table! {
    use diesel::sql_types::*;

    pollers (poller_id) {
        poller_id -> Text,
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

    logs (timestamp, trace_id, span_id) {
        timestamp -> Timestamptz,
        trace_id -> Nullable<Text>,
        span_id -> Nullable<Text>,
        severity_text -> Nullable<Text>,
        severity_number -> Nullable<Int4>,
        body -> Nullable<Text>,
        service_name -> Nullable<Text>,
        service_version -> Nullable<Text>,
        service_instance -> Nullable<Text>,
        scope_name -> Nullable<Text>,
        scope_version -> Nullable<Text>,
        attributes -> Nullable<Text>,
        resource_attributes -> Nullable<Text>,
        created_at -> Timestamptz,
    }
}

diesel::table! {
    use diesel::sql_types::*;

    service_status (timestamp, poller_id, service_name) {
        timestamp -> Timestamptz,
        poller_id -> Text,
        agent_id -> Nullable<Text>,
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

    discovered_interfaces (timestamp, device_id, if_index) {
        timestamp -> Timestamptz,
        agent_id -> Nullable<Text>,
        poller_id -> Nullable<Text>,
        device_ip -> Nullable<Text>,
        device_id -> Nullable<Text>,
        if_index -> Nullable<Int4>,
        if_name -> Nullable<Text>,
        if_descr -> Nullable<Text>,
        if_alias -> Nullable<Text>,
        if_speed -> Nullable<Int8>,
        if_phys_address -> Nullable<Text>,
        ip_addresses -> Nullable<Array<Text>>,
        if_admin_status -> Nullable<Int4>,
        if_oper_status -> Nullable<Int4>,
        metadata -> Nullable<Jsonb>,
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
        name -> Nullable<Text>,
        kind -> Nullable<Int4>,
        start_time_unix_nano -> Nullable<Int8>,
        end_time_unix_nano -> Nullable<Int8>,
        service_name -> Nullable<Text>,
        service_version -> Nullable<Text>,
        service_instance -> Nullable<Text>,
        scope_name -> Nullable<Text>,
        scope_version -> Nullable<Text>,
        status_code -> Nullable<Int4>,
        status_message -> Nullable<Text>,
        attributes -> Nullable<Text>,
        resource_attributes -> Nullable<Text>,
        events -> Nullable<Text>,
        links -> Nullable<Text>,
        created_at -> Timestamptz,
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
    }
}

diesel::table! {
    use diesel::sql_types::*;

    timeseries_metrics (timestamp, poller_id, metric_name) {
        timestamp -> Timestamptz,
        poller_id -> Text,
        agent_id -> Nullable<Text>,
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

    cpu_metrics (timestamp, poller_id, core_id) {
        timestamp -> Timestamptz,
        poller_id -> Text,
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

    disk_metrics (timestamp, poller_id, mount_point) {
        timestamp -> Timestamptz,
        poller_id -> Nullable<Text>,
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

    memory_metrics (timestamp, poller_id) {
        timestamp -> Timestamptz,
        poller_id -> Nullable<Text>,
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

    process_metrics (timestamp, poller_id, pid) {
        timestamp -> Timestamptz,
        poller_id -> Nullable<Text>,
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
    use diesel::sql_types::*;

    device_updates (observed_at, device_id) {
        observed_at -> Timestamptz,
        agent_id -> Text,
        poller_id -> Text,
        partition -> Text,
        device_id -> Text,
        discovery_source -> Text,
        ip -> Nullable<Text>,
        mac -> Nullable<Text>,
        hostname -> Nullable<Text>,
        available -> Nullable<Bool>,
        metadata -> Nullable<Jsonb>,
        created_at -> Timestamptz,
    }
}

diesel::table! {
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
        tcp_flags -> Nullable<Int4>,
        bytes_total -> Int8,
        packets_total -> Int8,
        bytes_in -> Int8,
        bytes_out -> Int8,
        sampler_address -> Nullable<Text>,
        ocsf_payload -> Jsonb,
        partition -> Nullable<Text>,
        created_at -> Timestamptz,
    }
}
