// List partitions listed in /proc/partitions

fn main() {
    for part_entry in procfs::partitions().unwrap() {
        println!("{part_entry:?}");
    }
}
