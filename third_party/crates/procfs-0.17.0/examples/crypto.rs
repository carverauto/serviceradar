use std::env::args;

use procfs::crypto;

pub fn main() {
    let crypto = crypto().expect("Was not able to access current crypto");
    let name_arg = args().nth(1);
    for (name, entries) in crypto.crypto_blocks {
        if let Some(ref name_find) = name_arg {
            if !name.contains(name_find) {
                continue;
            }
        }
        println!("Type: {name}");
        for block in entries {
            println!("{:>14}: {}", "Name", block.name);
            println!("{:>14}: {}", "Driver", block.driver);
            println!("{:>14}: {}", "Module", block.module);
            println!("{:>14}: {}", "Priority", block.priority);
            println!("{:>14}: {}", "Ref Count", block.ref_count);
            println!("{:>14}: {:?}", "Self Test", block.self_test);
            println!("{:>14}: {}", "Internal", block.internal);
            println!("{:>14}: {}", "fips enabled", block.fips_enabled);
            println!("{:>14}: {:?}", "Type Details", block.crypto_type);
            println!();
        }
    }
}
