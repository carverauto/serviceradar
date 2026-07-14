use futures::prelude::*;

#[tokio::main(flavor = "current_thread")]
async fn main() -> std::io::Result<()> {
	// Use `cargo run --example enumerate-domains`

	async_dnssd::enumerate_domains(
		async_dnssd::Enumerate::BrowseDomains,
		async_dnssd::Interface::Any,
	)
	.for_each(|e| async move {
		println!("Domain: {:?}", e);
	})
	.await;

	Ok(())
}
