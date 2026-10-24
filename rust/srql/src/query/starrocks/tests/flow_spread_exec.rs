//! Runs the SQL that `translate` emits for bucketed flow volume.
//!
//! The executor implements the StarRocks functions that SQL calls
//! (`time_slice` floor, inclusive `generate_series`, `milliseconds_diff` and
//! `seconds_diff` as expr1 − expr2, `seconds_add` / `seconds_sub`, `FLOOR`).
//! The expected buckets come from the language-reference rule and the #5970
//! review decision: each share is `floor(v * c(hi)) - floor(v * c(lo))` on the
//! real `[start_time, time]` interval, the window clips that interval, and
//! `MAX_BUCKETS` only limits how many buckets are emitted, folding the
//! in-window part before the earliest one into that bucket. A wrong booking
//! (the whole value on the end bucket, or the capped-span fraction
//! `floor(1e9 * 3600/14340) = 251046025`) does not match those numbers.

use std::collections::{BTreeMap, HashMap};

use chrono::{DateTime, Duration, NaiveDateTime, Utc};

use super::super::{translate, translate_raw};
use super::plan;

const MAX_BUCKETS: i64 = 240;

#[derive(Clone, Debug)]
enum Value {
    Null,
    Num(f64),
    Bool(bool),
    Time(DateTime<Utc>),
    Text(String),
}

#[derive(Clone, Debug)]
enum Expr {
    Null,
    Num(f64),
    Text(String),
    Col(String),
    SpreadK,
    Star,
    Neg(Box<Expr>),
    Bin(BinOp, Box<Expr>, Box<Expr>),
    Cmp(CmpOp, Box<Expr>, Box<Expr>),
    IsNull(Box<Expr>, bool),
    And(Box<Expr>, Box<Expr>),
    Or(Box<Expr>, Box<Expr>),
    Case {
        when: Box<Expr>,
        then: Box<Expr>,
        else_: Option<Box<Expr>>,
    },
    Cast(Box<Expr>, CastKind),
    TimeSlice(Box<Expr>, i64),
    SecondsAdd(Box<Expr>, Box<Expr>, bool),
    SecondsDiff(Box<Expr>, Box<Expr>),
    MillisDiff(Box<Expr>, Box<Expr>),
    Floor(Box<Expr>),
    Greatest(Vec<Expr>, bool),
    Coalesce(Vec<Expr>),
}

#[derive(Clone, Copy, Debug)]
enum BinOp {
    Add,
    Sub,
    Mul,
    Div,
}

#[derive(Clone, Copy, Debug)]
enum CmpOp {
    Eq,
    Ne,
    Lt,
    Gt,
    Le,
    Ge,
}

#[derive(Clone, Copy, Debug)]
enum CastKind {
    Double,
    Datetime,
    String,
}

struct Parser<'a> {
    s: &'a str,
    i: usize,
}

impl<'a> Parser<'a> {
    fn new(s: &'a str) -> Self {
        Self { s, i: 0 }
    }

    fn skip(&mut self) {
        while let Some(c) = self.s[self.i..].chars().next() {
            if c.is_whitespace() {
                self.i += c.len_utf8();
            } else {
                break;
            }
        }
    }

    fn rest(&self) -> &str {
        &self.s[self.i..]
    }

