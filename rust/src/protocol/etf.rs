use super::MAX_FRAME_BYTES;
use anyhow::{Context, Result, bail, ensure};
use num_bigint::{BigInt, Sign};
use std::borrow::Cow;
use std::cmp::Ordering;
use std::collections::BTreeMap;

const VERSION: u8 = 131;
pub(super) const MAX_DEPTH: usize = 64;
pub(super) const MAX_TERMS: usize = 100_000;

/// BEAM data supported by the Rust API, without executable guest objects or process handles.
/// Rust strings and byte vectors convert to binaries; booleans convert to the atoms
/// `true` and `false`. Use [`Value::atom`] to construct other atoms explicitly.
/// Atom names remain strings on the Rust host. The guest accepts only atoms already loaded there.
///
/// Maps compare by their keys and values, regardless of insertion order.
/// Float keys distinguish negative zero from positive zero.
///
/// Rust's `Ord` groups values by variant before comparing their contents.
/// This order differs from Erlang term order.
#[derive(Clone, Debug)]
pub enum Value {
    /// Atom name, including `true`, `false`, and `nil`.
    Atom(String),
    /// Arbitrary bytes; the binary need not be UTF-8 text.
    Binary(Vec<u8>),
    /// Arbitrary-precision integer.
    Integer(BigInt),
    /// Double-precision floating-point value.
    Float(f64),
    /// Proper list. Improper lists cannot be represented.
    List(Vec<Value>),
    /// Tuple whose elements may have different types.
    Tuple(Vec<Value>),
    /// Map with any supported value as a key.
    Map(BTreeMap<Value, Value>),
}

impl PartialEq for Value {
    fn eq(&self, other: &Self) -> bool {
        self.cmp(other) == Ordering::Equal
    }
}

impl Eq for Value {}

impl PartialOrd for Value {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for Value {
    fn cmp(&self, other: &Self) -> Ordering {
        match (self, other) {
            (Self::Atom(a), Self::Atom(b)) => a.cmp(b),
            (Self::Binary(a), Self::Binary(b)) => a.cmp(b),
            (Self::Integer(a), Self::Integer(b)) => a.cmp(b),
            (Self::Float(a), Self::Float(b)) => a.total_cmp(b),
            (Self::List(a), Self::List(b)) | (Self::Tuple(a), Self::Tuple(b)) => a.cmp(b),
            (Self::Map(a), Self::Map(b)) => a.iter().cmp(b),
            _ => self.kind_order().cmp(&other.kind_order()),
        }
    }
}

impl Value {
    /// Constructs an atom by name. Sending it requires the atom to exist in the guest.
    pub fn atom(name: impl Into<String>) -> Self {
        Self::Atom(name.into())
    }

    /// Copies bytes into a binary without requiring UTF-8 text.
    pub fn binary(bytes: impl AsRef<[u8]>) -> Self {
        Self::Binary(bytes.as_ref().into())
    }

    /// Builds a map. Later entries replace earlier values for the same key.
    pub fn map(entries: impl IntoIterator<Item = (Self, Self)>) -> Self {
        Self::Map(entries.into_iter().collect())
    }

    /// Looks up a map key. Returns `None` for a missing key or a non-map value.
    pub fn get(&self, key: &Value) -> Option<&Value> {
        let Self::Map(fields) = self else { return None };
        fields.get(key)
    }

    fn kind_order(&self) -> u8 {
        match self {
            Self::Atom(_) => 0,
            Self::Binary(_) => 1,
            Self::Integer(_) => 2,
            Self::Float(_) => 3,
            Self::List(_) => 4,
            Self::Tuple(_) => 5,
            Self::Map(_) => 6,
        }
    }

