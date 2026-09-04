//! Compiles a documented subset of tcpdump filter syntax to classic BPF.
//!
//! This is the second of remote capture's two filter front doors. An RPCAP
//! client sends a program its own libpcap compiled; the control plane sends an
//! expression string, which this module compiles into the same
//! [`Program`](super::bpf::Program). Both end at one `SO_ATTACH_FILTER` call,
//! so there is no second filter semantics to keep in sync.
//!
//! # The rule this module exists to enforce
//!
//! **Never widen a filter that was not fully understood.** A capture that
//! silently returns more than was asked for is a data-exfiltration surface; one
//! that silently returns less is the "reported success while writing nothing"
//! shape this repository keeps re-learning. Every construct outside the grammar
//! below is refused by name, never approximated.
//!
//! That rule is why two details here look like over-engineering and are not.
//! Both were verified against `tcpdump -d` on Linux 6.8:
//!
//! * **IPv4 port matching needs a fragment guard.** Without
//!   `ldh [20] & 0x1fff == 0`, a filter matches non-first fragments whose bytes
//!   at the port offset are payload rather than ports — silently widening.
//! * **IPv4 port matching needs the variable header length.** A fixed 20-byte
//!   assumption misses every packet carrying IP options — silently narrowing.
//!   The offset comes from `BPF_LDX|BPF_B|BPF_MSH`, which loads `4 * ([14] & 0xf)`.
//!
//! # Grammar
//!
//! ```text
//! expr    := not ( ("and" | "&&" | "or" | "||") not )*     // ONE level, left-assoc
//! not     := ("not" | "!") not | primary
//! primary := "(" expr ")" | primitive
//! primitive :=
//!     "ip" | "ip6" | "arp" | "tcp" | "udp" | "icmp" | "icmp6"
//!   | "inbound" | "outbound"
//!   | dir? "host" ADDR
//!   | dir? "net" CIDR
//!   | proto? dir? "port" NUM
//!   | proto? dir? "portrange" NUM "-" NUM
//! dir     := "src" | "dst"
//! proto   := "tcp" | "udp"
//! ```

use std::net::Ipv4Addr;

use thiserror::Error;

use super::bpf::{
    BPF_ABS, BPF_ALU, BPF_AND, BPF_B, BPF_H, BPF_IND, BPF_JEQ, BPF_JGE, BPF_JGT, BPF_JMP, BPF_JSET,
    BPF_K, BPF_LD, BPF_LDX, BPF_MSH, BPF_RET, BPF_W, Instruction, PACKET_OUTGOING, Program,
    ProgramError, SKF_AD_OFF, SKF_AD_PKTTYPE,
};

// Ethernet.
const OFF_ETHERTYPE: u32 = 12;
const ETHERTYPE_IP: u32 = 0x0800;
const ETHERTYPE_IP6: u32 = 0x86dd;
const ETHERTYPE_ARP: u32 = 0x0806;
const ETHERTYPE_RARP: u32 = 0x8035;

// IPv4, relative to the start of the Ethernet frame.
const OFF_IP4_FLAGS: u32 = 20;
const OFF_IP4_PROTO: u32 = 23;
const OFF_IP4_SRC: u32 = 26;
const OFF_IP4_DST: u32 = 30;
const IP4_FRAGMENT_MASK: u32 = 0x1fff;
const OFF_IP4_HEADER: u32 = 14;

// ARP/RARP sender and target protocol addresses.
const OFF_ARP_SPA: u32 = 28;
const OFF_ARP_TPA: u32 = 38;

// IPv6.
const OFF_IP6_NEXT_HEADER: u32 = 20;
const OFF_IP6_FRAG_NEXT_HEADER: u32 = 54;
const OFF_IP6_PORTS: u32 = 54;
const IP6_FRAGMENT_HEADER: u32 = 44;

const IPPROTO_ICMP: u32 = 1;
const IPPROTO_TCP: u32 = 6;
const IPPROTO_UDP: u32 = 17;
const IPPROTO_ICMP6: u32 = 58;
const IPPROTO_SCTP: u32 = 132;

/// Why an expression was refused.
///
/// Carries the offending text so an operator sees which token failed, not just
/// that something did.
#[derive(Debug, Error, PartialEq, Eq)]
pub enum FilterError {
    #[error("capture filter is empty")]
    Empty,