    fn eat_symbol(&mut self, symbol: &str) -> bool {
        self.skip();
        if self.rest().starts_with(symbol) {
            let next = self.rest()[symbol.len()..].chars().next();
            // Don't treat ">=" as ">" or "=" as the start of "=>".
            if symbol
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '_')
            {
                if next.is_some_and(|c| c.is_ascii_alphanumeric() || c == '_') {
                    return false;
                }
            } else if symbol == "<" && next == Some('>') {
                return false;
            } else if symbol == ">" && next == Some('=') {
                return false;
            } else if symbol == "<" && next == Some('=') {
                return false;
            } else if symbol == "!" && next == Some('=') {
                return false;
            }
            self.i += symbol.len();
            true
        } else {
            false
        }
    }

    fn ident(&mut self) -> Option<String> {
        self.skip();
        let rest = self.rest();
        if rest.starts_with('`') {
            let end = rest[1..].find('`')?;
            let name = rest[1..1 + end].to_string();
            self.i += end + 2;
            return Some(name);
        }
        let mut chars = rest.chars();
        let first = chars.next()?;
        if !(first.is_ascii_alphabetic() || first == '_') {
            return None;
        }
        let mut len = first.len_utf8();
        for c in chars {
            if c.is_ascii_alphanumeric() || c == '_' {
                len += c.len_utf8();
            } else {
                break;
            }
        }
        let name = rest[..len].to_string();
        self.i += len;
        Some(name)
    }

    fn keyword(&mut self, word: &str) -> bool {
        let mark = self.i;
        match self.ident() {
            Some(name) if name.eq_ignore_ascii_case(word) => true,
            _ => {
                self.i = mark;
                false
            }
        }
    }

    fn number(&mut self) -> Option<f64> {
        self.skip();
        let rest = self.rest();
        let mut len = 0;
        let bytes = rest.as_bytes();
        while len < bytes.len() && (bytes[len].is_ascii_digit() || bytes[len] == b'.') {
            len += 1;
        }
        if len == 0 {
            return None;
        }
        let value = rest[..len].parse().ok()?;
        self.i += len;
        Some(value)
    }

    fn string(&mut self) -> Option<String> {
        self.skip();
        if !self.rest().starts_with('\'') {
            return None;
        }
        let mut out = String::new();
        let bytes = self.rest().as_bytes();
        let mut j = 1;
        while j < bytes.len() {
            if bytes[j] == b'\'' {
                if j + 1 < bytes.len() && bytes[j + 1] == b'\'' {
                    out.push('\'');
                    j += 2;
                    continue;
                }
                self.i += j + 1;
                return Some(out);
            }
            out.push(bytes[j] as char);
            j += 1;
        }
        None
    }

    fn expect(&mut self, symbol: &str) {
        if !self.eat_symbol(symbol) {
            panic!(
                "expected {symbol} at {}",
                &self.rest()[..self.rest().len().min(80)]
            );
        }
    }

    fn expr(&mut self) -> Expr {
        self.or()
    }

    fn or(&mut self) -> Expr {
        let mut left = self.and();
        while self.keyword("OR") {
            left = Expr::Or(Box::new(left), Box::new(self.and()));
        }
        left
    }

    fn and(&mut self) -> Expr {
        let mut left = self.cmp();
        while self.keyword("AND") {
            left = Expr::And(Box::new(left), Box::new(self.cmp()));
        }
        left
    }

    fn cmp(&mut self) -> Expr {
        let left = self.add();
        if self.keyword("IS") {
            let negated = self.keyword("NOT");
            if !self.keyword("NULL") {
                panic!("expected NULL after IS at {}", snippet(self.rest()));
            }
            return Expr::IsNull(Box::new(left), negated);
        }
        let op = if self.eat_symbol(">=") {
            CmpOp::Ge
        } else if self.eat_symbol("<=") {
            CmpOp::Le
        } else if self.eat_symbol("<>") || self.eat_symbol("!=") {
            CmpOp::Ne
        } else if self.eat_symbol("=") {
            CmpOp::Eq
        } else if self.eat_symbol(">") {
            CmpOp::Gt
        } else if self.eat_symbol("<") {
            CmpOp::Lt
        } else {
            return left;
        };
        Expr::Cmp(op, Box::new(left), Box::new(self.add()))
    }

    fn add(&mut self) -> Expr {
        let mut left = self.mul();
        loop {
            if self.eat_symbol("+") {
                left = Expr::Bin(BinOp::Add, Box::new(left), Box::new(self.mul()));
            } else if self.eat_symbol("-") {
                left = Expr::Bin(BinOp::Sub, Box::new(left), Box::new(self.mul()));
            } else {
                break;
            }
        }
        left
    }

    fn mul(&mut self) -> Expr {
        let mut left = self.unary();
        loop {
            if self.eat_symbol("*") {
                left = Expr::Bin(BinOp::Mul, Box::new(left), Box::new(self.unary()));
            } else if self.eat_symbol("/") {
                left = Expr::Bin(BinOp::Div, Box::new(left), Box::new(self.unary()));
            } else {
                break;
            }
        }
        left
    }

    fn unary(&mut self) -> Expr {
        if self.eat_symbol("-") {
            Expr::Neg(Box::new(self.unary()))
        } else {
            self.primary()
        }
    }

    fn primary(&mut self) -> Expr {
        if self.eat_symbol("*") {
            return Expr::Star;
        }
        if self.keyword("CASE") {
            return self.case();
        }
        if self.keyword("CAST") {
            return self.cast();
        }
        if self.keyword("NULL") {
            return Expr::Null;
        }
        if self.keyword("INTERVAL") {
            let n = self.number().expect("interval length");
            if !self.keyword("SECOND") {
                panic!(
                    "only SECOND intervals are used, at {}",
                    snippet(self.rest())
                );
            }
            return Expr::Num(n);
        }
        if let Some(text) = self.string() {
            return Expr::Text(text);
        }
        if let Some(n) = self.number() {
            return Expr::Num(n);
        }
        if self.eat_symbol("(") {
            let inner = self.expr();
            self.expect(")");
            return inner;
        }
        let name = self.ident().unwrap_or_else(|| {
            panic!("expression at {}", snippet(self.rest()));
        });
        if self.eat_symbol("(") {
            return self.call(name);
        }
        if self.eat_symbol(".") {
            let field = self.ident().expect("field");
            if name.eq_ignore_ascii_case("spread") && field.eq_ignore_ascii_case("k") {
                return Expr::SpreadK;
            }
            return Expr::Col(field);
        }
        Expr::Col(name)
    }

    fn case(&mut self) -> Expr {
        self.expect_keyword("WHEN");
        let when = self.expr();
        self.expect_keyword("THEN");
        let then = self.expr();
        let else_ = if self.keyword("ELSE") {
            Some(Box::new(self.expr()))
        } else {
            None
        };
        self.expect_keyword("END");
        Expr::Case {
            when: Box::new(when),
            then: Box::new(then),
            else_,
        }
    }

    fn expect_keyword(&mut self, word: &str) {
        if !self.keyword(word) {
            panic!("expected {word} at {}", snippet(self.rest()));
        }
    }

    fn cast(&mut self) -> Expr {
        self.expect("(");
        let inner = self.expr();
        self.expect_keyword("AS");
        let kind = if self.keyword("DOUBLE") {
            CastKind::Double
        } else if self.keyword("DATETIME") {
            CastKind::Datetime
        } else if self.keyword("STRING") {
            CastKind::String
        } else {
            panic!("cast type at {}", snippet(self.rest()));
        };
        self.expect(")");
        Expr::Cast(Box::new(inner), kind)
    }

    fn call(&mut self, name: String) -> Expr {
        let lower = name.to_ascii_lowercase();
        if lower == "time_slice" {
            let dt = self.expr();
            self.expect(",");
            self.expect_keyword("INTERVAL");
            let n = self.number().expect("time_slice width");
            self.expect_keyword("SECOND");
            if self.eat_symbol(",") {
                self.expect_keyword("FLOOR");
            }
            self.expect(")");
            return Expr::TimeSlice(Box::new(dt), n as i64);
        }
        let mut args = Vec::new();
        if !self.eat_symbol(")") {
            loop {
                args.push(self.expr());
                if self.eat_symbol(")") {
                    break;
                }
                self.expect(",");
            }
        }
        match lower.as_str() {
            "seconds_add" => Expr::SecondsAdd(
                Box::new(take2(&mut args)),
                Box::new(take2(&mut args)),
                false,
            ),
            "seconds_sub" => {
                Expr::SecondsAdd(Box::new(take2(&mut args)), Box::new(take2(&mut args)), true)
            }
            "seconds_diff" => {
                Expr::SecondsDiff(Box::new(take2(&mut args)), Box::new(take2(&mut args)))
            }
            "milliseconds_diff" => {
                Expr::MillisDiff(Box::new(take2(&mut args)), Box::new(take2(&mut args)))
            }
            "floor" => Expr::Floor(Box::new(take2(&mut args))),
            "greatest" => Expr::Greatest(args, true),
            "least" => Expr::Greatest(args, false),
            "coalesce" => Expr::Coalesce(args),
            other => panic!("unexpected function {other}"),
        }
    }
}

fn take2(args: &mut Vec<Expr>) -> Expr {
    if args.is_empty() {
        panic!("missing function argument");
    }
    args.remove(0)
}

fn snippet(s: &str) -> String {
    s.chars().take(100).collect()
}

