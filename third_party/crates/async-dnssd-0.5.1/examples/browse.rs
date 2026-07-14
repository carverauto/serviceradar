use async_dnssd::{
	ResolvedHostFlags,
	StreamTimeoutExt,
	TxtRecord,
};
use futures::prelude::*;
use std::{
	env,
	time::Duration,
};
use tokio::spawn;

#[tokio::main(flavor = "current_thread")]
async fn main() {
	let search_timeout = Duration::from_secs(10);
	let resolve_timeout = Duration::from_secs(3);
	let address_timeout = Duration::from_secs(3);

	// MetaQuery to list all services available.
	let list_all_services = "_services._dns-sd._udp";

	// Use `cargo run --example browse` to list all services broadcasting
	// or `cargo run --example browse -- _http._tcp` to resolve a service.
	let query = &env::args()
		.nth(1)
		.unwrap_or_else(|| list_all_services.to_string());
	println!("Browse: {}", query);

	let query_result = async_dnssd::browse(query).timeout(search_timeout);
	query_result
		.try_for_each(move |service| {
			async move {
				let added = service.flags.contains(async_dnssd::BrowsedFlags::ADD);
				if query == list_all_services {
					// resolving MetaQuery responses isn't useful (and fails
					// with "bad param")... we'd need to browse them

					let mut reg_type = service.reg_type.as_str();
					if reg_type.ends_with('.') {
						reg_type = &reg_type[..reg_type.len() - 1];
					}
					let reg_type = service.service_name.clone() + "." + reg_type;
					println!(
						"Service Type {}{:?}@{:?}\t\t[{:?}]",
						if added { '+' } else { '-' },
						reg_type,
						service.domain,
						service
					);

					return Ok(());
				}

				println!(
					"Service {}{:?}@{:?} (type {:?})\t\t[{:?}]",
					if added { '+' } else { '-' },
					service.service_name,
					service.domain,
					service.reg_type,
					service
				);

				if !added {
					// only resolve added services
					return Ok(());
				}

				spawn(async move {
					let resolve = service.resolve().timeout(resolve_timeout);
					let service = &service;
					if let Err(e) = resolve
						.try_for_each(move |r| {
							async move {
								let txt = TxtRecord::parse(&r.txt).map(|rdata| {
									rdata
										.iter()
										.map(|(key, value)| {
											(
												String::from(String::from_utf8_lossy(key)),
												value.map(|value| {
													String::from(String::from_utf8_lossy(value))
												}),
											)
										})
										.collect::<Vec<_>>()
								});
								println!(
									"Resolved {:?} on {:?}: {:?}:{} (txt {:?})\t\t[{:?}]",
									service.service_name,
									r.interface,
									r.host_target,
									r.port,
									txt,
									r
								);
								let fullname = r.fullname.clone();
								let host_target_e = r.host_target.clone();
								spawn(
									// Query IPv4 + IPv6
									r.resolve_socket_address()
										.timeout(address_timeout)
										.try_for_each(move |result| {
											if result.flags.intersects(ResolvedHostFlags::ADD) {
												println!(
													"Address for {}: {}",
													fullname, result.address
												);
											}
											futures::future::ok(())
										})
										.map(move |r| {
											if let Err(e) = r {
												println!(
													"query_record {} failed: {}",
													host_target_e, e
												);
											}
										}),
								);
								Ok(())
							}
						})
						.await
					{
						println!("resolve {:?} failed: {}", service.service_name, e);
					}
				});

				Ok(())
			}
		})
		.await
		.unwrap();
}