    #[error(
        "unsupported filter construct `{0}`; supported: ip, ip6, arp, tcp, udp, icmp, icmp6, host, net, port, portrange, src, dst, inbound, outbound, and, or, not"
    )]
    Unsupported(String),

    #[error("unexpected `{0}` in capture filter")]
    Unexpected(String),

    #[error("capture filter ended unexpectedly; expected {0}")]
    UnexpectedEnd(&'static str),

    #[error("`{0}` is not a valid IPv4 address")]
    BadAddress(String),

    #[error("`{0}` is not a valid IPv4 CIDR block")]
    BadCidr(String),

    #[error("`{0}` is not a valid port number")]
    BadPort(String),

    #[error("port range `{lo}-{hi}` is inverted")]
    InvertedRange { lo: u16, hi: u16 },

    #[error("capture filter is too complex: {0}")]
    TooComplex(&'static str),

    #[error("`{modifier}` cannot be applied to `{primitive}`")]
    ModifierNotApplicable {
        modifier: &'static str,
        primitive: &'static str,
    },

    #[error(transparent)]
    Program(#[from] ProgramError),
}

/// Compile an expression into an attachable program.
///
/// `snaplen` becomes the accept return value, which is how cBPF expresses how
/// many bytes of a matching frame the kernel copies.
pub fn compile(expression: &str, snaplen: u32) -> Result<Program, FilterError> {
    let tokens = tokenize(expression)?;
    let mut parser = Parser {
        tokens: &tokens,
        pos: 0,
        depth: 0,
        terms: 0,
    };
    let expr = parser.parse_expr()?;
    parser.expect_end()?;
    Codegen::new(snaplen).emit(&expr)
}

// ---------------------------------------------------------------------------
// Tokens
// ---------------------------------------------------------------------------

fn tokenize(input: &str) -> Result<Vec<String>, FilterError> {
    let mut tokens = Vec::new();
    let mut current = String::new();

    for ch in input.chars() {
        match ch {
            '(' | ')' => {
                if !current.is_empty() {
                    tokens.push(std::mem::take(&mut current));
                }
                tokens.push(ch.to_string());
            }
            c if c.is_whitespace() => {
                if !current.is_empty() {
                    tokens.push(std::mem::take(&mut current));
                }
            }
            c => current.push(c.to_ascii_lowercase()),
        }
    }
    if !current.is_empty() {
        tokens.push(current);
    }
    if tokens.is_empty() {
        return Err(FilterError::Empty);
    }
    Ok(tokens)
}

// ---------------------------------------------------------------------------
// AST
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Dir {
    Src,
    Dst,
    Either,
}

impl Dir {
    fn name(self) -> &'static str {
        match self {
            Self::Src => "src",
            Self::Dst => "dst",
            Self::Either => "",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum Expr {
    And(Box<Expr>, Box<Expr>),
    Or(Box<Expr>, Box<Expr>),
    Not(Box<Expr>),

    EtherType(u32),
    /// IPv4 protocol byte, or the IPv6 next-header equivalent, or both.
    IpProto {
        v4: bool,
        v6: bool,
        proto: u32,
    },
    Host {
        addr: Ipv4Addr,
        dir: Dir,
    },
    Net {
        addr: Ipv4Addr,
        mask: u32,
        dir: Dir,
    },
    Port {
        lo: u16,
        hi: u16,
        dir: Dir,
        proto: Option<u32>,
    },
    Outbound,
}

/// How deeply `not` and parentheses may nest.
///
/// Generous for anything an operator writes by hand -- tcpdump's own examples
/// never exceed three -- and far below the depth at which the recursive-descent
/// parser exhausts the stack, measured between 1,000 and 1,200 levels on a
/// 2 MiB tokio worker stack in a debug build.
const MAX_PARSE_DEPTH: usize = 64;

/// How many terms one expression may contain.
///
/// # Nesting depth is not the same bound, and only bounding it left the crash open
///
/// `parse_expr` consumes an `and`/`or` chain in a LOOP, so `tcp or tcp or ...`
/// never drives the depth counter above 1 -- while the tree it builds leans
/// left one level per operator. Two unguarded recursive walks then run over
/// that spine: [`Codegen::expr`], which recurses into its left operand for
/// every `And`/`Or`, and the derived `Drop` for `Box<Expr>`.
///
/// Measured on the committed code, through the real entry point, on a tokio
/// worker's 2 MiB stack: `"tcp or ".repeat(19_000) + "tcp"` -- 133 KB, against a
/// 4 MiB frame cap -- aborts with `fatal runtime error: stack overflow`. A
/// depth guard alone therefore fixed the shape that was easy to think of and
/// left the process just as killable by the shape that was not. `and`, `||` and
/// chains of distinct primitives all abort at the same order of magnitude.
///
/// Terms are charged instead, which bounds the tree by construction whatever
/// its shape.
///
/// 1024 is far past anything that can ever produce a valid program. Measured on
/// this compiler: an `or` chain stops compiling at about 29 terms, refused with
/// "jump offset exceeds 255" -- classic BPF jump offsets are 8-bit, so long
/// chains are unrepresentable no matter what this limit says. That existing
/// error is not a substitute for this one, because it is raised in `resolve()`,
/// which runs AFTER `Codegen::emit` has already recursed the tree. This guard
/// exists purely to stop the recursion before it starts, and 1024 keeps roughly
/// a 5x margin below the shallowest measured overflow (~5,000 terms, debug
/// build, 2 MiB stack) while sitting ~35x above any filter that can compile.
const MAX_PARSE_TERMS: usize = 1024;

struct Parser<'a> {
    tokens: &'a [String],
    pos: usize,
    /// Bounded so a malformed expression cannot abort the process; see
    /// [`Parser::parse_not`].
    depth: usize,
    /// Terms consumed so far. Bounds the AST's SIZE, which is what the
    /// unguarded recursion in codegen actually walks; see [`MAX_PARSE_TERMS`].
    terms: usize,
}

impl<'a> Parser<'a> {
    fn peek(&self) -> Option<&'a str> {
        self.tokens.get(self.pos).map(String::as_str)
    }

    fn next(&mut self) -> Option<&'a str> {
        let t = self.tokens.get(self.pos).map(String::as_str);
        if t.is_some() {
            self.pos += 1;
        }
        t
    }

    fn expect_end(&self) -> Result<(), FilterError> {
        match self.peek() {
            None => Ok(()),
            Some(t) => Err(FilterError::Unexpected(t.to_string())),
        }
    }

    /// `and` and `or` share ONE precedence level and associate left to right.
    ///
    /// This is not the usual boolean precedence and it is not a simplification:
    /// libpcap's grammar declares `%left OR AND`, so `a or b and c` parses as
    /// `(a or b) and c`, not `a or (b and c)`. Verified against tcpdump 4.99.4
    /// on Linux 6.8 -- `tcp or udp and port 53` compiles to a byte-identical
    /// program to `(tcp or udp) and port 53` and a different one from
    /// `tcp or (udp and port 53)`.
    ///
    /// Implementing the conventional precedence here made every unparenthesised
    /// mixed expression compile to a filter that differed from tcpdump, which
    /// is the silent-widening the never-widen rule forbids.
    fn parse_expr(&mut self) -> Result<Expr, FilterError> {
        let mut left = self.parse_not()?;
        loop {
            let combine = match self.peek() {
                Some("and" | "&&") => true,
                Some("or" | "||") => false,
                _ => break,
            };
            self.next();
            let right = self.parse_not()?;
            left = if combine {
                Expr::And(Box::new(left), Box::new(right))
            } else {
                Expr::Or(Box::new(left), Box::new(right))
            };
        }
        Ok(left)
    }

    /// Every recursive path in this parser passes through here -- `parse_expr`
    /// calls it, and `parse_primary` reaches it again through `parse_expr` on
    /// an opening paren -- so one guard here bounds all of them.
    ///
    /// Without it the parser aborts the PROCESS on deep nesting. Measured, not
    /// theorised: `"(".repeat(10_000) + "tcp" + ")".repeat(10_000)` printed
    /// `thread 'main' has overflowed its stack / fatal runtime error: stack
    /// overflow, aborting`. A stack overflow is not a catchable error, so this
    /// is not "a bad filter is rejected" -- it is netprobe dying, taking eBPF
    /// flow attribution and the device census with it, from one string an
    /// operator typed.
    ///
    /// That string now arrives over IPC from the control plane, and will
    /// eventually arrive from an RPCAP client, so the input is not trusted.
    fn parse_not(&mut self) -> Result<Expr, FilterError> {
        // Charged before the depth check and never refunded: this counts how
        // big the tree is, not how deep the parser currently is, because the
        // recursion that actually overflows walks the finished tree.
        self.terms += 1;
        if self.terms > MAX_PARSE_TERMS {
            return Err(FilterError::TooComplex(
                "filter has too many terms (limit: 1024)",
            ));
        }

        self.depth += 1;
        if self.depth > MAX_PARSE_DEPTH {
            return Err(FilterError::TooComplex(
                "filter nesting is too deep (limit: 64 levels, counting the expression itself)",
            ));
        }
        let result = self.parse_not_inner();
        self.depth -= 1;
        result
    }

    fn parse_not_inner(&mut self) -> Result<Expr, FilterError> {
        if matches!(self.peek(), Some("not" | "!")) {
            self.next();
            return Ok(Expr::Not(Box::new(self.parse_not()?)));
        }
        self.parse_primary()
    }

    fn parse_primary(&mut self) -> Result<Expr, FilterError> {
        if self.peek() == Some("(") {
            self.next();
            let inner = self.parse_expr()?;
            match self.next() {
                Some(")") => return Ok(inner),
                Some(t) => return Err(FilterError::Unexpected(t.to_string())),
                None => return Err(FilterError::UnexpectedEnd("`)`")),
            }
        }
        self.parse_primitive()
    }

    fn parse_primitive(&mut self) -> Result<Expr, FilterError> {
        // Optional protocol qualifier, only meaningful before `port`.
        let mut proto: Option<u32> = None;
        if matches!(self.peek(), Some("tcp" | "udp"))
            && matches!(
                self.tokens.get(self.pos + 1).map(String::as_str),
                Some("port" | "portrange" | "src" | "dst")
            )
        {
            proto = Some(match self.next() {
                Some("tcp") => IPPROTO_TCP,
                _ => IPPROTO_UDP,
            });
        }

        let mut dir = Dir::Either;
        if matches!(self.peek(), Some("src" | "dst")) {
            dir = match self.next() {
                Some("src") => Dir::Src,
                _ => Dir::Dst,
            };
        }

        let token = self
            .next()
            .ok_or(FilterError::UnexpectedEnd("a primitive"))?;
        match token {
            "ip" | "ip6" | "arp" | "icmp" | "icmp6" | "tcp" | "udp" | "inbound" | "outbound"
                if dir != Dir::Either =>
            {
                // libpcap rejects these outright: `tcpdump 'src ip'` and
                // `tcpdump 'dst tcp'` are both `syntax error`, verified against
                // 4.99.4. Accepting them and DROPPING the direction compiled a
                // strictly wider filter than the operator wrote -- `src ip`
                // captured both directions -- which is the silent widening the
                // never-widen rule exists to prevent.
                Err(FilterError::ModifierNotApplicable {
                    modifier: dir.name(),
                    primitive: primitive_name(token),
                })
            }
            "ip" => Ok(Expr::EtherType(ETHERTYPE_IP)),
            "ip6" => Ok(Expr::EtherType(ETHERTYPE_IP6)),
            "arp" => Ok(Expr::EtherType(ETHERTYPE_ARP)),
            // Verified with `tcpdump -d icmp`: no IPv6 arm. icmp is v4-only and
            // icmp6 is v6-only; treating them as synonyms would widen both.
            "icmp" => Ok(Expr::IpProto {
                v4: true,
                v6: false,
                proto: IPPROTO_ICMP,
            }),
            "icmp6" => Ok(Expr::IpProto {
                v4: false,
                v6: true,
                proto: IPPROTO_ICMP6,
            }),
            "tcp" => Ok(Expr::IpProto {
                v4: true,
                v6: true,
                proto: IPPROTO_TCP,
            }),
            "udp" => Ok(Expr::IpProto {
                v4: true,
                v6: true,
                proto: IPPROTO_UDP,
            }),
            "inbound" => Ok(Expr::Not(Box::new(Expr::Outbound))),
            "outbound" => Ok(Expr::Outbound),
            "host" => {
                // tcpdump refuses `tcp host X` outright ("'tcp' modifier applied
                // to host"). Dropping the qualifier silently compiled a strictly
                // WIDER filter than the operator wrote.
                if let Some(p) = proto {
                    return Err(FilterError::ModifierNotApplicable {
                        modifier: proto_name(p),
                        primitive: "host",
                    });
                }
                let raw = self
                    .next()
                    .ok_or(FilterError::UnexpectedEnd("an address"))?;
                let addr: Ipv4Addr = raw
                    .parse()
                    .map_err(|_| FilterError::BadAddress(raw.to_string()))?;
                Ok(Expr::Host { addr, dir })
            }
            "net" => {
                if let Some(p) = proto {
                    return Err(FilterError::ModifierNotApplicable {
                        modifier: proto_name(p),
                        primitive: "net",
                    });
                }
                let raw = self
                    .next()
                    .ok_or(FilterError::UnexpectedEnd("a CIDR block"))?;
                let (addr, mask) = parse_cidr(raw)?;
                Ok(Expr::Net { addr, mask, dir })
            }
            "port" => {
                let raw = self.next().ok_or(FilterError::UnexpectedEnd("a port"))?;
                let port = parse_port(raw)?;
                Ok(Expr::Port {
                    lo: port,
                    hi: port,
                    dir,
                    proto,
                })
            }
            "portrange" => {
                let raw = self
                    .next()
                    .ok_or(FilterError::UnexpectedEnd("a port range"))?;
                let (lo, hi) = parse_port_range(raw)?;
                Ok(Expr::Port { lo, hi, dir, proto })
            }
            other => Err(FilterError::Unsupported(other.to_string())),
        }
    }
}

/// Parse a port the way libpcap does.
///
/// libpcap runs the literal through `strtol(..., 0)`, so the C base prefixes
/// apply: `0x50` is 80 and `010` is **8**, not 10. Confirmed by compiling with
/// tcpdump 4.99.4 on Linux 6.8 -- `port 010` and `port 8` produce byte-identical
/// programs, as do `port 0x50` and `port 80`.
///
/// Reading `010` as decimal was the dangerous half: it is accepted by both and
/// means different ports, so an operator copying a working tcpdump filter got a
/// capture of the wrong traffic with nothing to indicate it. Rejecting `0x50`
/// was merely unhelpful.
fn parse_port(raw: &str) -> Result<u16, FilterError> {
    parse_c_integer(raw)
        .and_then(|value| u16::try_from(value).ok())
        .ok_or_else(|| FilterError::BadPort(raw.to_string()))
}

/// Read an unsigned integer the way libpcap's `strtol(..., 0)` does, minus the
/// sign.
///
/// The radix is chosen from the C prefix: `0x` is hex, a bare leading zero is
/// octal, anything else decimal. Confirmed against tcpdump 4.99.4 on Linux 6.8
/// by md5 of `tcpdump -dd`: `port 010` and `port 8` produce byte-identical
/// programs, as do `port 0x50` and `port 80`.
///
/// # A sign is refused rather than honoured, deliberately
///
/// `from_str_radix` accepts its own leading `+`, and it accepts one AFTER the
/// prefix this function has already stripped. Sniffing the radix off the raw
/// string and then parsing the remainder therefore disagreed with itself:
/// `+010` took the DECIMAL arm (it does not start with `0`) and came out as 10,
/// while `010` came out as 8 -- two spellings of what an operator reads as the
/// same literal, meaning two different ports. Worse, `0+70` took the octal arm
/// with digits `+70` and compiled to port 56, which the commit that introduced
/// this claimed could not happen.
///
/// Refusing every sign is a narrowing: libpcap's `strtol` would accept some of
/// these. That direction is safe -- an operator gets an error and retypes the
/// filter. The other direction is not: silently capturing a different port than
/// the one written is the failure this whole function exists to prevent.
fn parse_c_integer(raw: &str) -> Option<u32> {
    let (digits, radix) =
        if let Some(hex) = raw.strip_prefix("0x").or_else(|| raw.strip_prefix("0X")) {
            (hex, 16)
        } else if raw.len() > 1 && raw.starts_with('0') {
            (&raw[1..], 8)
        } else {
            (raw, 10)
        };

    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_alphanumeric()) {
        return None;
    }
    u32::from_str_radix(digits, radix).ok()
}

