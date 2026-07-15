use procfs::{prelude::*, CpuPressure, IoPressure, MemoryPressure, PressureRecord};

/// A basic example of /proc/pressure/ usage.
fn main() {
    if let Ok(pressure) = MemoryPressure::current() {
        println!("Memory Pressure:");
        println!("{:>10}:", "Some");
        print_pressure(pressure.some, 20);
        println!("{:>10}:", "Full");
        print_pressure(pressure.full, 20);
    }
    if let Ok(pressure) = CpuPressure::current() {
        println!("CPU Pressure:");
        print_pressure(pressure.some, 20);
    }
    if let Ok(pressure) = IoPressure::current() {
        println!("IO Pressure:");
        println!("{:>10}:", "Some");
        print_pressure(pressure.some, 20);
        println!("{:>10}:", "Full");
        print_pressure(pressure.full, 20);
    }
}

fn print_pressure(pressure: PressureRecord, width: usize) {
    println!("{:>width$}: {}", "Average 10", pressure.avg10);
    println!("{:>width$}: {}", "Average 60", pressure.avg60);
    println!("{:>width$}: {}", "Average 300", pressure.avg300);
    println!("{:>width$}: {}", "Total", pressure.total);
}