struct Ctx<'a> {
    row: &'a HashMap<String, Value>,
    k: Option<i64>,
}

fn eval(expr: &Expr, ctx: &Ctx<'_>) -> Value {
    match expr {
        Expr::Null => Value::Null,
        Expr::Num(n) => Value::Num(*n),
        Expr::Text(s) => Value::Text(s.clone()),
        Expr::Star => Value::Num(1.0),
        Expr::Col(name) => ctx
            .row
            .get(&name.to_ascii_lowercase())
            .cloned()
            .unwrap_or(Value::Null),
        Expr::SpreadK => Value::Num(ctx.k.expect("spread.k") as f64),
        Expr::Neg(inner) => match eval(inner, ctx) {
            Value::Num(n) => Value::Num(-n),
            Value::Null => Value::Null,
            other => panic!("negate {other:?}"),
        },
        Expr::Bin(op, lhs, rhs) => arith(*op, eval(lhs, ctx), eval(rhs, ctx)),
        Expr::Cmp(op, lhs, rhs) => compare(*op, eval(lhs, ctx), eval(rhs, ctx)),
        Expr::IsNull(inner, negated) => {
            let is_null = matches!(eval(inner, ctx), Value::Null);
            Value::Bool(if *negated { !is_null } else { is_null })
        }
        Expr::And(lhs, rhs) => match truth(eval(lhs, ctx)) {
            Some(false) => Value::Bool(false),
            Some(true) => eval(rhs, ctx),
            None => match truth(eval(rhs, ctx)) {
                Some(false) => Value::Bool(false),
                _ => Value::Null,
            },
        },
        Expr::Or(lhs, rhs) => match truth(eval(lhs, ctx)) {
            Some(true) => Value::Bool(true),
            Some(false) => eval(rhs, ctx),
            None => match truth(eval(rhs, ctx)) {
                Some(true) => Value::Bool(true),
                _ => Value::Null,
            },
        },
        Expr::Case { when, then, else_ } => {
            if truth(eval(when, ctx)) == Some(true) {
                eval(then, ctx)
            } else if let Some(else_) = else_ {
                eval(else_, ctx)
            } else {
                Value::Null
            }
        }
        Expr::Cast(inner, kind) => cast(eval(inner, ctx), *kind),
        Expr::TimeSlice(inner, seconds) => match eval(inner, ctx) {
            Value::Time(dt) => Value::Time(time_slice(dt, *seconds)),
            Value::Null => Value::Null,
            other => panic!("time_slice {other:?}"),
        },
        Expr::SecondsAdd(dt, n, sub) => match (eval(dt, ctx), eval(n, ctx)) {
            (Value::Time(dt), Value::Num(n)) => {
                let secs = if *sub { -n } else { n };
                Value::Time(dt + Duration::seconds(secs as i64))
            }
            (Value::Null, _) | (_, Value::Null) => Value::Null,
            other => panic!("seconds_add {other:?}"),
        },
        Expr::SecondsDiff(a, b) | Expr::MillisDiff(a, b) => {
            let scale = if matches!(expr, Expr::MillisDiff(_, _)) {
                1_000
            } else {
                1
            };
            match (eval(a, ctx), eval(b, ctx)) {
                (Value::Time(a), Value::Time(b)) => {
                    Value::Num(((a - b).num_milliseconds() * scale / 1_000) as f64)
                }
                (Value::Null, _) | (_, Value::Null) => Value::Null,
                other => panic!("diff {other:?}"),
            }
        }
        Expr::Floor(inner) => match eval(inner, ctx) {
            Value::Num(n) => Value::Num(n.floor()),
            Value::Null => Value::Null,
            other => panic!("floor {other:?}"),
        },
        Expr::Greatest(args, greatest) => extreme(args, ctx, *greatest),
        Expr::Coalesce(args) => {
            for arg in args {
                let value = eval(arg, ctx);
                if !matches!(value, Value::Null) {
                    return value;
                }
            }
            Value::Null
        }
    }
}

fn arith(op: BinOp, lhs: Value, rhs: Value) -> Value {
    match (lhs, rhs) {
        (Value::Null, _) | (_, Value::Null) => Value::Null,
        (Value::Num(a), Value::Num(b)) => Value::Num(match op {
            BinOp::Add => a + b,
            BinOp::Sub => a - b,
            BinOp::Mul => a * b,
            BinOp::Div => a / b,
        }),
        other => panic!("arith {other:?}"),
    }
}

fn compare(op: CmpOp, lhs: Value, rhs: Value) -> Value {
    let lhs = coerce_time(lhs);
    let rhs = coerce_time(rhs);
    let ord = match (&lhs, &rhs) {
        (Value::Null, _) | (_, Value::Null) => return Value::Null,
        (Value::Num(a), Value::Num(b)) => a.partial_cmp(b),
        (Value::Time(a), Value::Time(b)) => a.partial_cmp(b),
        (Value::Text(a), Value::Text(b)) => Some(a.cmp(b)),
        (Value::Bool(a), Value::Bool(b)) => Some(a.cmp(b)),
        _ => None,
    };
    let Some(ord) = ord else {
        panic!("compare {lhs:?} {rhs:?}");
    };
    Value::Bool(match op {
        CmpOp::Eq => ord.is_eq(),
        CmpOp::Ne => ord.is_ne(),
        CmpOp::Lt => ord.is_lt(),
        CmpOp::Gt => ord.is_gt(),
        CmpOp::Le => ord.is_le(),
        CmpOp::Ge => ord.is_ge(),
    })
}

fn coerce_time(value: Value) -> Value {
    if let Value::Text(text) = &value
        && let Some(dt) = parse_dt(text)
    {
        return Value::Time(dt);
    }
    value
}

fn truth(value: Value) -> Option<bool> {
    match value {
        Value::Bool(b) => Some(b),
        Value::Null => None,
        other => panic!("truth {other:?}"),
    }
}

fn cast(value: Value, kind: CastKind) -> Value {
    match (value, kind) {
        (Value::Null, _) => Value::Null,
        (Value::Num(n), CastKind::Double) => Value::Num(n),
        (Value::Text(text), CastKind::Datetime) => {
            Value::Time(parse_dt(&text).unwrap_or_else(|| panic!("datetime {text}")))
        }
        (Value::Time(dt), CastKind::String) => Value::Text(stamp(dt)),
        (Value::Text(text), CastKind::String) => Value::Text(text),
        (Value::Num(n), CastKind::String) => Value::Text(n.to_string()),
        other => panic!("cast {other:?}"),
    }
}

