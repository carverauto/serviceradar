use clap::{Parser, Subcommand};
use std::io::Write;
use std::io::{BufRead, BufReader};
use std::path::PathBuf;
use std::process::exit;

#[derive(Parser)]
#[clap(author, version)]
#[clap(propagate_version = true)]
#[command(arg_required_else_help(true))]
/// oneio reads files from local or remote locations with any compression.
struct Cli {
    /// file to open, remote or local
    #[clap(name = "FILE")]
    file: Option<PathBuf>,

    /// download the file to the current directory, similar to run `wget`
    #[clap(short, long)]
    download: bool,

    /// output file path
    #[clap(short, long)]
    outfile: Option<PathBuf>,

    /// cache reading to a specified directory
    #[clap(long)]
    cache_dir: Option<String>,

    /// force re-caching if a local cache already exists
    #[clap(long)]
    cache_force: bool,

    /// specify cache file name
    #[clap(long)]
    cache_file: Option<String>,

    /// read through the file and only print out stats
    #[clap(short, long)]
    stats: bool,

    #[clap(subcommand)]
    command: Option<Commands>,
}

#[derive(Subcommand)]
enum Commands {
    /// S3-related subcommands
    S3 {
        #[clap(subcommand)]
        s3_command: S3Commands,
    },

    /// Generate SHA256 digest
    Digest {
        /// file to open, remote or local
        #[clap(name = "FILE")]
        file: PathBuf,
    },
}

#[derive(Subcommand)]
enum S3Commands {
    /// Upload file to S3
    Upload {
        /// S3 bucket name
        #[clap()]
        bucket: String,

        /// S3 file path
        #[clap()]
        path: String,
    },
    /// List S3 bucket
    List {
        /// S3 bucket name
        #[clap()]
        bucket: String,

        /// S3 file path
        #[clap(default_value = "")]
        prefix: String,

        /// delimiter for directory listing
        #[clap(short, long)]
        delimiter: Option<String>,

        /// showing directories only
        #[clap(short, long)]
        dirs: bool,
    },
}

fn main() {
    let cli = Cli::parse();
    let outfile: Option<PathBuf> = cli.outfile;

    if let Some(command) = cli.command {
        match command {
            Commands::S3 { s3_command } => match s3_command {
                S3Commands::Upload {
                    bucket: s3_bucket,
                    path: s3_path,
                } => {
                    if let Err(e) = oneio::s3_env_check() {
                        eprintln!("missing s3 credentials");
                        eprintln!("{e}");
                        exit(1);
                    }
                    let path_string = cli.file.clone().unwrap().to_str().unwrap().to_string();
                    match oneio::s3_upload(
                        s3_bucket.as_str(),
                        s3_path.as_str(),
                        path_string.as_str(),
                    ) {
                        Ok(_) => {
                            println!("file successfully uploaded to s3://{s3_bucket}/{s3_path}");
                        }
                        Err(e) => {
                            eprintln!("file upload error: {e}");
                        }
                    }
                    return;
                }
                S3Commands::List {
                    bucket,
                    prefix,
                    delimiter,
                    dirs,
                } => {
                    if let Err(e) = oneio::s3_env_check() {
                        eprintln!("missing s3 credentials");
                        eprintln!("{e}");
                        exit(1);
                    }
                    match oneio::s3_list(bucket.as_str(), prefix.as_str(), delimiter, dirs) {
                        Ok(paths) => {
                            paths.iter().for_each(|p| println!("{p}"));
                        }
                        Err(e) => {
                            eprintln!("unable to list bucket content");
                            eprintln!("{e}");
                            exit(1);
                        }
                    }
                    return;
                }
            },
            Commands::Digest { file } => {
                let path_string = file.as_path().to_string_lossy().to_string();
                println!(
                    "{}",
                    oneio::get_sha256_digest(path_string.as_str()).unwrap()
                );
                return;
            }
        }
    }

    let path_string = cli.file.clone().unwrap().to_str().unwrap().to_string();
    let path = path_string.as_str();

    if cli.download {
        let out_path = match outfile {
            None => path
                .split('/')
                .next_back()
                .unwrap_or("output.txt")
                .to_string(),
            Some(p) => p.to_str().unwrap().to_string(),
        };

        match oneio::download(path, out_path.as_str(), None) {
            Ok(_) => {
                println!("file successfully downloaded to {}", out_path.as_str());
            }
            Err(e) => {
                eprintln!("file download error: {e}");
            }
        }

        return;
    }

    let reader = Box::new(BufReader::new(match cli.cache_dir {
        Some(dir) => {
            match oneio::get_cache_reader(path, dir.as_str(), cli.cache_file, cli.cache_force) {
                Ok(reader) => reader,
                Err(e) => {
                    eprintln!("Cannot open {path}: {e}");
                    return;
                }
            }
        }
        None => match oneio::get_reader(path) {
            Ok(reader) => reader,
            Err(e) => {
                eprintln!("Cannot open {path}: {e}");
                return;
            }
        },
    }));

    let mut stdout = std::io::stdout();

    let mut count_lines = 0;
    let mut count_chars = 0;

    for line in reader.lines() {
        let line = match line {
            Ok(l) => l,
            Err(e) => {
                eprintln!("Cannot read line from {path}: {e}");
                exit(1);
            }
        };
        if !cli.stats {
            if let Err(e) = writeln!(stdout, "{line}") {
                if e.kind() != std::io::ErrorKind::BrokenPipe {
                    eprintln!("{e}");
                    exit(1);
                }
                exit(0);
            }
        }
        count_chars += line.chars().count();
        count_lines += 1;
    }

    if cli.stats {
        println!("lines: \t {count_lines}");
        println!("chars: \t {count_chars}");
    }
}
