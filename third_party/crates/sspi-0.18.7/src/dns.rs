#![allow(dead_code)]
#![allow(unused_imports)]

cfg_if::cfg_if! {
    if #[cfg(windows)] {
        use windows::{
            core::*,
            Win32::NetworkManagement::Dns::*,
        };
        use windows_registry::LOCAL_MACHINE;
        use std::ptr::{null_mut};
        use core::ffi::{c_void};

        pub(crate) fn dns_query_srv_records(name: &str) -> Vec<String> {
            let mut records = Vec::new();

            let mut p_query_results: *mut DNS_RECORDA = null_mut();

            // SAFETY: FFI call with no outstanding preconditions.
            let dns_status = unsafe {
                DnsQuery_W(
                    &HSTRING::from(name),
                    DNS_TYPE_SRV,
                    DNS_QUERY_STANDARD,
                    None,
                    &mut p_query_results,
                    None
                )
            };

            match dns_status.ok() {
                Ok(()) => {
                    // SAFETY: `p_query_results` in non-null because `dns_status` is Ok.
                    let query_results = unsafe { *p_query_results };
                    // SAFETY: `query_results.Data` is guaranteed to contain `SRV` because
                    // of arguments to `DnsQuery_W`.
                    let p_name_target = unsafe { query_results.Data.Srv.pNameTarget };
                    let name_target = PWSTR::from_raw(p_name_target.as_ptr() as *mut u16);
                    // SAFETY: `name_target` is guaranteed to be correct at this point.
                    let name_target = unsafe {name_target.to_string()};

                    if let Ok(name_target) = name_target {
                        records.push(name_target);
                    }
                }
                Err(error) => error!(%error, "DnsQuery_W failed"),
            }

            // SAFETY: `p_query_results` is not null.
            unsafe {
                DnsFree(Some(p_query_results as *const c_void), DnsFreeRecordList);
            }

            records
        }

        pub(crate) struct DnsClientNrptRule {
            rule_name: String,
            namespace: String,
            name_servers: Vec<String>
        }

        pub(crate) fn get_dns_client_nrpt_rules() -> Vec<DnsClientNrptRule> {
            let mut rules: Vec<DnsClientNrptRule> = Vec::new();
            let hklm = LOCAL_MACHINE;
            let dns_policy_config_key_path = "System\\CurrentControlSet\\Services\\Dnscache\\Parameters\\DnsPolicyConfig";
            if let Ok(dns_policy_config_key) = hklm.open(dns_policy_config_key_path) {
                for rule_name in dns_policy_config_key.keys().unwrap() {
                    let dns_policy_rule_key_path = format!("{}\\{}", dns_policy_config_key_path, &rule_name);
                    if let Ok(dns_policy_rule_key) = hklm.open(dns_policy_rule_key_path) {
                        let namespace: Option<String> = dns_policy_rule_key.get_string("Name").ok(); // REG_MULTI_SZ
                        let name_server_list: Option<String> = dns_policy_rule_key.get_string("GenericDNSServers").ok(); // REG_SZ
                        if let (Some(namespace), Some(name_server_list)) = (namespace, name_server_list) {
                            let name_servers: Vec<String> = name_server_list.split(';').map(|x| x.to_string()).collect();
                            rules.push(DnsClientNrptRule {
                                rule_name,
                                namespace,
                                name_servers,
                            });
                        }
                    }
                }
            }
            rules
        }

        pub(crate) fn get_default_name_servers() -> Vec<String> {
            let hklm = LOCAL_MACHINE;
            let tcpip_linkage_key_path = "SYSTEM\\CurrentControlSet\\Services\\Tcpip\\Linkage";
            let tcpip_interfaces_key_path = "SYSTEM\\CurrentControlSet\\Services\\Tcpip\\Parameters\\Interfaces";
            let dns_registered_adapters_key_path = "SYSTEM\\CurrentControlSet\\Services\\Tcpip\\Parameters\\DNSRegisteredAdapters";

            if let Ok(tcpip_linkage_key) = hklm.open(tcpip_linkage_key_path) {
                let bind_devices: Vec<String> = tcpip_linkage_key.get_multi_string("Bind").unwrap();
                let device_ids = bind_devices.iter().map(|x| x.strip_prefix("\\Device\\").unwrap());

                for device_id in device_ids {
                    let interface_key_path = format!("{}\\{}", tcpip_interfaces_key_path, &device_id);
                    let dns_adapter_key_path = format!("{}\\{}", dns_registered_adapters_key_path, &device_id);

                    if let (Ok(interface_key), Ok(dns_adapter_key)) = (hklm.open(interface_key_path), hklm.open(dns_adapter_key_path)) {
                        let name_server: Option<String> = interface_key.get_string("NameServer").ok().filter(|x: &String| !x.is_empty());
                        let dhcp_name_server: Option<String> = interface_key.get_string("DhcpNameServer").ok().filter(|x: &String| !x.is_empty());
                        let stale_adapter: u32 = dns_adapter_key.get_u32("StaleAdapter").unwrap_or(1);

                        if stale_adapter != 1 {
                            if let Some(name_server_list) = name_server.or(dhcp_name_server) {
                                let name_servers: Vec<String> = name_server_list.split(' ')
                                    .map(|c| c.trim().to_string()).filter(|x: &String| !x.is_empty()).collect();
                                return name_servers;
                            }
                        }
                    }
                }
            }
            Vec::new()
        }

        pub(crate) fn get_name_servers_for_domain(domain: &str) -> Vec<String> {
            let domain_namespace = if domain.starts_with('.') {
                domain.to_string()
            } else {
                format!(".{}", &domain)
            };

            for nrpt_rule in get_dns_client_nrpt_rules() {
                if nrpt_rule.namespace.ends_with(&domain_namespace) {
                    return nrpt_rule.name_servers;
                }
            }

            get_default_name_servers()
        }

        pub(crate) fn detect_kdc_hosts_from_dns_windows(domain: &str) -> Vec<String> {
            let krb_tcp_name = &format!("_kerberos._tcp.{}", domain);
            let krb_tcp_srv = dns_query_srv_records(krb_tcp_name);

            if !krb_tcp_srv.is_empty() {
                return krb_tcp_srv.iter().map(|x| format!("tcp://{}:88", x)).collect()
            }

            let krb_udp_name = &format!("_kerberos._udp.{}", domain);
            let krb_udp_srv = dns_query_srv_records(krb_udp_name);

            if !krb_udp_srv.is_empty() {
                return krb_udp_srv.iter().map(|x| format!("udp://{}:88", x)).collect()
            }

            Vec::new()
        }
    }
}