    /// Looks up a binary map key, such as a string field name. Does not match atom keys.
    /// Returns `None` for a missing key or a non-map value.
    pub fn get_binary(&self, key: impl AsRef<[u8]>) -> Option<&Value> {
        let Self::Map(fields) = self else { return None };
        fields.iter().find_map(|(field, value)| match field {
            Self::Binary(bytes) if bytes == key.as_ref() => Some(value),
            _ => None,
        })
    }
}

impl From<&str> for Value {
    fn from(value: &str) -> Self {
        Self::binary(value)
    }
}

impl From<String> for Value {
    fn from(value: String) -> Self {
        Self::Binary(value.into_bytes())
    }
}

impl From<Vec<u8>> for Value {
    fn from(value: Vec<u8>) -> Self {
        Self::Binary(value)
    }
}

macro_rules! integer_values {
    ($($number:ty),+) => {$(
        impl From<$number> for Value {
            fn from(value: $number) -> Self { Self::Integer(value.into()) }
        }
    )+};
}

integer_values!(i32, i64, u32, u64, usize, BigInt);

impl From<bool> for Value {
    fn from(value: bool) -> Self {
        Self::atom(if value { "true" } else { "false" })
    }
}

#[derive(Default)]
struct Budget {
    terms: usize,
}

impl Budget {
    fn charge(&mut self, depth: usize, count: usize) -> Result<()> {
        ensure!(depth <= MAX_DEPTH, "ETF nesting limit exceeded");
        ensure!(count <= MAX_TERMS - self.terms, "ETF term limit exceeded");
        self.terms += count;
        Ok(())
    }
}

pub(super) fn envelope<'a, const N: usize>(
    input: &'a [u8],
    names: [&[u8]; N],
) -> Result<[Option<Term<'a>>; N]> {
    let mut decoder = Decoder::new(unversioned(input)?);
    let Node::Map(len) = decoder.node()? else {
        bail!("expected an ETF envelope map");
    };
    ensure!(
        len <= (MAX_TERMS - 1) / 2,
        "ETF envelope has too many fields"
    );
    let mut fields = [None; N];
    for _ in 0..len {
        let (_, key) = decoder.atom()?;
        let value = decoder.slice()?;
        if let Some(index) = names.iter().position(|&name| name == key) {
            ensure!(
                fields[index].replace(value).is_none(),
                "duplicate ETF envelope field"
            );
        }
    }
    ensure!(decoder.bytes.is_empty(), "trailing ETF bytes");
    Ok(fields)
}

fn unversioned(input: &[u8]) -> Result<&[u8]> {
    let (version, rest) = input.split_first().context("missing ETF version")?;
    ensure!(*version == VERSION, "invalid ETF version");
    Ok(rest)
}

#[cfg(test)]
pub(super) fn decode(input: &[u8]) -> Result<Value> {
    let mut decoder = Decoder::new(unversioned(input)?);
    let value = decoder.term(0)?;
    ensure!(decoder.bytes.is_empty(), "trailing ETF bytes");
    Ok(value)
}

#[derive(Clone, Copy)]
pub(super) struct Term<'a>(&'a [u8]);

impl<'a> Term<'a> {
    pub(super) fn atom(self) -> Result<Cow<'a, str>> {
        let (utf8, bytes) = Decoder::new(self.0).atom()?;
        atom_name(utf8, bytes)
    }

    pub(super) fn binary(self) -> Result<&'a [u8]> {
        match Decoder::new(self.0).node()? {
            Node::Binary(bytes) => Ok(bytes),
            _ => bail!("expected an ETF binary"),
        }
    }

    pub(super) fn unsigned(self) -> Result<u32> {
        match Decoder::new(self.0).node()? {
            Node::Integer(value) => Ok(u32::try_from(value)?),
            Node::Big(0, digits) if digits.len() <= 4 => {
                let mut bytes = [0; 4];
                bytes[..digits.len()].copy_from_slice(digits);
                Ok(u32::from_le_bytes(bytes))
            }
            _ => bail!("expected a u32 ETF integer"),
        }
    }

    pub(super) fn value(self) -> Result<Value> {
        Decoder::new(self.0).term(1)
    }
}

enum Node<'a> {
    Atom(bool, &'a [u8]),
    Binary(&'a [u8]),
    Integer(i32),
    Big(u8, &'a [u8]),
    Float(f64),
    Nil,
    String(&'a [u8]),
    Tuple(usize),
    List(usize),
    Map(usize),
    Opaque { tag: u8, children: usize },
}

impl Node<'_> {
    fn children(&self) -> Result<usize> {
        Ok(match *self {
            Self::Tuple(len) => len,
            Self::List(len) => len.checked_add(1).context("ETF list too large")?,
            Self::Map(len) => len.checked_mul(2).context("ETF map too large")?,
            Self::Opaque { children, .. } => children,
            _ => 0,
        })
    }
}

fn atom_name(utf8: bool, bytes: &[u8]) -> Result<Cow<'_, str>> {
    let name = if utf8 || bytes.is_ascii() {
        Cow::Borrowed(std::str::from_utf8(bytes)?)
    } else {
        Cow::Owned(bytes.iter().copied().map(char::from).collect())
    };
    ensure!(name.chars().count() <= 255, "ETF atom too long");
    Ok(name)
}

struct Decoder<'a> {
    bytes: &'a [u8],
    budget: Budget,
}

