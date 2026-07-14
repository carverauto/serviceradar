# Benchmarking

We implement benchmark here with comparisons against some popular alternative parsers.

## Setting Up

Run `bash download.sh` to download test data files to `/tmp` directory.

## Run benchmarks

Run `cargo bench` anywhere in the project will run all benchmarks.

## Implemented Benchmarks

- [X] BGPKIT Parser
- [X] [bgpdump](https://github.com/RIPE-NCC/bgpdump)
- [ ] [libparsebgp](https://github.com/CAIDA/libparsebgp)
- [ ] [bgpscanner](https://gitlab.com/Isolario/bgpscanner)
- [ ] [micro bgp suite](https://git.doublefourteen.io/bgp/ubgpsuite)
- [ ] [mrt-parser](https://github.com/sdstrowes/mrt-parser)