fn extreme(args: &[Expr], ctx: &Ctx<'_>, greatest: bool) -> Value {
    let mut best: Option<Value> = None;
    for arg in args {
        let value = eval(arg, ctx);
        if matches!(value, Value::Null) {
            return Value::Null;
        }
        best = Some(match best {
            None => value,
            Some(current) => {
                let ord = match compare(CmpOp::Gt, value.clone(), current.clone()) {
                    Value::Bool(true) => true,
                    Value::Bool(false) => false,
                    other => panic!("extreme {other:?}"),
                };
                if ord == greatest { value } else { current }
            }
        });
    }
    best.unwrap_or(Value::Null)
}

fn parse_dt(text: &str) -> Option<DateTime<Utc>> {
    if let Ok(dt) = DateTime::parse_from_rfc3339(text) {
        return Some(dt.with_timezone(&Utc));
    }
    NaiveDateTime::parse_from_str(text, "%Y-%m-%d %H:%M:%S")
        .ok()
        .map(|dt| DateTime::<Utc>::from_naive_utc_and_offset(dt, Utc))
}

fn stamp(dt: DateTime<Utc>) -> String {
    dt.format("%Y-%m-%d %H:%M:%S").to_string()
}

fn time_slice(dt: DateTime<Utc>, seconds: i64) -> DateTime<Utc> {
    let secs = dt.timestamp();
    let width = seconds.max(1);
    DateTime::<Utc>::from_timestamp(secs - secs.rem_euclid(width), 0).expect("slice")
}

fn at(text: &str) -> DateTime<Utc> {
    parse_dt(text).unwrap_or_else(|| panic!("time {text}"))
}

#[derive(Clone, Debug)]
enum Agg {
    Sum(Expr),
    Count(Expr),
    Avg(Expr),
    Value(Expr),
}

struct Item {
    agg: Agg,
    alias: String,
}

struct Query {
    items: Vec<Item>,
    from_series: Option<(Expr, Expr, Expr)>,
    filter: Option<Expr>,
    group: Vec<Expr>,
    limit: Option<usize>,
}

fn query_body(sql: &str) -> &str {
    let Some(end) = sql.find(") windowed") else {
        return sql;
    };
    let bytes = sql.as_bytes();
    let mut depth = 0;
    let mut open = None;
    for (i, byte) in bytes.iter().enumerate().take(end) {
        match byte {
            b'(' => {
                if depth == 0 {
                    open = Some(i);
                }
                depth += 1;
            }
            b')' => depth -= 1,
            _ => {}
        }
    }
    let open = open.expect("windowed wrapper");
    &sql[open + 1..end]
}

fn split_top(sql: &str) -> Vec<(String, String)> {
    let bytes = sql.as_bytes();
    let keywords = [
        "SELECT", "FROM", "WHERE", "GROUP", "ORDER", "LIMIT", "OFFSET",
    ];
    let mut marks = Vec::new();
    let mut depth = 0;
    let mut quote = false;
    let mut i = 0;
    while i < bytes.len() {
        if quote {
            if bytes[i] == b'\'' {
                if i + 1 < bytes.len() && bytes[i + 1] == b'\'' {
                    i += 2;
                    continue;
                }
                quote = false;
            }
            i += 1;
            continue;
        }
        match bytes[i] {
            b'\'' => {
                quote = true;
                i += 1;
            }
            b'(' => {
                depth += 1;
                i += 1;
            }
            b')' => {
                depth -= 1;
                i += 1;
            }
            _ if depth == 0 => {
                let rest = &sql[i..];
                let boundary = i == 0 || bytes[i - 1].is_ascii_whitespace() || bytes[i - 1] == b'(';
                let mut matched = None;
                if boundary {
                    for word in keywords {
                        let ok = rest.len() >= word.len()
                            && rest[..word.len()].eq_ignore_ascii_case(word)
                            && rest
                                .as_bytes()
                                .get(word.len())
                                .is_none_or(|c| !c.is_ascii_alphanumeric() && *c != b'_');
                        if ok {
                            matched = Some((*word).to_string());
                            break;
                        }
                    }
                }
                if let Some(word) = matched {
                    marks.push((i, word.clone()));
                    i += word.len();
                } else {
                    i += 1;
                }
            }
            _ => i += 1,
        }
    }
    marks
        .iter()
        .enumerate()
        .map(|(n, (pos, word))| {
            let text_start = pos + word.len();
            let text_end = marks.get(n + 1).map(|(next, _)| *next).unwrap_or(sql.len());
            (word.clone(), sql[text_start..text_end].to_string())
        })
        .collect()
}

fn parse_query(sql: &str) -> Query {
    let body = query_body(sql);
    let parts = split_top(body);
    let mut select = None;
    let mut from = None;
    let mut filter = None;
    let mut group = None;
    let mut limit = None;
    for (word, text) in parts {
        match word.as_str() {
            "SELECT" => select = Some(text),
            "FROM" => from = Some(text),
            "WHERE" => filter = Some(text),
            "GROUP" => {
                group = Some(
                    text.trim_start_matches([' ', '\n'])
                        .trim_start_matches("BY")
                        .trim()
                        .to_string(),
                )
            }
            "LIMIT" => {
                let n = text.split_whitespace().next().unwrap_or("0");
                limit = Some(n.parse().expect("limit"));
            }
            _ => {}
        }
    }
    let select = select.expect("select");
    // Row listings project helpers this executor does not model. They also do not
    // aggregate, so the observable is how many rows the FROM clause emits.
    let items = if select_aggregates(&select) {
        split_commas(&select)
            .into_iter()
            .map(parse_item)
            .collect::<Vec<_>>()
    } else {
        Vec::new()
    };
    let from_series = from.as_deref().and_then(parse_series);
    let filter = filter.map(|text| Parser::new(text.trim()).expr());
    let group = group
        .map(|text| {
            split_commas(&text)
                .into_iter()
                .map(|piece| {
                    let piece = piece.trim();
                    if let Ok(index) = piece.parse::<usize>() {
                        let item = items
                            .get(index - 1)
                            .unwrap_or_else(|| panic!("group {index}"));
                        match &item.agg {
                            Agg::Value(expr) => expr.clone(),
                            _ => panic!("grouped an aggregate"),
                        }
                    } else {
                        Parser::new(piece).expr()
                    }
                })
                .collect()
        })
        .unwrap_or_default();
    Query {
        items,
        from_series,
        filter,
        group,
        limit,
    }
}