impl<'a> Decoder<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self {
            bytes,
            budget: Budget::default(),
        }
    }

    fn slice(&mut self) -> Result<Term<'a>> {
        let bytes = self.bytes;
        let mut pending = 1usize;
        // Every pending node needs at least one byte. This walk uses constant stack space.
        while pending > 0 {
            ensure!(pending <= self.bytes.len(), "truncated ETF body");
            pending = (pending - 1)
                .checked_add(self.node()?.children()?)
                .context("ETF body too large")?;
        }
        Ok(Term(&bytes[..bytes.len() - self.bytes.len()]))
    }

    fn take(&mut self, len: usize) -> Result<&'a [u8]> {
        let (head, tail) = self.bytes.split_at_checked(len).context("truncated ETF")?;
        self.bytes = tail;
        Ok(head)
    }

    fn number<const N: usize>(&mut self) -> Result<[u8; N]> {
        self.take(N)?.try_into().context("truncated ETF number")
    }

    fn byte(&mut self) -> Result<u8> {
        Ok(self.number::<1>()?[0])
    }

    fn size(&mut self) -> Result<usize> {
        Ok(u32::from_be_bytes(self.number()?) as usize)
    }

    fn atom(&mut self) -> Result<(bool, &'a [u8])> {
        let tag = self.byte()?;
        self.atom_body(tag)
    }

    fn atom_body(&mut self, tag: u8) -> Result<(bool, &'a [u8])> {
        let len = match tag {
            100 | 118 => usize::from(u16::from_be_bytes(self.number()?)),
            115 | 119 => usize::from(self.byte()?),
            _ => bail!("expected an ETF atom"),
        };
        Ok((matches!(tag, 118 | 119), self.take(len)?))
    }

    fn node(&mut self) -> Result<Node<'a>> {
        let tag = self.byte()?;
        let opaque = |children| Node::Opaque { tag, children };
        Ok(match tag {
            70 => Node::Float(f64::from_be_bytes(self.number()?)),
            97 => Node::Integer(i32::from(self.byte()?)),
            98 => Node::Integer(i32::from_be_bytes(self.number()?)),
            100 | 115 | 118 | 119 => {
                let (utf8, bytes) = self.atom_body(tag)?;
                Node::Atom(utf8, bytes)
            }
            104 => Node::Tuple(usize::from(self.byte()?)),
            105 => Node::Tuple(self.size()?),
            106 => Node::Nil,
            107 => {
                let len = usize::from(u16::from_be_bytes(self.number()?));
                Node::String(self.take(len)?)
            }
            108 => Node::List(self.size()?),
            109 => {
                let len = self.size()?;
                Node::Binary(self.take(len)?)
            }
            110 | 111 => {
                let len = if tag == 110 {
                    usize::from(self.byte()?)
                } else {
                    self.size()?
                };
                let sign = self.byte()?;
                Node::Big(sign, self.take(len)?)
            }
            116 => Node::Map(self.size()?),
            77 => {
                let len = self.size()?;
                self.byte()?;
                self.take(len)?;
                opaque(0)
            }
            88 | 89 | 101 | 102 | 103 | 120 => {
                self.atom()?;
                self.take(match tag {
                    89 => 8,
                    101 | 102 => 5,
                    103 => 9,
                    _ => 12,
                })?;
                opaque(0)
            }
            90 | 114 => {
                let words = usize::from(u16::from_be_bytes(self.number()?));
                self.atom()?;
                self.take(words * 4 + if tag == 90 { 4 } else { 1 })?;
                opaque(0)
            }
            99 => {
                self.take(31)?;
                opaque(0)
            }
            112 => {
                // OTP follows the children because the encoded size field can overcount.
                self.take(25)?;
                opaque(
                    self.size()?
                        .checked_add(4)
                        .context("ETF function too large")?,
                )
            }
            113 => opaque(3),
            67 => {
                let fields = self.size()?;
                self.byte()?;
                opaque(
                    fields
                        .checked_mul(2)
                        .and_then(|n| n.checked_add(2))
                        .context("ETF record too large")?,
                )
            }
            tag => bail!("unsupported ETF tag {tag}"),
        })
    }

    fn terms(&mut self, depth: usize, len: usize) -> Result<Vec<Value>> {
        (0..len).map(|_| self.term(depth)).collect()
    }

    fn term(&mut self, depth: usize) -> Result<Value> {
        self.budget.charge(depth, 1)?;
        Ok(match self.node()? {
            Node::Float(number) => {
                ensure!(number.is_finite(), "invalid ETF float");
                Value::Float(number)
            }
            Node::Integer(number) => Value::Integer(number.into()),
            Node::Atom(utf8, bytes) => Value::Atom(atom_name(utf8, bytes)?.into_owned()),
            Node::Tuple(len) => Value::Tuple(self.terms(depth + 1, len)?),
            Node::Nil => Value::List(Vec::new()),
            Node::String(bytes) => {
                self.budget.charge(depth + 1, bytes.len())?;
                Value::List(
                    bytes
                        .iter()
                        .map(|&byte| Value::Integer(byte.into()))
                        .collect(),
                )
            }
            Node::List(len) => {
                let items = self.terms(depth + 1, len)?;
                ensure!(
                    matches!(self.node()?, Node::Nil),
                    "unsupported ETF list tail"
                );
                Value::List(items)
            }
            Node::Binary(bytes) => Value::Binary(bytes.to_vec()),
            Node::Big(sign, bytes) => {
                let sign = match sign {
                    0 => Sign::Plus,
                    1 => Sign::Minus,
                    _ => bail!("invalid ETF integer sign"),
                };
                Value::Integer(BigInt::from_bytes_le(sign, bytes))
            }
            Node::Map(len) => {
                let mut fields = BTreeMap::new();
                for _ in 0..len {
                    let key = self.term(depth + 1)?;
                    let value = self.term(depth + 1)?;
                    fields.insert(key, value);
                }
                Value::Map(fields)
            }
            Node::Opaque { tag, .. } => bail!("unsupported ETF value tag {tag}"),
        })
    }
}

