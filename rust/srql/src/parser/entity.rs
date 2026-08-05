use crate::{
    error::{Result, ServiceError},
    parser::Entity,
};

pub(super) fn parse_entity(raw: &str) -> Result<Entity> {
    let normalized = raw.trim_matches('"').trim_matches('\'').to_lowercase();
    match normalized.as_str() {
        "agents" | "agent" | "ocsf_agents" => Ok(Entity::Agents),
        "devices" | "device" | "device_inventory" => Ok(Entity::Devices),
        "device_graph" | "devicegraph" | "graph" => Ok(Entity::DeviceGraph),
        "graph_cypher" | "graphcypher" | "cypher" => Ok(Entity::GraphCypher),
        "interfaces" | "interface" | "discovered_interfaces" => Ok(Entity::Interfaces),
        "events" | "activity" => Ok(Entity::Events),
        "security_findings" | "security_finding" | "findings" | "finding" => {
            Ok(Entity::SecurityFindings)
        }
        "scan_activity" | "scan_activities" | "security_scans" | "scanner_activity" => {
            Ok(Entity::ScanActivity)
        }
        "dns_activity" | "dns_activities" | "dns_security_activity" | "powerdns" | "pdns" => {
            Ok(Entity::DnsActivity)
        }
        "bmp_events" | "bmp_event" | "bmp_routing_events" => Ok(Entity::BmpEvents),
        "field_survey_sessions" | "fieldsurvey_sessions" | "survey_sessions" => {
            Ok(Entity::FieldSurveySessions)
        }
        "field_survey_rasters"
        | "fieldsurvey_rasters"
        | "survey_coverage_rasters"
        | "survey_rasters" => Ok(Entity::FieldSurveyRasters),
        "field_survey_artifacts"
        | "fieldsurvey_artifacts"
        | "survey_room_artifacts"
        | "survey_artifacts" => Ok(Entity::FieldSurveyArtifacts),
        "field_survey_rf_observations"
        | "fieldsurvey_rf_observations"
        | "survey_rf_observations" => Ok(Entity::FieldSurveyRfObservations),
        "field_survey_pose_samples" | "fieldsurvey_pose_samples" | "survey_pose_samples" => {
            Ok(Entity::FieldSurveyPoseSamples)
        }
        "field_survey_rf_pose_matches"
        | "fieldsurvey_rf_pose_matches"
        | "survey_rf_pose_matches" => Ok(Entity::FieldSurveyRfPoseMatches),
        "field_survey_spectrum_observations"
        | "fieldsurvey_spectrum_observations"
        | "survey_spectrum_observations" => Ok(Entity::FieldSurveySpectrumObservations),
        "wifi_sites" | "wifi_site_map" | "wifi_map_sites" => Ok(Entity::WifiSites),
        "wifi_site_snapshots" | "wifi_snapshots" => Ok(Entity::WifiSiteSnapshots),
        "wifi_aps" | "wifi_access_points" | "wifi_ap_observations" => Ok(Entity::WifiAccessPoints),
        "wifi_controllers" | "wifi_wlcs" | "wifi_controller_observations" => {
            Ok(Entity::WifiControllers)
        }
        "wifi_radius_groups" | "wifi_radius_group_observations" => Ok(Entity::WifiRadiusGroups),
        "wifi_fleet_history" | "wifi_history" => Ok(Entity::WifiFleetHistory),
        "wifi_site_references" | "wifi_airport_references" | "wifi_references" => {
            Ok(Entity::WifiSiteReferences)
        }
        "virtualization_clusters" | "virtualization_cluster" | "hypervisor_clusters" => {
            Ok(Entity::VirtualizationClusters)
        }
        "virtualization_hosts" | "virtualization_host" | "hypervisors" | "hypervisor_hosts" => {
            Ok(Entity::VirtualizationHosts)
        }
        "virtualization_guests" | "virtualization_guest" | "vms" | "vm" | "containers" => {
            Ok(Entity::VirtualizationGuests)
        }
        "virtualization_datastores" | "virtualization_datastore" | "datastores" => {
            Ok(Entity::VirtualizationDatastores)
        }
        "virtualization_host_disks" | "virtualization_disks" | "host_disks" => {
            Ok(Entity::VirtualizationHostDisks)
        }
        "virtualization_network_interfaces" | "virtualization_nics" | "hypervisor_nics" => {
            Ok(Entity::VirtualizationNetworkInterfaces)
        }
        "virtualization_storage_systems" | "storage_systems" | "ceph" => {
            Ok(Entity::VirtualizationStorageSystems)
        }
        "logs" => Ok(Entity::Logs),
        "services" | "service" => Ok(Entity::Services),
        "service_availability" | "service_availability_latest" | "availability_services" => {
            Ok(Entity::ServiceAvailability)
        }
        "monitored_services" | "monitored_service" | "service_inventory" => {
            Ok(Entity::MonitoredServices)
        }
        "slo_evaluations" | "slo_evaluation" | "service_slos" | "slo" => Ok(Entity::SloEvaluations),
        "dashboards" | "dashboard" | "authored_dashboards" | "authored_dashboard" => {
            Ok(Entity::Dashboards)
        }
        "gateways" | "gateway" => Ok(Entity::Gateways),
        "otel_metrics" | "metrics" => Ok(Entity::OtelMetrics),
        "otel_metric_points" | "metric_points" => Ok(Entity::OtelMetricPoints),
        "rperf_metrics" | "rperf" => Ok(Entity::RperfMetrics),
        "cpu_metrics" | "cpu" => Ok(Entity::CpuMetrics),
        "memory_metrics" | "memory" => Ok(Entity::MemoryMetrics),
        "disk_metrics" | "disk" => Ok(Entity::DiskMetrics),
        "process_metrics" | "processes" => Ok(Entity::ProcessMetrics),
        "capacity_forecasts" | "capacity_forecast" | "forecasts" | "forecast" => {
            Ok(Entity::CapacityForecasts)
        }
        "timeseries_metrics" | "timeseries" => Ok(Entity::TimeseriesMetrics),
        "timeseries_metric_interface_hourly"
        | "timeseries_metrics_interface_hourly"
        | "interface_timeseries_metrics_hourly"
        | "interface_metrics_hourly" => Ok(Entity::TimeseriesMetricInterfaceHourly),
        "snmp_metrics" | "snmp" => Ok(Entity::SnmpMetrics),
        "otel_trace_summaries" | "trace_summaries" | "traces_summaries" => {
            Ok(Entity::TraceSummaries)
        }
        "otel_traces" | "traces" | "trace_spans" => Ok(Entity::Traces),
        "flows" | "flow" | "network_activity" => Ok(Entity::Flows),
        "attributed_flows" | "attributed_flow" | "flow_attributions" | "flow_attribution" => {
            Ok(Entity::AttributedFlows)
        }
        "alerts" | "alert" => Ok(Entity::Alerts),
        "addon_fleet" | "addon_fleets" => Ok(Entity::AddonFleet),
        "addon_statuses" | "addon_status" => Ok(Entity::AddonStatuses),
        "public_endpoints"
        | "public_endpoint"
        | "k8s_public_endpoints"
        | "k8s_endpoints"
        | "vip_inventory" => Ok(Entity::PublicEndpoints),
        "endpoint_inventory_scans"
        | "endpoint_inventory_scan"
        | "endpoint_inventory_status"
        | "endpoint_inventory_statuses"
        | "endpoint_inventory_freshness" => Ok(Entity::EndpointInventoryScans),
        "endpoint_packages"
        | "endpoint_package"
        | "endpoint_inventory_packages"
        | "endpoint_inventory"
        | "packages" => Ok(Entity::EndpointPackages),
        "endpoint_package_catalog"
        | "endpoint_package_catalogs"
        | "endpoint_software_packages"
        | "endpoint_software_package"
        | "package_catalog"
        | "package_catalogs" => Ok(Entity::EndpointPackageCatalog),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported entity '{other}'"
        ))),
    }
}