fn primitive_name(token: &str) -> &'static str {
    match token {
        "ip" => "ip",
        "ip6" => "ip6",
        "arp" => "arp",
        "icmp" => "icmp",
        "icmp6" => "icmp6",
        "tcp" => "tcp",
        "udp" => "udp",
        "inbound" => "inbound",
        _ => "outbound",
    }
}

fn proto_name(proto: u32) -> &'static str {
    match proto {
        IPPROTO_TCP => "tcp",
        IPPROTO_UDP => "udp",
        _ => "protocol",
    }
}

fn parse_cidr(raw: &str) -> Result<(Ipv4Addr, u32), FilterError> {
    let (addr_str, len_str) = raw
        .split_once('/')
        .ok_or_else(|| FilterError::BadCidr(raw.to_string()))?;
    let addr: Ipv4Addr = addr_str
        .parse()
        .map_err(|_| FilterError::BadCidr(raw.to_string()))?;
    // The same C radix rule as a port. Leaving this decimal after fixing ports
    // kept the identical divergence one function away: tcpdump reads
    // `net 10.0.0.0/010` as /8, and reading it as /10 silently NARROWS the
    // filter -- a capture that quietly misses traffic the operator asked for.
    let len = parse_c_integer(len_str).ok_or_else(|| FilterError::BadCidr(raw.to_string()))?;
    if len > 32 {
        return Err(FilterError::BadCidr(raw.to_string()));
    }
    let mask = if len == 0 { 0 } else { u32::MAX << (32 - len) };
    // libpcap refuses a network address with bits outside its prefix rather than
    // masking them away. Masking silently WIDENS the filter: `net 10.1.2.3/8`
    // would quietly become `net 10.0.0.0/8`.
    if u32::from(addr) & !mask != 0 {
        return Err(FilterError::BadCidr(raw.to_string()));
    }
    Ok((addr, mask))
}