fn select_aggregates(select: &str) -> bool {
    let bytes = select.as_bytes();
    let mut depth = 0;
    let mut quote = false;
    let mut i = 0;
    while i < bytes.len() {
        if quote {
            if bytes[i] == b'\'' {
                quote = false;
            }
            i += 1;
            continue;
        }
        match bytes[i] {
            b'\'' => quote = true,
            b'(' => depth += 1,
            b')' => depth -= 1,
            _ if depth == 0 => {
                let rest = &select[i..];
                for word in ["sum(", "count(", "avg("] {
                    if rest.len() >= word.len() && rest[..word.len()].eq_ignore_ascii_case(word) {
                        return true;
                    }
                }
            }
            _ => {}
        }
        i += 1;
    }
    false
}

fn parse_series(from: &str) -> Option<(Expr, Expr, Expr)> {
    let marker = "generate_series(";
    let start = from.to_ascii_lowercase().find(marker)?;
    let mut parser = Parser::new(&from[start + marker.len() - 1..]);
    parser.expect("(");
    let a = parser.expr();
    parser.expect(",");
    let b = parser.expr();
    parser.expect(",");
    let c = parser.expr();
    parser.expect(")");
    Some((a, b, c))
}

fn parse_item(piece: String) -> Item {
    let piece = piece.trim();
    let (expr_sql, alias) = match piece.rfind(" AS ") {
        Some(at) => {
            let alias = piece[at + 4..].trim().trim_matches('`').to_string();
            (piece[..at].trim(), alias)
        }
        None => (piece, "value".to_string()),
    };
    let mut parser = Parser::new(expr_sql);
    let head = parser.ident();
    let agg = if parser.eat_symbol("(")
        && let Some(name) = &head
        && matches!(name.to_ascii_lowercase().as_str(), "sum" | "count" | "avg")
    {
        let lower = name.to_ascii_lowercase();
        if parser.keyword("DISTINCT") {
            panic!("count distinct is outside this executor");
        }
        let inner = if parser.eat_symbol(")") {
            Expr::Star
        } else {
            let inner = parser.expr();
            parser.expect(")");
            inner
        };
        match lower.as_str() {
            "sum" => Agg::Sum(inner),
            "count" => Agg::Count(inner),
            "avg" => Agg::Avg(inner),
            _ => unreachable!(),
        }
    } else {
        Agg::Value(Parser::new(expr_sql).expr())
    };
    Item { agg, alias }
}

fn split_commas(sql: &str) -> Vec<String> {
    let mut out = Vec::new();
    let bytes = sql.as_bytes();
    let mut depth = 0;
    let mut quote = false;
    let mut start = 0;
    let mut i = 0;
    while i < bytes.len() {
        if quote {
            if bytes[i] == b'\'' {
                if i + 1 < bytes.len() && bytes[i + 1] == b'\'' {
                    i += 2;
                    continue;
                }
                quote = false;
            }
            i += 1;
            continue;
        }
        match bytes[i] {
            b'\'' => quote = true,
            b'(' => depth += 1,
            b')' => depth -= 1,
            b',' if depth == 0 => {
                out.push(sql[start..i].trim().to_string());
                start = i + 1;
            }
            _ => {}
        }
        i += 1;
    }
    let tail = sql[start..].trim();
    if !tail.is_empty() {
        out.push(tail.to_string());
    }
    out
}

#[derive(Clone)]
struct Flow {
    end: DateTime<Utc>,
    start: Option<DateTime<Utc>>,
    stop: Option<DateTime<Utc>>,
    bytes_total: Option<f64>,
    bytes_in: Option<f64>,
    packets_total: Option<f64>,
    sampling_rate: Option<f64>,
    event_type: Option<&'static str>,
    src_endpoint_ip: Option<&'static str>,
    /// Rollup rows are already booked on an hour bucket.
    bucket: Option<DateTime<Utc>>,
    value: Option<f64>,
}

impl Flow {
    fn raw(start: Option<&str>, end: &str) -> Self {
        Self {
            end: at(end),
            start: start.map(at),
            stop: start.map(|_| at(end)),
            bytes_total: None,
            bytes_in: None,
            packets_total: None,
            sampling_rate: Some(1.0),
            event_type: None,
            src_endpoint_ip: None,
            bucket: None,
            value: None,
        }
    }

    fn row(&self) -> HashMap<String, Value> {
        let mut row = HashMap::new();
        row.insert("time".into(), Value::Time(self.end));
        row.insert("timestamp".into(), Value::Time(self.end));
        row.insert(
            "start_time".into(),
            self.start.map(Value::Time).unwrap_or(Value::Null),
        );
        row.insert(
            "end_time".into(),
            self.stop.map(Value::Time).unwrap_or(Value::Null),
        );
        let num = |value: Option<f64>| value.map(Value::Num).unwrap_or(Value::Null);
        row.insert("bytes_total".into(), num(self.bytes_total));
        row.insert("bytes_in".into(), num(self.bytes_in));
        row.insert("bytes_out".into(), Value::Num(0.0));
        row.insert("packets_total".into(), num(self.packets_total));
        row.insert("packets_in".into(), Value::Num(0.0));
        row.insert("packets_out".into(), Value::Num(0.0));
        row.insert("sampling_rate".into(), num(self.sampling_rate));
        row.insert(
            "event_type".into(),
            self.event_type
                .map(|text| Value::Text(text.into()))
                .unwrap_or(Value::Null),
        );
        row.insert(
            "src_endpoint_ip".into(),
            self.src_endpoint_ip
                .map(|text| Value::Text(text.into()))
                .unwrap_or(Value::Null),
        );
        if let Some(bucket) = self.bucket {
            row.insert("bucket".into(), Value::Time(bucket));
        }
        row.insert("value".into(), num(self.value));
        row
    }
}

struct Ran {
    /// group key -> alias -> number. Absent aliases were NULL.
    cells: BTreeMap<String, BTreeMap<String, i64>>,
    expanded: usize,
}