cfg_if::cfg_if! {
    if #[cfg(any(target_os="macos", target_os="ios"))] {
        use std::time::Duration;
        use tokio::time::timeout;
        use futures::stream::{StreamExt};
        use async_dnssd::{query_record, QueryRecordResult, QueriedRecordFlags, Type};

        #[derive(Clone)]
        pub(crate) struct DnsSrvRecord {
            priority: u16,
            weight: u16,
            port: u16,
            target: String
        }

        impl From<&QueryRecordResult> for DnsSrvRecord {
            fn from(record: &QueryRecordResult) -> Self {
                let rdata = record.rdata.as_slice();
                let priority = u16::from_be_bytes(rdata[0..2].try_into().unwrap());
                let weight = u16::from_be_bytes(rdata[2..4].try_into().unwrap());
                let port = u16::from_be_bytes(rdata[4..6].try_into().unwrap());
                let target_data = &rdata[6..rdata.len()];
                DnsSrvRecord {
                    priority,
                    weight,
                    port,
                    target: dns_decode_target_data_to_string(target_data)
                }
            }
        }

        pub(crate) fn dns_decode_target_data_to_string(v: &[u8]) -> String {
            let mut names = Vec::new();

            let mut i = 0;
            while i < v.len() {
                let size = v[i] as usize;
                if size == 0 || i + 1 + size > v.len() {
                    break;
                }
                names.push(String::from_utf8_lossy(&v[i+1..i+1+size]));
                i = i + 1 + size;
            }

            names.join(".")
        }

        pub(crate) fn dns_query_srv_records(name: &str) -> Vec<DnsSrvRecord> {
            const QUERY_TIMEOUT: u64 = 1000;

            async fn query_with_timeout(name: &str, query_timeout: u64) -> Vec<DnsSrvRecord> {
                let mut dns_records: Vec<DnsSrvRecord> = Vec::new();
                let mut query = query_record(name, Type::SRV);

                loop {
                    match timeout(Duration::from_millis(query_timeout), query.next()).await {
                        Ok(Some(Ok(dns_record))) => {
                            let srv_record: DnsSrvRecord = (&dns_record).into();
                            dns_records.push(srv_record.to_owned());
                            if !dns_record.flags.contains(QueriedRecordFlags::MORE_COMING) {
                                break;
                            }
                        }
                        Ok(None) => {
                            break
                        }
                        Ok(Some(Err(error))) => {
                            error!(%error, "IO error when reading DNS query");
                            break;
                        }
                        Err(error) => {
                            error!(%error, "Timeout when reading DNS query");
                            break;
                        }
                    }
                }

                dns_records
            }

            execute_future(query_with_timeout(name, QUERY_TIMEOUT))
        }

        pub(crate) fn detect_kdc_hosts_from_dns_apple(domain: &str) -> Vec<String> {
            let krb_tcp_name = &format!("_kerberos._tcp.{}", domain);
            let krb_tcp_srv = dns_query_srv_records(krb_tcp_name);

            if !krb_tcp_srv.is_empty() {
                return krb_tcp_srv.iter().map(|x| format!("tcp://{}:{}", &x.target, x.port)).collect()
            }

            let krb_udp_name = &format!("_kerberos._udp.{}", domain);
            let krb_udp_srv = dns_query_srv_records(krb_udp_name);

            if !krb_udp_srv.is_empty() {
                return krb_udp_srv.iter().map(|x| format!("udp://{}:{}", &x.target, x.port)).collect()
            }

            Vec::new()
        }
    }
}