fn parse_port_range(raw: &str) -> Result<(u16, u16), FilterError> {
    let (lo_str, hi_str) = raw
        .split_once('-')
        .ok_or_else(|| FilterError::BadPort(raw.to_string()))?;
    // Same radix rules as a bare port: libpcap parses both endpoints with
    // strtol(base 0), so `portrange 010-020` is 8-16.
    let lo = parse_port(lo_str).map_err(|_| FilterError::BadPort(raw.to_string()))?;
    let hi = parse_port(hi_str).map_err(|_| FilterError::BadPort(raw.to_string()))?;
    if lo > hi {
        return Err(FilterError::InvertedRange { lo, hi });
    }
    Ok((lo, hi))
}

// ---------------------------------------------------------------------------
// Code generation
// ---------------------------------------------------------------------------

/// A jump destination, resolved to a relative offset once every block is laid
/// out. cBPF jumps are forward-only unsigned bytes, which the short-circuit
/// layout below satisfies by construction.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Target {
    Label(usize),
}

#[derive(Debug, Clone, Copy)]
struct Pending {
    code: u16,
    jt: Option<Target>,
    jf: Option<Target>,
    k: u32,
}

struct Codegen {
    out: Vec<Pending>,
    labels: Vec<Option<usize>>,
    snaplen: u32,
}

impl Codegen {
    fn new(snaplen: u32) -> Self {
        Self {
            out: Vec::new(),
            labels: Vec::new(),
            snaplen,
        }
    }

    fn new_label(&mut self) -> usize {
        self.labels.push(None);
        self.labels.len() - 1
    }

    fn place(&mut self, label: usize) {
        self.labels[label] = Some(self.out.len());
    }

    fn push(&mut self, code: u16, jt: Option<Target>, jf: Option<Target>, k: u32) {
        self.out.push(Pending { code, jt, jf, k });
    }

    fn emit(mut self, expr: &Expr) -> Result<Program, FilterError> {
        let accept = self.new_label();
        let reject = self.new_label();

        self.expr(expr, accept, reject);

        self.place(accept);
        self.push(BPF_RET | BPF_K, None, None, self.snaplen);
        self.place(reject);
        self.push(BPF_RET | BPF_K, None, None, 0);

        self.resolve()
    }

    fn resolve(self) -> Result<Program, FilterError> {
        let mut insns = Vec::with_capacity(self.out.len());
        for (index, pending) in self.out.iter().enumerate() {
            let resolve_one = |t: Option<Target>| -> Result<u8, FilterError> {
                let Some(Target::Label(l)) = t else {
                    return Ok(0);
                };
                let target = self.labels[l].expect("every label is placed before resolve");
                let delta = target
                    .checked_sub(index + 1)
                    .ok_or(FilterError::TooComplex("backward jump"))?;
                u8::try_from(delta).map_err(|_| FilterError::TooComplex("jump offset exceeds 255"))
            };
            insns.push(Instruction::new(
                pending.code,
                resolve_one(pending.jt)?,
                resolve_one(pending.jf)?,
                pending.k,
            ));
        }
        Ok(Program::new(insns)?)
    }

    /// Emit code that jumps to `t` when `expr` holds and `f` otherwise.
    fn expr(&mut self, expr: &Expr, t: usize, f: usize) {
        match expr {
            Expr::And(a, b) => {
                let next = self.new_label();
                self.expr(a, next, f);
                self.place(next);
                self.expr(b, t, f);
            }
            Expr::Or(a, b) => {
                let next = self.new_label();
                self.expr(a, t, next);
                self.place(next);
                self.expr(b, t, f);
            }
            Expr::Not(a) => self.expr(a, f, t),
            Expr::EtherType(ty) => self.ethertype(*ty, t, f),
            Expr::IpProto { v4, v6, proto } => self.ip_proto(*v4, *v6, *proto, t, f),
            Expr::Host { addr, dir } => self.host(*addr, *dir, t, f),
            Expr::Net { addr, mask, dir } => self.net(*addr, *mask, *dir, t, f),
            Expr::Port { lo, hi, dir, proto } => self.port(*lo, *hi, *dir, *proto, t, f),
            Expr::Outbound => {
                // Verified: `tcpdump -dd outbound` is an ancillary load of
                // SKF_AD_PKTTYPE compared against PACKET_OUTGOING, not a
                // packet-byte read. `inbound` is its negation.
                let off = (SKF_AD_OFF + SKF_AD_PKTTYPE) as u32;
                self.push(BPF_LD | BPF_H | BPF_ABS, None, None, off);
                self.jeq(PACKET_OUTGOING, t, f);
            }
        }
    }

    fn jeq(&mut self, k: u32, t: usize, f: usize) {
        self.push(
            BPF_JMP | BPF_JEQ | BPF_K,
            Some(Target::Label(t)),
            Some(Target::Label(f)),
            k,
        );
    }

    fn ethertype(&mut self, ty: u32, t: usize, f: usize) {
        self.push(BPF_LD | BPF_H | BPF_ABS, None, None, OFF_ETHERTYPE);
        self.jeq(ty, t, f);
    }