pub(super) fn encode(value: &Value, frame: &mut Vec<u8>) -> Result<()> {
    frame.push(VERSION);
    Encoder {
        bytes: frame,
        budget: Budget::default(),
    }
    .term(0, value)
}

struct Encoder<'a> {
    bytes: &'a mut Vec<u8>,
    budget: Budget,
}

impl Encoder<'_> {
    fn append(&mut self, bytes: &[u8]) -> Result<()> {
        ensure!(
            self.bytes.len() + bytes.len() <= 4 + MAX_FRAME_BYTES,
            "request exceeds frame limit"
        );
        self.bytes.extend_from_slice(bytes);
        Ok(())
    }

    fn header(&mut self, tag: u8, len: usize) -> Result<()> {
        self.append(&[tag])?;
        self.append(&u32::try_from(len)?.to_be_bytes())
    }

    fn term(&mut self, depth: usize, value: &Value) -> Result<()> {
        self.budget.charge(depth, 1)?;
        match value {
            Value::Atom(atom) => {
                ensure!(atom.chars().count() <= 255, "ETF atom too long");
                let len = u16::try_from(atom.len())?.to_be_bytes();
                self.append(&[118, len[0], len[1]])?;
                self.append(atom.as_bytes())
            }
            Value::Binary(bytes) => {
                self.header(109, bytes.len())?;
                self.append(bytes)
            }
            Value::Integer(integer) => {
                if let Ok(byte) = u8::try_from(integer) {
                    return self.append(&[97, byte]);
                }
                if let Ok(small) = i32::try_from(integer) {
                    self.append(&[98])?;
                    return self.append(&small.to_be_bytes());
                }
                let (sign, digits) = integer.to_bytes_le();
                self.header(111, digits.len())?;
                self.append(&[u8::from(sign == Sign::Minus)])?;
                self.append(&digits)
            }
            Value::Float(number) => {
                ensure!(number.is_finite(), "invalid ETF float");
                self.append(&[70])?;
                self.append(&number.to_be_bytes())
            }
            Value::List(items) => {
                if !items.is_empty() {
                    self.header(108, items.len())?;
                    for item in items {
                        self.term(depth + 1, item)?;
                    }
                }
                self.append(&[106])
            }
            Value::Tuple(items) => {
                self.header(105, items.len())?;
                for item in items {
                    self.term(depth + 1, item)?;
                }
                Ok(())
            }
            Value::Map(entries) => {
                self.header(116, entries.len())?;
                for (key, value) in entries {
                    self.term(depth + 1, key)?;
                    self.term(depth + 1, value)?;
                }
                Ok(())
            }
        }
    }
}
