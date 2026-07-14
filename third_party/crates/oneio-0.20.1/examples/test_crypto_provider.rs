//! Example demonstrating crypto provider initialization.
//!
//! This example shows how to explicitly initialize the crypto provider
//! before making HTTPS requests. While oneio now initializes the provider
//! automatically, you can still call it explicitly for clarity or to handle
//! initialization errors early.

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Initialize crypto provider explicitly
    oneio::crypto::ensure_default_provider()?;
    println!("✓ Crypto provider initialized successfully!");

    // Test HTTPS download - crypto provider is already set up
    println!("\nDownloading test file via HTTPS...");
    let content = oneio::read_to_string("https://spaces.bgpkit.org/oneio/test_data.txt")?;
    println!("✓ Downloaded content:\n{}", content.trim());

    println!("\n✓ All operations completed successfully!");
    Ok(())
}