    fn ip_proto(&mut self, v4: bool, v6: bool, proto: u32, t: usize, f: usize) {
        let v6_label = self.new_label();
        let after_v4 = if v6 { v6_label } else { f };

        if v4 {
            let check = self.new_label();
            self.ethertype(ETHERTYPE_IP, check, after_v4);
            self.place(check);
            self.push(BPF_LD | BPF_B | BPF_ABS, None, None, OFF_IP4_PROTO);
            self.jeq(proto, t, after_v4);
        }

        if v6 {
            self.place(v6_label);
            let check = self.new_label();
            self.ethertype(ETHERTYPE_IP6, check, f);
            self.place(check);
            self.push(BPF_LD | BPF_B | BPF_ABS, None, None, OFF_IP6_NEXT_HEADER);
            let frag = self.new_label();
            self.jeq(proto, t, frag);
            // Follow exactly one fragment header, which is what tcpdump does.
            self.place(frag);
            let frag_check = self.new_label();
            self.jeq(IP6_FRAGMENT_HEADER, frag_check, f);
            self.place(frag_check);
            self.push(
                BPF_LD | BPF_B | BPF_ABS,
                None,
                None,
                OFF_IP6_FRAG_NEXT_HEADER,
            );
            self.jeq(proto, t, f);
        }
    }

    /// `host`/`net` match ARP and RARP sender/target protocol addresses as well
    /// as the IPv4 header. A compiler that checks only the IP header silently
    /// under-matches, and the difference never appears on IP-only traffic.
    fn address(&mut self, mask: Option<u32>, value: u32, dir: Dir, t: usize, f: usize) {
        let mut arms: Vec<(u32, u32)> = Vec::new();
        match dir {
            Dir::Src => arms.push((ETHERTYPE_IP, OFF_IP4_SRC)),
            Dir::Dst => arms.push((ETHERTYPE_IP, OFF_IP4_DST)),
            Dir::Either => {
                arms.push((ETHERTYPE_IP, OFF_IP4_SRC));
                arms.push((ETHERTYPE_IP, OFF_IP4_DST));
            }
        }
        let arp_offsets: &[u32] = match dir {
            Dir::Src => &[OFF_ARP_SPA],
            Dir::Dst => &[OFF_ARP_TPA],
            Dir::Either => &[OFF_ARP_SPA, OFF_ARP_TPA],
        };

        let ip_label = self.new_label();
        let arp_label = self.new_label();
        let rarp_label = self.new_label();

        // IPv4 arm.
        self.push(BPF_LD | BPF_H | BPF_ABS, None, None, OFF_ETHERTYPE);
        self.jeq(ETHERTYPE_IP, ip_label, arp_label);
        self.place(ip_label);
        for (i, (_, off)) in arms.iter().enumerate() {
            let last = i + 1 == arms.len();
            let next = if last { arp_label } else { self.new_label() };
            self.load_masked(*off, mask);
            self.jeq(value, t, next);
            if !last {
                self.place(next);
            }
        }

        // ARP arm, then RARP. The guard must be emitted BEFORE the arm body:
        // a block expression that emits the body while computing the jump
        // target would lay the body down first and jump over nothing.
        self.place(arp_label);
        let arp_body = self.new_label();
        self.push(BPF_LD | BPF_H | BPF_ABS, None, None, OFF_ETHERTYPE);
        self.jeq(ETHERTYPE_ARP, arp_body, rarp_label);
        self.arp_arm(arp_body, arp_offsets, mask, value, t, rarp_label);

        self.place(rarp_label);
        let rarp_body = self.new_label();
        self.push(BPF_LD | BPF_H | BPF_ABS, None, None, OFF_ETHERTYPE);
        self.jeq(ETHERTYPE_RARP, rarp_body, f);
        self.arp_arm(rarp_body, arp_offsets, mask, value, t, f);
    }

    fn arp_arm(
        &mut self,
        label: usize,
        offsets: &[u32],
        mask: Option<u32>,
        value: u32,
        t: usize,
        f: usize,
    ) {
        self.place(label);
        for (i, off) in offsets.iter().enumerate() {
            let last = i + 1 == offsets.len();
            let next = if last { f } else { self.new_label() };
            self.load_masked(*off, mask);
            self.jeq(value, t, next);
            if !last {
                self.place(next);
            }
        }
    }

    fn load_masked(&mut self, offset: u32, mask: Option<u32>) {
        self.push(BPF_LD | BPF_W | BPF_ABS, None, None, offset);
        if let Some(mask) = mask {
            self.push(BPF_ALU | BPF_AND | BPF_K, None, None, mask);
        }
    }

    fn host(&mut self, addr: Ipv4Addr, dir: Dir, t: usize, f: usize) {
        self.address(None, u32::from(addr), dir, t, f);
    }

    fn net(&mut self, addr: Ipv4Addr, mask: u32, dir: Dir, t: usize, f: usize) {
        self.address(Some(mask), u32::from(addr) & mask, dir, t, f);
    }

    /// Port matching, following libpcap's structure exactly.
    ///
    /// Verified with `tcpdump -d "tcp port 443"` on Linux 6.8. Two things that
    /// look surprising and are what libpcap actually does:
    ///
    /// * **IPv6 ports are read at fixed offsets 54 and 56**, gated only on the
    ///   next-header byte at 20. libpcap does NOT walk the extension-header
    ///   chain for port matching, so a packet whose next header is a fragment
    ///   header (44) does not match `tcp port N` — and neither does ours.
    /// * **The IPv4 arm needs both guards**: the `0x1fff` fragment check, and
    ///   `BPF_MSH` for the variable header length. IPv6 needs neither, because
    ///   its header is fixed length and libpcap applies no fragment guard here.
    fn port(&mut self, lo: u16, hi: u16, dir: Dir, proto: Option<u32>, t: usize, f: usize) {
        let v4_check = self.new_label();
        let v6_arm = self.new_label();

        // One ethertype load feeds both comparisons, as libpcap does.
        self.push(BPF_LD | BPF_H | BPF_ABS, None, None, OFF_ETHERTYPE);
        self.jeq(ETHERTYPE_IP6, v6_arm, v4_check);

        // ---- IPv6 ----
        self.place(v6_arm);
        self.push(BPF_LD | BPF_B | BPF_ABS, None, None, OFF_IP6_NEXT_HEADER);
        let v6_ports = self.new_label();
        self.proto_gate(proto, v6_ports, f);
        self.place(v6_ports);
        let v6_offsets: &[u32] = match dir {
            Dir::Src => &[OFF_IP6_PORTS],
            Dir::Dst => &[OFF_IP6_PORTS + 2],
            Dir::Either => &[OFF_IP6_PORTS, OFF_IP6_PORTS + 2],
        };
        self.port_compares(v6_offsets, false, lo, hi, t, f);

        // ---- IPv4 ----
        self.place(v4_check);
        let v4_arm = self.new_label();
        self.jeq(ETHERTYPE_IP, v4_arm, f);
        self.place(v4_arm);
        self.push(BPF_LD | BPF_B | BPF_ABS, None, None, OFF_IP4_PROTO);
        let v4_frag = self.new_label();
        self.proto_gate(proto, v4_frag, f);
        self.place(v4_frag);

        // Fragment guard: without it the filter matches non-first fragments
        // whose payload bytes happen to look like a matching port.
        self.push(BPF_LD | BPF_H | BPF_ABS, None, None, OFF_IP4_FLAGS);
        let not_fragment = self.new_label();
        // JSET jumps when any masked bit is set, i.e. this IS a fragment, so
        // the true arm is the reject path.
        self.push(
            BPF_JMP | BPF_JSET | BPF_K,
            Some(Target::Label(f)),
            Some(Target::Label(not_fragment)),
            IP4_FRAGMENT_MASK,
        );
        self.place(not_fragment);

        // Variable IPv4 header length into X: 4 * ([14] & 0xf).
        self.push(BPF_LDX | BPF_B | BPF_MSH, None, None, OFF_IP4_HEADER);
        let v4_offsets: &[u32] = match dir {
            Dir::Src => &[OFF_IP4_HEADER],
            Dir::Dst => &[OFF_IP4_HEADER + 2],
            Dir::Either => &[OFF_IP4_HEADER, OFF_IP4_HEADER + 2],
        };
        self.port_compares(v4_offsets, true, lo, hi, t, f);
    }