cfg_if::cfg_if! {
    if #[cfg(feature="dns_resolver")] {
        use hickory_resolver::TokioResolver;
        use hickory_resolver::system_conf::read_system_conf;
        use hickory_resolver::config::{ResolverConfig, NameServerConfig, ResolverOpts};
        use hickory_resolver::proto::xfer::Protocol;
        use hickory_resolver::name_server::GenericConnector;
        use hickory_proto::runtime::TokioRuntimeProvider;
        use std::env;
        use std::net::{IpAddr,SocketAddr};
        use std::str::FromStr;
        use url::Url;

        fn get_dns_name_server_from_url(url: &str) -> Option<NameServerConfig> {
            let url = if !url.contains("://") && !url.is_empty() {
                format!("udp://{}", url)
            } else {
                url.to_string()
            };

            if let Ok(url) = Url::parse(&url) {
                if let Some(url_host) = url.host_str() {
                    let url_port = url.port().unwrap_or(53);
                    let protocol = match url.scheme().to_lowercase().as_str() {
                        "tcp" => Protocol::Tcp,
                        "udp" => Protocol::Udp,
                        _ => Protocol::Udp,
                    };
                    if let Ok(ip_addr) = IpAddr::from_str(url_host) {
                        let socket_addr = SocketAddr::new(ip_addr, url_port);
                        return Some(NameServerConfig {
                            socket_addr,
                            protocol,
                            tls_dns_name: None,
                            trust_negative_responses: false,
                            http_endpoint: None,
                            bind_addr: None
                        });
                    }
                }
            }

            None
        }

        fn get_dns_resolver_from_name_servers(name_servers: Vec<String>) -> TokioResolver {
            let mut resolver_config = ResolverConfig::new();

            for name_server_url in name_servers {
                if let Some(name_server) = get_dns_name_server_from_url(&name_server_url) {
                    resolver_config.add_name_server(name_server);
                }
            }

            let mut resolver_options = ResolverOpts::default();
            resolver_options.validate = false;

            TokioResolver::builder_with_config(resolver_config, GenericConnector::new(TokioRuntimeProvider::new()))
                .with_options(resolver_options)
                .build()
        }

        #[cfg(target_os="windows")]
        fn get_dns_resolver(domain: &str) -> Option<TokioResolver> {
            let name_servers = get_name_servers_for_domain(domain);
            Some(get_dns_resolver_from_name_servers(name_servers))
        }

        #[cfg(not(target_os="windows"))]
        fn get_dns_resolver(_domain: &str) -> Option<TokioResolver> {
            if let Ok(name_server_list) = env::var("SSPI_DNS_URL") {
                let name_servers: Vec<String> = name_server_list
                    .split(',').map(|c|c.trim()).filter(|x| !x.is_empty()).map(String::from).collect();
                Some(get_dns_resolver_from_name_servers(name_servers))
            } else if let Ok((resolver_config, resolver_options)) = read_system_conf() {
                Some(TokioResolver::builder_with_config(resolver_config, GenericConnector::new(TokioRuntimeProvider::new()))
                    .with_options(resolver_options)
                    .build())
            } else {
                None
            }
        }

        pub(crate) fn detect_kdc_hosts_from_dns_resolver(domain: &str) -> Vec<String> {
            let mut kdc_hosts = Vec::new();

            if let Some(resolver) = get_dns_resolver(domain) {
                if let Ok(records) = execute_future(resolver.srv_lookup(format!("_kerberos._tcp.{}", domain))) {
                    for record in records {
                        let port = record.port();
                        let target_name = record.target().to_string();
                        let target_name = target_name.trim_end_matches('.').to_string();
                        let kdc_host = format!("tcp://{}:{}", &target_name, port);
                        kdc_hosts.push(kdc_host);
                    }
                }

                if let Ok(records) = execute_future(resolver.srv_lookup(format!("_kerberos._udp.{}", domain))) {
                    for record in records {
                        let port = record.port();
                        let target_name = record.target().to_string();
                        let target_name = target_name.trim_end_matches('.').to_string();
                        let kdc_host = format!("udp://{}:{}", &target_name, port);
                        kdc_hosts.push(kdc_host);
                    }
                }
            }

            kdc_hosts
        }
    }
}

