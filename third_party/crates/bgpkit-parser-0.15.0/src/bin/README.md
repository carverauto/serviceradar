# BGPKIT Parser Cli

`bgpkit-parser-cli` is a simple commandline tool interface for `bgpkit-parser`.

## Usage

```
➜  cli git:(cli) ✗ bgpkit-parser-cli 0.1.0

Mingwei Zhang <mingwei@bgpkit.com>

bgpkit-parser-cli is a simple cli tool that allow parsing of individual MRT files

USAGE:
    bgpkit-parser-cli [FLAGS] [OPTIONS] <FILE>

FLAGS:
    -e, --elems-count      Count BGP elems
    -h, --help             Prints help information
        --json             Output as JSON objects
        --pretty           Pretty-print JSON output
    -r, --records-count    Count MRT records
    -V, --version          Prints version information

OPTIONS:
    -a, --as-path <as-path>          Filter by AS path regex string
    -m, --elem-type <elem-type>      Filter by elem type: announce (a) or withdraw (w)
    -T, --end-ts <end-ts>            Filter by end unix timestamp inclusive
    -o, --origin-asn <origin-asn>    Filter by origin AS Number
    -J, --peer-asn <peer-asn>        Filter by peer IP ASN
    -j, --peer-ip <peer-ip>          Filter by peer IP address
    -p, --prefix <prefix>            Filter by network prefix
    -t, --start-ts <start-ts>        Filter by start unix timestamp inclusive
```

## Examples

### Parse local file

```
bgpkit-parser-cli /tmp/update-example.gz |tail
A|1637437799|185.1.8.65|60924|186.233.208.0/22|60924 6939 57463 271253 271253 264556 262873 262793|IGP|185.1.8.63|0|0|60924:6 60924:150 60924:502 60924:2002|NAG||
A|1637437799|185.1.8.65|60924|186.233.208.0/21|60924 6939 57463 271253 271253 264556 262873 262793|IGP|185.1.8.63|0|0|60924:6 60924:150 60924:502 60924:2002|NAG||
A|1637437799|185.1.8.65|60924|143.137.53.0/24|60924 6939 57463 271253 271253 264556 262873 264031|IGP|185.1.8.63|0|0|60924:6 60924:150 60924:502 60924:2002|NAG||
A|1637437799|2001:7f8:73::edfc:0:2|60924|2607:fdf0:5e54::/48|60924 59605 6453 1299 13807 8008|IGP||0|0|60924:6 60924:150 60924:502 60924:2002|NAG||
...
```

### Parse remote file

```
bgpkit-parser-cli http://archive.routeviews.org/route-views.bdix/bgpdata/2021.11/UPDATES/updates.20211127.1900.bz2 |tail
A|1638040499.820021|103.151.196.1|140684|103.139.144.0/24|58689 139192|IGP|103.151.196.177|0|0||NAG||
A|1638040499.842529|103.151.196.1|140684|103.139.144.0/24|58689 139192|IGP|103.151.196.88|0|0||NAG||
A|1638040499.842567|103.151.196.5|140684|103.139.144.0/24|58689 139192|IGP|103.151.196.88|0|0||NAG||
A|1638040500.212436|103.151.196.1|140684|103.139.144.0/24|58689 139192|IGP|103.151.196.177|0|0||NAG||
...
```

### Count file's MRT records and BGP messages

```
bgpkit-parser-cli http://archive.routeviews.org/route-views.bdix/bgpdata/2021.11/UPDATES/updates.20211127.1900.bz2 -e -r
total records: 15678
total elems:   15722
```

### Use filters

Available filters are:
```text
    -a, --as-path <as-path>          Filter by AS path regex string
    -m, --elem-type <elem-type>      Filter by elem type: announce (a) or withdraw (w)
    -o, --origin-asn <origin-asn>    Filter by origin AS Number
    -J, --peer-asn <peer-asn>        Filter by peer IP ASN
    -j, --peer-ip <peer-ip>          Filter by peer IP address
    -p, --prefix <prefix>            Filter by network prefix
    -t, --start-ts <start-ts>        Filter by start unix timestamp inclusive
    -T, --end-ts <end-ts>            Filter by end unix timestamp inclusive
```

For example, filter by peer IP address:
```
bgpkit-parser-cli http://archive.routeviews.org/route-views.bdix/bgpdata/2021.11/UPDATES/updates.20211127.1900.bz2 --peer-ip 103.151.196.1
A|1638039600.519347|103.151.196.1|140684|103.139.144.0/24|58689 139192|IGP|103.151.196.177|0|0||NAG||
A|1638039600.570541|103.151.196.1|140684|103.139.144.0/24|134146 134146 134146 134146 58689 139192|IGP|103.151.196.183|0|4||NAG||
W|1638039600.588036|103.151.196.1|140684|103.139.144.0/24|||||||||
A|1638039600.635757|103.151.196.1|140684|103.139.144.0/24|134146 134146 134146 134146 23956 58689 139192|IGP|103.151.196.183|0|4||NAG||
...
```

Multiple filters can be used to construct a combination of filters.
For example, filter by peer IP address and keep only the withdraws:
```
bgpkit-parser-cli http://archive.routeviews.org/route-views.bdix/bgpdata/2021.11/UPDATES/updates.20211127.1900.bz2 --peer-ip 103.151.196.1 --elem-type w |head
W|1638039600.588036|103.151.196.1|140684|103.139.144.0/24|||||||||
W|1638039600.909854|103.151.196.1|140684|103.139.144.0/24|||||||||
W|1638039601.908543|103.151.196.1|140684|103.139.144.0/24|||||||||
W|1638039602.266345|103.151.196.1|140684|103.139.144.0/24|||||||||
...
```
