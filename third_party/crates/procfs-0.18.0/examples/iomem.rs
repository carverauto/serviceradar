//
// Print physical location of system RAM
// This requires CAP_SYS_ADMIN privilege, or root, otherwise physical memory addresses will be zero
//

fn main() {
    if !rustix::process::geteuid().is_root() {
        println!("WARNING: Access to /proc/iomem requires root, re-run with sudo");
    }

    let iomem = procfs::iomem().expect("Can't read /proc/iomem");

    for (_indent, map) in iomem.iter() {
        if map.name == "System RAM" {
            println!("Found RAM here: 0x{:x}-0x{:x}", map.address.0, map.address.1);
        }
    }

    if !rustix::process::geteuid().is_root() {
        println!("\n\nWARNING: Access to /proc/iomem requires root, re-run with sudo");
    }
}