fn execute(sql: &str, flows: &[Flow]) -> Ran {
    let query = parse_query(sql);
    let mut acc: BTreeMap<String, BTreeMap<String, (f64, i64)>> = BTreeMap::new();
    let mut expanded = 0;
    for flow in flows {
        let row = flow.row();
        let ks = match &query.from_series {
            Some((start, end, step)) => {
                let ctx = Ctx { row: &row, k: None };
                let start = num(&eval(start, &ctx));
                let end = num(&eval(end, &ctx));
                let step = num(&eval(step, &ctx));
                series(start, end, step)
            }
            None => vec![0],
        };
        for k in ks {
            let ctx = Ctx {
                row: &row,
                k: Some(k),
            };
            if let Some(filter) = &query.filter
                && truth(eval(filter, &ctx)) != Some(true)
            {
                continue;
            }
            expanded += 1;
            let key = if query.group.is_empty()
                && query
                    .items
                    .iter()
                    .all(|item| matches!(item.agg, Agg::Value(_)))
            {
                format!("{expanded}")
            } else if query.group.is_empty() {
                let keys: Vec<Expr> = query
                    .items
                    .iter()
                    .filter_map(|item| match &item.agg {
                        Agg::Value(expr) => Some(expr.clone()),
                        _ => None,
                    })
                    .collect();
                keys.iter()
                    .map(|expr| show(&eval(expr, &ctx)))
                    .collect::<Vec<_>>()
                    .join("|")
            } else {
                query
                    .group
                    .iter()
                    .map(|expr| show(&eval(expr, &ctx)))
                    .collect::<Vec<_>>()
                    .join("|")
            };
            let entry = acc.entry(key).or_default();
            for item in &query.items {
                match &item.agg {
                    Agg::Value(_) => {}
                    Agg::Sum(expr) => match eval(expr, &ctx) {
                        Value::Null => {}
                        Value::Num(n) => {
                            let cell = entry.entry(item.alias.clone()).or_insert((0.0, 0));
                            cell.0 += n;
                            cell.1 += 1;
                        }
                        other => panic!("sum {other:?}"),
                    },
                    Agg::Count(expr) => {
                        let counts =
                            !matches!(expr, Expr::Star) && matches!(eval(expr, &ctx), Value::Null);
                        if !counts {
                            let cell = entry.entry(item.alias.clone()).or_insert((0.0, 0));
                            cell.0 += 1.0;
                        }
                    }
                    Agg::Avg(expr) => match eval(expr, &ctx) {
                        Value::Null => {}
                        Value::Num(n) => {
                            let cell = entry.entry(item.alias.clone()).or_insert((0.0, 0));
                            cell.0 += n;
                            cell.1 += 1;
                        }
                        other => panic!("avg {other:?}"),
                    },
                }
            }
        }
    }
    let mut cells = BTreeMap::new();
    for (key, aggs) in acc {
        let mut out = BTreeMap::new();
        for item in &query.items {
            if let Some((sum, n)) = aggs.get(&item.alias) {
                let value = match item.agg {
                    Agg::Avg(_) => {
                        if *n == 0 {
                            continue;
                        }
                        sum / (*n as f64)
                    }
                    _ => *sum,
                };
                out.insert(item.alias.clone(), as_i64(value));
            }
        }
        if !out.is_empty()
            || query
                .items
                .iter()
                .any(|item| matches!(item.agg, Agg::Value(_)))
        {
            cells.insert(key, out);
        }
    }
    if let Some(limit) = query.limit {
        while cells.len() > limit {
            cells.pop_last();
        }
    }
    Ran { cells, expanded }
}

fn series(start: i64, end: i64, step: i64) -> Vec<i64> {
    let mut out = Vec::new();
    if step == 0 {
        panic!("generate_series step 0");
    }
    if step > 0 && start <= end {
        let mut v = start;
        while v <= end {
            out.push(v);
            v += step;
        }
    } else if step < 0 && start >= end {
        let mut v = start;
        while v >= end {
            out.push(v);
            v += step;
        }
    }
    out
}

fn num(value: &Value) -> i64 {
    match value {
        Value::Num(n) => as_i64(*n),
        other => panic!("number {other:?}"),
    }
}

fn as_i64(n: f64) -> i64 {
    assert!((n - n.round()).abs() < 1e-4, "non-integral aggregate {n}");
    n.round() as i64
}

fn show(value: &Value) -> String {
    match value {
        Value::Time(dt) => stamp(*dt),
        Value::Num(n) => as_i64(*n).to_string(),
        Value::Text(text) => text.clone(),
        Value::Null => "null".into(),
        Value::Bool(b) => b.to_string(),
    }
}

fn column(ran: &Ran, alias: &str) -> BTreeMap<String, i64> {
    let mut out = BTreeMap::new();
    for (key, aggs) in &ran.cells {
        let Some(value) = aggs.get(alias) else {
            continue;
        };
        // Downsample queries also group by the chart series. An unsplit chart's
        // series is NULL, so the bucket is the timestamp in front of `|null`.
        let bucket = match key.rsplit_once('|') {
            Some((bucket, "null")) => bucket.to_string(),
            _ => key.clone(),
        };
        *out.entry(bucket).or_default() += *value;
    }
    out
}

/// Share rule from the language reference and the #5970 review decision.
/// `v` is the already-sampled volume. Buckets are keyed by their start.
fn oracle(
    v: f64,
    start: Option<DateTime<Utc>>,
    end: DateTime<Utc>,
    bucket_s: i64,
    window_start: DateTime<Utc>,
) -> BTreeMap<String, i64> {
    let home = time_slice(end, bucket_s);
    let spreads = start.is_some_and(|start| start < end && (home - start).num_milliseconds() > 0);
    if !spreads {
        return BTreeMap::from([(stamp(home), as_i64(v))]);
    }
    let start = start.expect("start");
    let credited = start.max(time_slice(window_start, bucket_s));
    let earliest_raw = credited.max(home - Duration::seconds((MAX_BUCKETS - 1) * bucket_s));
    let earliest = time_slice(earliest_raw, bucket_s);
    let duration = (end - start).num_milliseconds() as f64;
    let c = |boundary: DateTime<Utc>| -> f64 {
        let elapsed = (boundary - start).num_milliseconds() as f64;
        (v * (elapsed / duration)).floor()
    };
    let mut out = BTreeMap::new();
    let mut bucket = earliest;
    while bucket <= home {
        let hi = end.min(bucket + Duration::seconds(bucket_s));
        let lo = if bucket == earliest { credited } else { bucket };
        let share = as_i64(c(hi) - c(lo));
        out.insert(stamp(bucket), share);
        bucket += Duration::seconds(bucket_s);
    }
    out
}

