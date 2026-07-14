#[tokio::main(flavor = "current_thread")]
async fn main() -> std::io::Result<()> {
	// Use `cargo run --example register`

	let (_registration, result) = async_dnssd::register("_ssh._tcp", 2022)?.await?;
	println!("Registered: {:?}", result);

	// wait until killed
	futures::future::pending::<()>().await;
	Ok(())
}