    /// Bare `port` matches TCP, UDP and SCTP, exactly as tcpdump does. A
    /// protocol-qualified `tcp port` / `udp port` matches only that protocol.
    fn proto_gate(&mut self, proto: Option<u32>, ok: usize, f: usize) {
        match proto {
            Some(p) => self.jeq(p, ok, f),
            None => {
                let try_tcp = self.new_label();
                let try_udp = self.new_label();
                self.jeq(IPPROTO_SCTP, ok, try_tcp);
                self.place(try_tcp);
                self.jeq(IPPROTO_TCP, ok, try_udp);
                self.place(try_udp);
                self.jeq(IPPROTO_UDP, ok, f);
            }
        }
    }

    fn port_compares(
        &mut self,
        offsets: &[u32],
        indexed: bool,
        lo: u16,
        hi: u16,
        t: usize,
        f: usize,
    ) {
        let mode = if indexed { BPF_IND } else { BPF_ABS };
        for (i, off) in offsets.iter().enumerate() {
            let last = i + 1 == offsets.len();
            let next = if last { f } else { self.new_label() };
            self.push(BPF_LD | BPF_H | mode, None, None, *off);
            if lo == hi {
                self.jeq(u32::from(lo), t, next);
            } else {
                // Verified shape: JGE on the lower bound, then JGT on the upper.
                let upper = self.new_label();
                self.push(
                    BPF_JMP | BPF_JGE | BPF_K,
                    Some(Target::Label(upper)),
                    Some(Target::Label(next)),
                    u32::from(lo),
                );
                self.place(upper);
                self.push(
                    BPF_JMP | BPF_JGT | BPF_K,
                    Some(Target::Label(next)),
                    Some(Target::Label(t)),
                    u32::from(hi),
                );
            }
            if !last {
                self.place(next);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ok(expr: &str) -> Program {
        compile(expr, 262_144).unwrap_or_else(|e| panic!("compile {expr:?}: {e}"))
    }

    #[test]
    fn every_documented_primitive_compiles() {
        for expr in [
            "ip",
            "ip6",
            "arp",
            "tcp",
            "udp",
            "icmp",
            "icmp6",
            "inbound",
            "outbound",
            "host 192.0.2.1",
            "src host 192.0.2.1",
            "dst host 192.0.2.1",
            "net 10.0.0.0/8",
            "port 443",
            "tcp port 443",
            "udp port 53",
            "src port 443",
            "portrange 80-90",
            "tcp portrange 8000-8100",
            "icmp or arp",
            "tcp and dst host 192.0.2.1",
            "not arp",
            "(tcp or udp) and host 192.0.2.1",
            "ip and not icmp",
        ] {
            let program = ok(expr);
            assert!(!program.is_empty(), "{expr}");
            let last = program.instructions().last().copied().unwrap();
            assert_eq!(last, Instruction::reject(), "{expr} must end in a return");
        }
    }

    #[test]
    fn unsupported_constructs_are_named_never_approximated() {
        // Each of these is something tcpdump accepts and we deliberately do
        // not. Silently widening to "match more" would be an exfiltration
        // surface; silently narrowing would be an empty capture that reports
        // success.
        assert_eq!(
            compile("vlan", 262_144),
            Err(FilterError::Unsupported("vlan".into()))
        );
        assert_eq!(
            compile("mpls", 262_144),
            Err(FilterError::Unsupported("mpls".into()))
        );
        assert_eq!(
            compile("ether host aa:bb:cc:dd:ee:ff", 262_144),
            Err(FilterError::Unsupported("ether".into()))
        );
    }

    #[test]
    fn a_typo_is_rejected_with_the_offending_token() {
        assert_eq!(
            compile("tpc port 443", 262_144),
            Err(FilterError::Unsupported("tpc".into()))
        );
    }

    #[test]
    fn malformed_operands_are_rejected_by_kind() {
        assert_eq!(
            compile("host 999.1.1.1", 262_144),
            Err(FilterError::BadAddress("999.1.1.1".into()))
        );
        assert_eq!(
            compile("net 10.0.0.0/33", 262_144),
            Err(FilterError::BadCidr("10.0.0.0/33".into()))
        );
        assert_eq!(
            compile("port 70000", 262_144),
            Err(FilterError::BadPort("70000".into()))
        );
        assert_eq!(
            compile("portrange 90-80", 262_144),
            Err(FilterError::InvertedRange { lo: 90, hi: 80 })
        );
        assert_eq!(compile("", 262_144), Err(FilterError::Empty));
        assert_eq!(
            compile("tcp and", 262_144),
            Err(FilterError::UnexpectedEnd("a primitive"))
        );
        assert_eq!(
            compile("(tcp", 262_144),
            Err(FilterError::UnexpectedEnd("`)`"))
        );
    }

    #[test]
    fn snaplen_is_the_accept_return_value() {
        let program = compile("icmp", 96).unwrap();
        let insns = program.instructions();
        assert!(
            insns.contains(&Instruction::accept(96)),
            "accept must return the snaplen: {insns:?}"
        );
        assert_eq!(insns.last().copied().unwrap(), Instruction::reject());
    }

    #[test]
    fn icmp_has_no_ipv6_arm_and_icmp6_has_no_ipv4_arm() {
        // Verified against `tcpdump -d icmp`, which has no IPv6 branch.
        // Treating the two as synonyms would widen both filters.
        let icmp = ok("icmp");
        assert!(
            !icmp
                .instructions()
                .iter()
                .any(|i| i.k == ETHERTYPE_IP6 && i.code == (BPF_JMP | BPF_JEQ | BPF_K)),
            "icmp must not test for IPv6: {:?}",
            icmp.instructions()
        );

        let icmp6 = ok("icmp6");
        assert!(
            !icmp6
                .instructions()
                .iter()
                .any(|i| i.k == ETHERTYPE_IP && i.code == (BPF_JMP | BPF_JEQ | BPF_K)),
            "icmp6 must not test for IPv4"
        );
    }

    #[test]
    fn ipv4_port_matching_carries_the_fragment_guard() {
        // Without this a filter matches non-first fragments whose bytes at the
        // port offset are payload rather than ports, silently widening.
        let program = ok("tcp port 443");
        assert!(
            program
                .instructions()
                .iter()
                .any(|i| i.k == IP4_FRAGMENT_MASK),
            "expected a 0x1fff fragment guard: {:?}",
            program.instructions()
        );
    }

    #[test]
    fn ipv4_port_matching_uses_the_variable_header_length() {
        // A fixed 20-byte assumption misses every packet with IP options.
        let program = ok("tcp port 443");
        assert!(
            program
                .instructions()
                .iter()
                .any(|i| i.code == (BPF_LDX | BPF_B | BPF_MSH)),
            "expected BPF_MSH to read 4*([14]&0xf): {:?}",
            program.instructions()
        );
    }

    #[test]
    fn bare_port_matches_sctp_as_tcpdump_does() {
        let program = ok("port 443");
        assert!(
            program.instructions().iter().any(|i| i.k == IPPROTO_SCTP),
            "bare `port` must also match SCTP"
        );
        // A protocol-qualified port must NOT.
        let qualified = ok("tcp port 443");
        assert!(!qualified.instructions().iter().any(|i| i.k == IPPROTO_SCTP));
    }

    #[test]
    fn host_also_matches_arp_and_rarp_addresses() {
        // tcpdump's `host` matches ARP/RARP sender and target protocol
        // addresses. Checking only the IP header silently under-matches, and
        // the gap never shows on IP-only traffic.
        let program = ok("host 192.0.2.1");
        let ks: Vec<u32> = program.instructions().iter().map(|i| i.k).collect();
        assert!(ks.contains(&ETHERTYPE_ARP), "expected an ARP arm: {ks:?}");
        assert!(ks.contains(&ETHERTYPE_RARP), "expected a RARP arm: {ks:?}");
        assert!(ks.contains(&OFF_ARP_SPA));
        assert!(ks.contains(&OFF_ARP_TPA));
    }

    #[test]
    fn net_masks_before_comparing() {
        let program = ok("net 10.0.0.0/8");
        let insns = program.instructions();
        assert!(
            insns
                .iter()
                .any(|i| i.code == (BPF_ALU | BPF_AND | BPF_K) && i.k == 0xff00_0000),
            "expected `and #0xff000000`: {insns:?}"
        );
        assert!(insns.iter().any(|i| i.k == 0x0a00_0000));
    }

    #[test]
    fn direction_uses_an_ancillary_load_not_a_packet_byte() {
        let program = ok("outbound");
        let insns = program.instructions();
        assert_eq!(insns[0].k, 0xffff_f004, "SKF_AD_OFF + SKF_AD_PKTTYPE");
        assert!(insns.iter().any(|i| i.k == PACKET_OUTGOING));
    }

    #[test]
    fn inbound_is_the_negation_of_outbound() {
        // Verified: `tcpdump -dd inbound` is `outbound` with the two returns
        // swapped. It is NOT a test for PACKET_HOST.
        let inbound = ok("inbound");
        let outbound = ok("outbound");
        assert_eq!(inbound.len(), outbound.len());
        assert_eq!(inbound.instructions()[0], outbound.instructions()[0]);
        assert_eq!(
            inbound.instructions().last(),
            outbound.instructions().last()
        );
    }

    #[test]
    fn every_jump_is_forward_and_within_range() {
        // cBPF jump offsets are unsigned bytes. A backward or oversized jump
        // is rejected by the kernel with a bare EINVAL, so catch it here where
        // the reason is visible.
        for expr in [
            "(tcp or udp or icmp or arp) and (host 192.0.2.1 or net 10.0.0.0/8)",
            "not (tcp port 443 or udp port 53)",
            "ip and tcp and dst host 192.0.2.1 and dst port 443",
        ] {
            let program = ok(expr);
            let len = program.len();
            for (i, insn) in program.instructions().iter().enumerate() {
                if insn.code & 0x07 == BPF_JMP {
                    assert!(
                        i + 1 + insn.jt as usize <= len,
                        "{expr}: jt out of range at {i}"
                    );
                    assert!(
                        i + 1 + insn.jf as usize <= len,
                        "{expr}: jf out of range at {i}"
                    );
                }
            }
        }
    }
    #[test]
    fn deep_nesting_is_refused_instead_of_aborting_the_process() {
        // Measured before the guard existed: 10,000 nested parens printed
        // "thread 'main' has overflowed its stack / fatal runtime error: stack
        // overflow, aborting". A stack overflow is not a catchable error, so
        // this was not a bad filter being rejected -- it was netprobe dying and
        // taking eBPF flow attribution and the device census with it, from one
        // string typed into a capture form.
        for depth in [1_000usize, 10_000, 100_000] {
            let expr = format!("{}tcp{}", "(".repeat(depth), ")".repeat(depth));
            assert_eq!(
                compile(&expr, 262_144),
                Err(FilterError::TooComplex(
                    "filter nesting is too deep (limit: 64 levels, counting the expression itself)"
                )),
                "nesting {depth} deep must be refused"
            );
        }

        // `not` recurses through the same path, so one guard covers both.
        let expr = format!("{}tcp", "not ".repeat(5_000));
        assert!(matches!(
            compile(&expr, 262_144),
            Err(FilterError::TooComplex(_))
        ));
    }

    #[test]
    fn a_flat_and_or_chain_is_refused_instead_of_aborting_in_codegen() {
        // The bug a depth limit alone did NOT fix, and the reason this test
        // exists: `parse_expr` consumes an and/or chain in a loop, so the depth
        // counter never rises above 1 while the tree leans left one level per
        // operator. `Codegen::expr` then recurses over that spine with no guard
        // at all.
        //
        // Measured on the previous commit, through the real entry point, on a
        // tokio worker's 2 MiB stack: "tcp or " repeated 19,000 times -- 133 KB,
        // against a 4 MiB frame cap -- printed "fatal runtime error: stack
        // overflow". Not catchable, so netprobe simply died.
        for (op, n) in [
            ("or", 2_000usize),
            ("and", 2_000),
            ("||", 5_000),
            ("&&", 5_000),
        ] {
            let expr = format!("tcp {op} ").repeat(n) + "tcp";
            assert_eq!(
                compile(&expr, 262_144),
                Err(FilterError::TooComplex(
                    "filter has too many terms (limit: 1024)"
                )),
                "a flat {op} chain of {n} terms must be refused before codegen walks it"
            );
        }

        // Distinct primitives, so nothing about the refusal depends on the
        // terms being identical.
        let expr = (0..3_000)
            .map(|i| format!("host 192.0.2.{} or ", i % 250))
            .collect::<String>()
            + "tcp";
        assert!(matches!(
            compile(&expr, 262_144),
            Err(FilterError::TooComplex(_))
        ));

        // The bound is on the WHOLE tree, so nesting cannot be used to smuggle
        // terms past it either.
        let expr = format!("({})", vec!["tcp"; 2_000].join(" or "));
        assert!(matches!(
            compile(&expr, 262_144),
            Err(FilterError::TooComplex(_))
        ));
    }

    #[test]
    fn the_term_limit_never_rejects_a_filter_that_could_have_compiled() {
        // A guard that rejects real filters is its own bug. It cannot here, and
        // the reason is worth recording: classic BPF jump offsets are 8-bit, so
        // this compiler already refuses an `or` chain at about 29 terms with
        // "jump offset exceeds 255". Everything the term limit rejects was
        // unrepresentable anyway -- it just rejects it BEFORE codegen recurses
        // rather than after.
        let longest = (1..)
            .take_while(|n| compile(&vec!["tcp"; *n].join(" or "), 262_144).is_ok())
            .last()
            .expect("some chain length compiles");
        assert!(
            longest < MAX_PARSE_TERMS,
            "the term limit ({MAX_PARSE_TERMS}) must sit above the longest compilable chain \
             ({longest}), or it is rejecting filters that would have worked"
        );
        assert!(
            longest >= 20,
            "a 20-term chain should still compile; got {longest}"
        );
    }

    #[test]
    fn nesting_an_operator_would_actually_write_still_compiles() {
        // A limit that rejects real filters is its own bug. Three levels is
        // already more than tcpdump's own documentation uses.
        assert!(
            compile(
                "((tcp and port 22) or (udp and port 53)) and not host 192.0.2.1",
                262_144
            )
            .is_ok()
        );
        // 63 parens, not 64: the outermost expression is itself one level, so
        // the limit is reached one paren earlier than the number suggests. Both
        // sides of the boundary are asserted so the limit cannot drift.
        let expr = format!("{}tcp{}", "(".repeat(63), ")".repeat(63));
        assert!(
            compile(&expr, 262_144).is_ok(),
            "63 parens is within the limit"
        );
        let expr = format!("{}tcp{}", "(".repeat(64), ")".repeat(64));
        assert!(
            compile(&expr, 262_144).is_err(),
            "64 parens is one level past it"
        );
    }

    #[test]
    fn port_literals_use_libpcaps_radix_rules_not_rusts() {
        // libpcap runs the literal through strtol(base 0). Confirmed against
        // tcpdump 4.99.4 on Linux 6.8 by md5 of `tcpdump -dd`: `port 010` and
        // `port 8` are byte-identical, as are `port 0x50` and `port 80`.
        //
        // Reading `010` as decimal was the dangerous half: both compilers
        // accept it and they mean DIFFERENT ports, so an operator copying a
        // working tcpdump filter captured the wrong traffic with nothing to
        // show for it.
        assert_eq!(
            compile("port 010", 262_144).unwrap(),
            compile("port 8", 262_144).unwrap(),
            "a leading zero is octal, as in C"
        );
        assert_eq!(
            compile("port 0x50", 262_144).unwrap(),
            compile("port 80", 262_144).unwrap(),
            "0x is hex; rejecting it was merely unhelpful, but it is still wrong"
        );
        assert_eq!(
            compile("portrange 010-020", 262_144).unwrap(),
            compile("portrange 8-16", 262_144).unwrap(),
            "both endpoints of a range follow the same rule"
        );

        // `0` alone is still zero, not an empty octal literal.
        assert!(compile("port 0", 262_144).is_ok());
        // And genuinely malformed literals are still refused.
        for bad in ["port 0x", "port 08", "port 0xzz", "port 65536"] {
            assert!(compile(bad, 262_144).is_err(), "{bad} must be refused");
        }
    }

    #[test]
    fn a_sign_cannot_slip_past_the_radix_sniffer() {
        // The subtle half of the radix rule, and the half that shipped
        // unguarded. `parse_c_integer` chooses the radix from the RAW string
        // and parses the digits afterwards, and `from_str_radix` accepts its
        // own leading sign -- so without an explicit refusal the two halves
        // disagree with each other. `+010` does not start with `0`, so it took
        // the decimal arm and meant port 10, while `010` meant port 8: two
        // spellings an operator reads as one literal, resolving to different
        // ports. `0+70` was worse, taking the octal arm with digits `+70` and
        // compiling to port 56.
        for expr in [
            "port +80",
            "port -80",
            "port +010",
            "port 0+70",
            "port 0+7",
            "port 0x+f",
            "port +0x50",
            "portrange +010-020",
            "portrange 10-+20",
        ] {
            assert!(
                compile(expr, 262_144).is_err(),
                "{expr} must be refused rather than silently meaning some other port"
            );
        }

        // Refusing a sign is a NARROWING -- libpcap's strtol would take some of
        // these. That direction is safe: the operator sees an error and
        // retypes. The unsafe direction is capturing a port they did not write.
        assert!(compile("port 80", 262_144).is_ok());
        assert!(compile("portrange 10-20", 262_144).is_ok());
    }

    #[test]
    fn a_cidr_prefix_length_follows_the_same_radix_rule_as_a_port() {
        // The same divergence class as a port literal, one function away, and
        // it also shipped unguarded. tcpdump reads `net 10.0.0.0/010` as /8;
        // reading it as /10 silently NARROWS the filter, so the capture quietly
        // misses traffic the operator asked for.
        assert_eq!(
            compile("net 192.0.2.0/030", 262_144).unwrap(),
            compile("net 192.0.2.0/24", 262_144).unwrap(),
            "a leading zero is octal here too: 030 octal is 24"
        );
        assert_eq!(
            compile("net 192.0.2.0/0x18", 262_144).unwrap(),
            compile("net 192.0.2.0/24", 262_144).unwrap()
        );
        for expr in ["net 192.0.2.0/+24", "net 192.0.2.0/08", "net 192.0.2.0/0x"] {
            assert!(compile(expr, 262_144).is_err(), "{expr} must be refused");
        }
    }

    #[test]
    fn a_direction_before_a_primitive_that_has_none_is_refused() {
        // libpcap answers `syntax error` to both of these, verified against
        // 4.99.4. Accepting them and silently DROPPING the direction compiled a
        // strictly wider filter than the operator wrote: `src ip` captured both
        // directions, which is exactly the silent widening the never-widen rule
        // exists to prevent -- and it looks like it worked.
        // EVERY primitive named in the guard's match arm, in both directions.
        // The first version of this list covered nine of eighteen and omitted
        // `icmp6` entirely, so that one could have been dropped from the guard
        // -- restoring the silent widening for icmp6 traffic -- with the whole
        // suite still green.
        for expr in [
            "src ip",
            "dst ip",
            "src ip6",
            "dst ip6",
            "src arp",
            "dst arp",
            "src icmp",
            "dst icmp",
            "src icmp6",
            "dst icmp6",
            "src tcp",
            "dst tcp",
            "src udp",
            "dst udp",
            "src inbound",
            "dst inbound",
            "src outbound",
            "dst outbound",
        ] {
            // `expect_err` takes a plain message, NOT a format string: the
            // previous `expect_err("{expr} must be refused")` printed the
            // literal braces and named nothing, so a regression said only that
            // *something* compiled. Match instead, so the panic identifies the
            // expression.
            let err = match compile(expr, 262_144) {
                Err(err) => err,
                Ok(_) => panic!("{expr} must be refused, as libpcap refuses it"),
            };
            assert!(
                matches!(err, FilterError::ModifierNotApplicable { .. }),
                "{expr} refused for the wrong reason: {err}"
            );
        }

        // The primitives that DO take a direction are untouched.
        for expr in [
            "src host 192.0.2.1",
            "dst net 192.0.2.0/24",
            "src port 22",
            "dst portrange 1-2",
        ] {
            assert!(compile(expr, 262_144).is_ok(), "{expr} must still compile");
        }
    }
}