fn sampled(bytes: f64, rate: f64) -> f64 {
    bytes * rate.max(1.0)
}

fn sql_of(query: &str) -> String {
    translate(&plan(query), "serviceradar")
        .unwrap_or_else(|err| panic!("{query}: {err}"))
        .sql
}

fn sql_raw(query: &str) -> String {
    translate_raw(&plan(query), "serviceradar")
        .unwrap_or_else(|err| panic!("{query}: {err}"))
        .sql
}

fn assert_buckets(
    label: &str,
    sql: &str,
    flows: &[Flow],
    alias: &str,
    expect: &BTreeMap<String, i64>,
) {
    let ran = execute(sql, flows);
    let got = column(&ran, alias);
    assert_eq!(got, *expect, "{label}\n{sql}");
}

fn sum_of(map: &BTreeMap<String, i64>) -> i64 {
    map.values().sum()
}

#[test]
fn flow_volume_shares_match_the_real_interval() {
    let window = "time:[2026-01-01T09:00:00Z,2026-01-01T18:00:00Z]";
    let window_start = at("2026-01-01 09:00:00");

    // Five-minute flow, one billion bytes. The chart used to draw one spike.
    let five = "in:flows {window} bucket:1m agg:sum value_field:bytes_total limit:300"
        .replace("{window}", window);
    let mut flow = Flow::raw(Some("2026-01-01 10:00:00"), "2026-01-01 10:05:00");
    flow.bytes_total = Some(1_000_000_000.0);
    let expect = oracle(1_000_000_000.0, flow.start, flow.end, 60, window_start);
    let sql = sql_of(&five);
    assert_buckets("five minute sum", &sql, &[flow.clone()], "value", &expect);
    assert_eq!(sum_of(&expect), 1_000_000_000);
    for minute in 0..5 {
        let key = format!("2026-01-01 10:0{minute}:00");
        assert_eq!(expect.get(&key).copied(), Some(200_000_000), "{key}");
    }
    assert_eq!(expect.get("2026-01-01 10:05:00").copied(), Some(0));

    // The same flow through stats, packets, attributed flows, and rate_sum.
    let packets =
        format!(r#"in:flows {window} stats:"sum(packets_total) as packets by time:1m" limit:300"#);
    flow.packets_total = Some(1_000_000_000.0);
    let packet_sql = sql_of(&packets);
    assert_buckets(
        "stats packets",
        &packet_sql,
        &[flow.clone()],
        "packets",
        &expect,
    );
    let mut attributed = flow.clone();
    attributed.event_type = Some("attributed_flow");
    attributed.bytes_in = Some(1_000_000_000.0);
    attributed.bytes_total = None;
    let rate = format!(
        "in:attributed_flows {window} bucket:1m agg:rate_sum value_field:bytes_in limit:300"
    );
    assert_buckets(
        "attributed rate_sum",
        &sql_of(&rate),
        &[attributed],
        "value",
        &expect,
    );

    // Partial buckets and an odd byte count still telescope to the exact total.
    let mut odd = Flow::raw(Some("2026-01-01 10:00:20"), "2026-01-01 10:03:20");
    odd.bytes_total = Some(1_000_000_007.0);
    let odd_expect = oracle(1_000_000_007.0, odd.start, odd.end, 60, window_start);
    assert_eq!(sum_of(&odd_expect), 1_000_000_007);
    assert_ne!(
        odd_expect.get("2026-01-01 10:00:00"),
        odd_expect.get("2026-01-01 10:01:00"),
        "equal splits would hide a by-bucket-count bug"
    );
    assert_buckets("odd partial", &sql, &[odd], "value", &odd_expect);

    // Ten-hour flow ending on an hour boundary, one-hour window. The share is
    // the real in-window fraction, not the fraction of the capped 239 minutes.
    let hour = "time:[2026-01-01T10:00:00Z,2026-01-01T11:00:01Z]";
    let hour_sql = sql_of(&format!(
        "in:flows {hour} bucket:1m agg:sum value_field:bytes_total limit:300"
    ));
    let mut long = Flow::raw(Some("2026-01-01 01:00:00"), "2026-01-01 11:00:00");
    long.bytes_total = Some(1_000_000_000.0);
    let hour_expect = oracle(
        1_000_000_000.0,
        long.start,
        long.end,
        60,
        at("2026-01-01 10:00:00"),
    );
    let clip_total = sum_of(&hour_expect);
    assert_eq!(clip_total, 100_000_000);
    assert_ne!(clip_total, 251_046_025);
    assert_buckets("window clip", &hour_sql, &[long], "value", &hour_expect);

    // Six-hour flow inside a wide window: 240 buckets, prefix folded into the first.
    let mut six = Flow::raw(Some("2026-01-01 10:00:00"), "2026-01-01 16:00:00");
    six.bytes_total = Some(21_600.0);
    let six_expect = oracle(21_600.0, six.start, six.end, 60, window_start);
    assert_eq!(six_expect.len(), 240);
    assert_eq!(sum_of(&six_expect), 21_600);
    assert_eq!(six_expect.get("2026-01-01 12:01:00").copied(), Some(7_320));
    assert_eq!(six_expect.get("2026-01-01 12:02:00").copied(), Some(60));
    assert_buckets("cap fold", &sql, &[six.clone()], "value", &six_expect);

    // Three hours on the boundary expands through the closing bucket and keeps the total.
    let mut three = Flow::raw(Some("2026-01-01 10:00:00"), "2026-01-01 13:00:00");
    three.bytes_total = Some(1_000_000_000.0);
    let three_expect = oracle(1_000_000_000.0, three.start, three.end, 60, window_start);
    assert_eq!(three_expect.len(), 181);
    assert_eq!(sum_of(&three_expect), 1_000_000_000);
    assert_buckets("three hour", &sql, &[three], "value", &three_expect);

    // NULL start, zero duration, reversed interval, and a flow inside its own bucket.
    for (label, start) in [
        ("null start", None),
        ("zero duration", Some("2026-01-01 10:04:00")),
        ("reversed", Some("2026-01-01 10:06:00")),
        ("inside bucket", Some("2026-01-01 10:04:10")),
    ] {
        let mut row = Flow::raw(start, "2026-01-01 10:04:40");
        if label == "null start" {
            row.start = None;
            row.stop = None;
        }
        if label == "zero duration" {
            row.stop = Some(at("2026-01-01 10:04:40"));
            row.start = Some(at("2026-01-01 10:04:40"));
        }
        if label == "reversed" {
            row.stop = Some(row.end);
        }
        if label == "inside bucket" {
            row.stop = Some(row.end);
        }
        row.bytes_total = Some(50.0);
        let expect = oracle(50.0, row.start, row.end, 60, window_start);
        assert_eq!(expect.len(), 1, "{label}");
        assert_eq!(sum_of(&expect), 50, "{label}");
        assert_buckets(label, &sql, &[row], "value", &expect);
    }

    // Sampling scales the volume once, then the shares split that product.
    let mut sampled_flow = Flow::raw(Some("2026-01-01 10:00:00"), "2026-01-01 10:05:00");
    sampled_flow.bytes_total = Some(100.0);
    sampled_flow.sampling_rate = Some(10.0);
    let sampled_expect = oracle(
        sampled(100.0, 10.0),
        sampled_flow.start,
        sampled_flow.end,
        60,
        window_start,
    );
    assert_eq!(sum_of(&sampled_expect), 1_000);
    assert_eq!(
        sampled_expect.get("2026-01-01 10:00:00").copied(),
        Some(200)
    );
    assert_buckets(
        "sampled once",
        &sql,
        &[sampled_flow],
        "value",
        &sampled_expect,
    );

    // Hour buckets stay on the hour the flow ended, on the rollup and the raw fallback.
    let hour_query = "in:flows time:[2026-01-01T10:00:00Z,2026-01-01T16:00:00Z] bucket:1h agg:sum value_field:bytes_total limit:50";
    let mut ended = Flow::raw(Some("2026-01-01 11:00:00"), "2026-01-01 13:30:00");
    ended.bytes_total = Some(1_000_000_000.0);
    ended.bucket = Some(ended.end);
    let hour_expect = BTreeMap::from([("2026-01-01 13:00:00".to_string(), 1_000_000_000)]);
    let rollup_sql = sql_of(hour_query);
    let raw_sql = sql_raw(hour_query);
    assert!(
        !rollup_sql.to_ascii_lowercase().contains("generate_series"),
        "{rollup_sql}"
    );
    assert!(
        !raw_sql.to_ascii_lowercase().contains("generate_series"),
        "{raw_sql}"
    );
    assert_buckets(
        "hour rollup",
        &rollup_sql,
        &[ended.clone()],
        "value",
        &hour_expect,
    );
    assert_buckets("hour raw", &raw_sql, &[ended], "value", &hour_expect);

    // count and avg read the flow once, in the bucket it ended in.
    let mut mixed_flow = Flow::raw(Some("2026-01-01 10:00:00"), "2026-01-01 10:04:30");
    mixed_flow.bytes_total = Some(270.0);
    let mixed = format!(
        r#"in:flows {window} stats:"sum(bytes_total) as bytes, count(*) as flows, avg(bytes_total) as mean by time:1m" limit:300"#
    );
    let mixed_sql = sql_of(&mixed);
    let mixed_ran = execute(&mixed_sql, &[mixed_flow.clone()]);
    let bytes = column(&mixed_ran, "bytes");
    let byte_expect = oracle(270.0, mixed_flow.start, mixed_flow.end, 60, window_start);
    assert_eq!(bytes, byte_expect, "{mixed_sql}");
    assert_eq!(sum_of(&bytes), 270);
    let counts = column(&mixed_ran, "flows");
    assert_eq!(counts.get("2026-01-01 10:04:00").copied(), Some(1));
    assert_eq!(counts.values().sum::<i64>(), 1);
    let means = column(&mixed_ran, "mean");
    assert_eq!(means.get("2026-01-01 10:04:00").copied(), Some(270));
    assert_eq!(means.len(), 1);

    let count_sql = sql_of(&format!("in:flows {window} bucket:1m agg:count limit:300"));
    let counted = execute(&count_sql, &[mixed_flow.clone()]);
    assert_eq!(
        column(&counted, "value").values().sum::<i64>(),
        1,
        "{count_sql}"
    );

    let avg_sql = sql_of(&format!(
        "in:flows {window} bucket:1m agg:avg value_field:bytes_total limit:300"
    ));
    let averaged = column(&execute(&avg_sql, &[mixed_flow.clone()]), "value");
    assert_eq!(averaged.len(), 1, "{avg_sql}");
    assert_eq!(sum_of(&averaged), 270);

    // A sum grouped by address does not multiply the flow by its bucket count.
    let by_ip = format!(
        r#"in:flows {window} stats:"sum(bytes_total) as bytes by src_endpoint_ip" limit:50"#
    );
    let mut hosted = mixed_flow.clone();
    hosted.src_endpoint_ip = Some("192.0.2.10");
    let grouped = execute(&sql_of(&by_ip), &[hosted]);
    let grouped_bytes = column(&grouped, "bytes");
    assert_eq!(grouped_bytes.len(), 1);
    assert_eq!(sum_of(&grouped_bytes), 270);

    // A row listing is one row, and a metric sum is not a flow spread.
    let listing = sql_of(&format!("in:flows {window} limit:50"));
    let listed = execute(&listing, &[mixed_flow]);
    assert_eq!(listed.expanded, 1, "{listing}");
    let metric = sql_of(&format!(
        "in:timeseries_metrics {window} bucket:1m agg:sum limit:300"
    ));
    let mut sample = Flow::raw(None, "2026-01-01 10:04:40");
    sample.value = Some(12.0);
    let metric_ran = column(&execute(&metric, &[sample]), "value");
    assert_eq!(metric_ran.len(), 1, "{metric}");
    assert_eq!(sum_of(&metric_ran), 12);

    let report = format!(
        "{{\"five_minute_nonzero\":200000000,\"window_clip\":{},\"cap_rows\":{},\"cap_first\":{},\"three_hour_rows\":{}}}",
        clip_total,
        six_expect.len(),
        six_expect.get("2026-01-01 12:01:00").copied().unwrap(),
        three_expect.len()
    );
    println!("FLOW_SPREAD_REPORT={report}");
}
