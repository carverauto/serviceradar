use criterion::{criterion_group, criterion_main, Criterion};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

mod data_source;

#[derive(Copy, Clone, Debug)]
struct BgpReader<'s> {
    name: &'s str,
    executable: &'s str,
    args: &'s [&'s str],
}

/// Alternate BGP reading programs to test against listed as the executable name and additional
/// command line arguments. When executed the specified arguments will be added before the input
/// file.
const BGP_READERS: &[BgpReader<'static>] = &[
    BgpReader {
        name: "bgpkit",
        executable: "bgpkit-parser",
        args: &[],
    },
    BgpReader {
        name: "bgpdump",
        executable: "bgpdump",
        args: &["-M"],
    },
    // The remaining items have not been tested. While I attempted to find the correct executable
    // names and arguments, some may not be correct.
    BgpReader {
        name: "libparsebgp",
        executable: "libparsebgp",
        args: &[],
    },
    // Micro BGP Suite also provides a legacy wrapper under bgpscanner's name, so it may be
    // difficult to determine if which version is being used.
    BgpReader {
        name: "bgpscanner",
        executable: "bgpscanner",
        args: &[],
    },
    BgpReader {
        name: "Micro BGP Suite",
        executable: "bgpgrep",
        args: &[],
    },
    #[cfg(unix)]
    BgpReader {
        name: "mrt-parser",
        executable: "mrt",
        args: &["-f"],
    },
];

fn perform_run(executable: &PathBuf, args: &[&str], input_file: &PathBuf) -> Duration {
    // Setup execution of the command
    let mut command_setup = Command::new(executable);
    command_setup
        .args(args)
        .arg(input_file)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        // As much as I would like inherit the stderr, some of these programs will just spam the
        // console with useless logging information.
        .stderr(Stdio::null());

    let start_time = Instant::now();
    let status = command_setup.status();
    let elapsed = start_time.elapsed();

    // Check to ensure command was successful
    match status {
        Ok(a) if a.success() => {}
        Ok(status) => panic!(
            "{} exited with failing status code {}",
            executable.display(),
            status
        ),
        Err(err) => panic!(
            "An error occurred while attempting to run {}: {}",
            executable.display(),
            err
        ),
    }

    elapsed
}

fn benchmark(c: &mut Criterion) {
    let mut programs_to_test = Vec::new();

    for &program in BGP_READERS {
        let BgpReader {
            name,
            executable,
            args,
        } = program;

        let path_result = match executable {
            // Ensure we always use the latest build of the project. Optimized binary targets are
            // compiled before benchmarks to allow for integration tests so it will always be found
            // at this path.
            "bgpkit-parser" => Ok(data_source::locate_target_dir().join("release/bgpkit-parser")),
            // For remaining programs use which crate to locate their executables on the system
            name => which::which(name),
        };

        match path_result {
            Ok(path) => {
                println!(
                    "Benchmarking {} using: {} {} [input file]",
                    name,
                    path.display(),
                    args.join(" ")
                );
                programs_to_test.push((program, path));
            }
            Err(err) => {
                println!("Unable to locate executable for {name}: {err}");
            }
        }
    }

    let update_data = data_source::test_data_file("update-example.gz");
    let mut update_group = c.benchmark_group("update-data.gz");

    for (program, path) in &programs_to_test {
        update_group.bench_function(program.name, |b| {
            b.iter_custom(|n| {
                let mut total_elapsed = Duration::default();

                for _ in 0..n {
                    total_elapsed += perform_run(path, program.args, &update_data);
                }

                total_elapsed
            })
        });
    }

    update_group.finish();

    let rib_data = data_source::test_data_file("rib-example-small.bz2");
    let mut rib_group = c.benchmark_group("rib-data.bz2");

    // The file is fairly large when decompressed, so we only do a couple iterations
    rib_group.sample_size(10);

    for (program, path) in &programs_to_test {
        rib_group.bench_function(program.name, |b| {
            b.iter_custom(|n| {
                let mut total_elapsed = Duration::default();

                for _ in 0..n {
                    total_elapsed += perform_run(path, program.args, &rib_data);
                }

                total_elapsed
            })
        });
    }

    rib_group.finish();
}

criterion_group!(benches, benchmark);
criterion_main!(benches);