#[cfg(any(feature = "dns_resolver", target_os = "macos", target_os = "ios"))]
fn execute_future<Fut>(fut: Fut) -> Fut::Output
where
    Fut: std::future::IntoFuture + Send,
    Fut::Output: Send,
{
    use std::thread;

    use tokio::runtime::{Builder, Handle, Runtime, RuntimeFlavor};
    use tokio::task;

    fn new_runtime() -> Runtime {
        Builder::new_current_thread().enable_all().build().unwrap()
    }

    match Handle::try_current() {
        Ok(handle) => {
            match handle.runtime_flavor() {
                RuntimeFlavor::CurrentThread => thread::scope(|s| {
                    s.spawn(move || new_runtime().block_on(fut.into_future()))
                        .join()
                        .unwrap()
                }),
                // block_in_place can't be used in current_thread runtime
                _ => task::block_in_place(move || handle.block_on(fut.into_future())),
            }
        }
        Err(_) => new_runtime().block_on(fut.into_future()),
    }
}

#[allow(unused_variables)]
#[instrument(level = "debug", ret)]
pub(crate) fn detect_kdc_hosts_from_dns(domain: &str) -> Vec<String> {
    cfg_if::cfg_if! {
        if #[cfg(windows)] {
            detect_kdc_hosts_from_dns_windows(domain)
        } else if #[cfg(any(target_os="macos", target_os="ios"))] {
            detect_kdc_hosts_from_dns_apple(domain)
        } else if #[cfg(feature="dns_resolver")] {
            detect_kdc_hosts_from_dns_resolver(domain)
        } else {
            Vec::new()
        }
    }
}
