//! Destination rules for the network and HTTP grants.
//!
//! With an allowlist, the sockets grant links its own `wasi:sockets/ip-name-lookup`
//! (`Lookup`): it resolves only names a rule allows (any name with `public`) and
//! records the addresses each allowed name returned, with that rule's ports, up
//! to `MAX_PERMISSIONS` address and port pairs per VM. Names are looked up in
//! absolute form, so the host's search domains don't apply. A lookup returns
//! only the addresses the guest may reach. The socket check admits a
//! connection, UDP datagram, or received datagram when an address rule matches
//! it, or when an allowed lookup returned its address for its port. Listening
//! and accepting are refused; local binds are allowed. HTTP requests are
//! checked by the URL's host and port (`allows_url`) before they are sent.

use std::collections::{BTreeSet, HashMap};
use std::fmt;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::str::FromStr;
use std::sync::{Arc, Mutex};
use wasmtime::component::{Accessor, HasData};
use wasmtime_wasi::p3::bindings::sockets::ip_name_lookup::{ErrorCode, Host, HostWithStore};
use wasmtime_wasi::p3::bindings::sockets::types::IpAddress;
use wasmtime_wasi::sockets::SocketAddrUse;

/// Which destinations a network or HTTP grant reaches.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum NetworkAccess {
    /// No access. The default.
    #[default]
    Denied,
    /// Any reachable destination, including loopback, private, and cloud metadata addresses.
    Any,
    /// Only destinations that one of the rules allows.
    Only(NetworkRules),
}

impl NetworkAccess {
    pub(crate) fn granted(&self) -> bool {
        !matches!(self, Self::Denied)
    }

    pub(crate) fn rules(&self) -> Option<&NetworkRules> {
        match self {
            Self::Only(rules) => Some(rules),
            _ => None,
        }
    }
}

/// A nonempty list of [`NetworkRule`]s. Clones share the list.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NetworkRules(Arc<[NetworkRule]>);

impl NetworkRules {
    /// The rules, or `None` when there are none.
    pub fn new(rules: impl IntoIterator<Item = NetworkRule>) -> Option<Self> {
        let rules: Arc<[NetworkRule]> = rules.into_iter().collect();
        (!rules.is_empty()).then_some(Self(rules))
    }
}

impl std::ops::Deref for NetworkRules {
    type Target = [NetworkRule];

    fn deref(&self) -> &[NetworkRule] {
        &self.0
    }
}

/// The HTTP grant's access, which has no `public` rule.
#[derive(Clone, Debug, Default)]
pub(crate) struct HttpAccess(NetworkAccess);

impl TryFrom<NetworkAccess> for HttpAccess {
    type Error = anyhow::Error;

    fn try_from(access: NetworkAccess) -> anyhow::Result<Self> {
        anyhow::ensure!(
            !access
                .rules()
                .is_some_and(|rules| rules.iter().any(|rule| rule.target == Target::Public)),
            "the HTTP grant doesn't support `public` rules yet; list host names or addresses"
        );
        Ok(Self(access))
    }
}

impl std::ops::Deref for HttpAccess {
    type Target = NetworkAccess;

    fn deref(&self) -> &NetworkAccess {
        &self.0
    }
}

/// One destination a grant allows, parsed from a string:
///
/// * a host name, `api.example.com`, or every subdomain of one, `*.example.com`;
/// * an IP address or CIDR range, `10.1.2.3`, `10.0.0.0/8`, `[fd00::1]`, `[fd00::/8]`;
/// * `public`: any public address: IPv4 outside the special-purpose ranges, or
///   IPv6 global unicast outside them. Not available for HTTP.
///
/// Rules are case insensitive. IPv4-mapped IPv6 rules mean the IPv4 address.
///
/// Add `:port` to allow one port only, for example `api.example.com:443`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NetworkRule {
    target: Target,
    port: Option<u16>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum Target {
    Name(String),
    /// `*.suffix`: names that end with `.suffix`.
    Subdomains(String),
    Range(IpAddr, u8),
    Public,
}

impl NetworkRule {
    fn allows_port(&self, port: u16) -> bool {
        self.port.is_none_or(|allowed| allowed == port)
    }

    fn allows_name(&self, name: &str) -> bool {
        match &self.target {
            Target::Name(allowed) => allowed == name,
            Target::Subdomains(suffix) => name
                .strip_suffix(suffix.as_str())
                .is_some_and(|rest| rest.len() > 1 && rest.ends_with('.')),
            Target::Range(..) | Target::Public => false,
        }
    }

    fn allows_ip(&self, ip: IpAddr) -> bool {
        match self.target {
            Target::Range(network, prefix) => in_range(ip, network, prefix),
            Target::Public => is_public(ip),
            Target::Name(_) | Target::Subdomains(_) => false,
        }
    }
}

impl FromStr for NetworkRule {
    type Err = String;

    fn from_str(rule: &str) -> Result<Self, String> {
        let invalid = |reason: &str| format!("invalid network rule {rule:?}: {reason}");
        let (host, port) = if let Some(rest) = rule.strip_prefix('[') {
            let (host, rest) = rest.split_once(']').ok_or_else(|| invalid("missing ]"))?;
            match rest {
                "" => (host, None),
                _ => (
                    host,
                    Some(
                        rest.strip_prefix(':')
                            .ok_or_else(|| invalid("expected :port after ]"))?,
                    ),
                ),
            }
        } else {
            match rule.split_once(':') {
                Some((_, rest)) if rest.contains(':') => {
                    return Err(invalid("write IPv6 addresses in brackets, [fd00::1]"));
                }
                Some((host, port)) => (host, Some(port)),
                None => (rule, None),
            }
        };
        let port = port
            .map(|port| {
                port.parse::<u16>()
                    .ok()
                    .filter(|port| *port != 0)
                    .ok_or_else(|| invalid("the port must be 1-65535"))
            })
            .transpose()?;
        let bracketed = rule.starts_with('[');
        let target = if host.eq_ignore_ascii_case("public") && !bracketed {
            Target::Public
        } else if let Some((address, prefix)) = host.split_once('/') {
            let address: IpAddr = address.parse().map_err(|_| invalid("bad address"))?;
            let prefix: u8 = prefix.parse().map_err(|_| invalid("bad prefix length"))?;
            if prefix > max_prefix(address) {
                return Err(invalid("prefix length too long"));
            }
            Target::Range(address, prefix)
        } else if let Ok(address) = host.parse::<IpAddr>() {
            Target::Range(address, max_prefix(address))
        } else if bracketed {
            return Err(invalid("brackets hold an IPv6 address"));
        } else if let Some(suffix) = host.strip_prefix("*.") {
            Target::Subdomains(name(suffix).ok_or_else(|| invalid("bad host name"))?)
        } else {
            Target::Name(name(host).ok_or_else(|| invalid("bad host name"))?)
        };
        if bracketed && !matches!(target, Target::Range(IpAddr::V6(_), _)) {
            return Err(invalid("brackets hold an IPv6 address"));
        }
        // Destinations are matched in their IPv4 form, so rules written with an
        // IPv4-mapped address are too. Other IPv6 ranges stay IPv6.
        let target = match target {
            Target::Range(IpAddr::V6(address), prefix) => match address.to_ipv4_mapped() {
                Some(v4) if prefix >= 96 => Target::Range(IpAddr::V4(v4), prefix - 96),
                Some(_) => {
                    return Err(invalid(
                        "an IPv4-mapped range needs a prefix of at least 96; write the IPv4 range",
                    ));
                }
                None => Target::Range(IpAddr::V6(address), prefix),
            },
            target => target,
        };
        Ok(Self { target, port })
    }
}

impl fmt::Display for NetworkRule {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.target {
            Target::Name(name) => write!(f, "{name}")?,
            Target::Subdomains(suffix) => write!(f, "*.{suffix}")?,
            Target::Public => write!(f, "public")?,
            Target::Range(address, prefix) => {
                let full = *prefix == max_prefix(*address);
                match (address, full) {
                    (IpAddr::V4(address), true) => write!(f, "{address}")?,
                    (IpAddr::V4(address), false) => write!(f, "{address}/{prefix}")?,
                    (IpAddr::V6(address), true) => write!(f, "[{address}]")?,
                    (IpAddr::V6(address), false) => write!(f, "[{address}/{prefix}]")?,
                }
            }
        }
        match self.port {
            Some(port) => write!(f, ":{port}"),
            None => Ok(()),
        }
    }
}

/// A lowercase ASCII host name with valid labels.
fn name(host: &str) -> Option<String> {
    let host = host.to_ascii_lowercase();
    let valid = |label: &str| {
        (1..=63).contains(&label.len())
            && label
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
            && !label.starts_with('-')
            && !label.ends_with('-')
    };
    (host.len() <= 253 && host.split('.').all(valid)).then_some(host)
}

fn max_prefix(address: IpAddr) -> u8 {
    if address.is_ipv4() { 32 } else { 128 }
}

fn in_range(ip: IpAddr, network: IpAddr, prefix: u8) -> bool {
    match (ip, network) {
        (IpAddr::V4(ip), IpAddr::V4(network)) => {
            let mask = u32::MAX.checked_shl(32 - u32::from(prefix)).unwrap_or(0);
            u32::from(ip) & mask == u32::from(network) & mask
        }
        (IpAddr::V6(ip), IpAddr::V6(network)) => {
            let mask = u128::MAX.checked_shl(128 - u32::from(prefix)).unwrap_or(0);
            u128::from(ip) & mask == u128::from(network) & mask
        }
        _ => false,
    }
}

// Classify by prefix. Unallocated space in 2000::/3 can match, and actual
// reachability depends on the host's routing table.
fn is_public(ip: IpAddr) -> bool {
    const V4: &[(Ipv4Addr, u8)] = &[
        (Ipv4Addr::new(0, 0, 0, 0), 8),
        (Ipv4Addr::new(10, 0, 0, 0), 8),
        (Ipv4Addr::new(100, 64, 0, 0), 10),
        (Ipv4Addr::new(127, 0, 0, 0), 8),
        (Ipv4Addr::new(169, 254, 0, 0), 16),
        (Ipv4Addr::new(172, 16, 0, 0), 12),
        (Ipv4Addr::new(192, 0, 0, 0), 24),
        (Ipv4Addr::new(192, 0, 2, 0), 24),
        (Ipv4Addr::new(192, 88, 99, 0), 24),
        (Ipv4Addr::new(192, 168, 0, 0), 16),
        (Ipv4Addr::new(198, 18, 0, 0), 15),
        (Ipv4Addr::new(198, 51, 100, 0), 24),
        (Ipv4Addr::new(203, 0, 113, 0), 24),
        (Ipv4Addr::new(224, 0, 0, 0), 4),
        (Ipv4Addr::new(240, 0, 0, 0), 4),
    ];
    // Special-purpose ranges inside global unicast (2000::/3): IETF protocol
    // assignments, documentation, and 6to4.
    const V6: &[(Ipv6Addr, u8)] = &[
        (Ipv6Addr::new(0x2001, 0, 0, 0, 0, 0, 0, 0), 23),
        (Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 0), 32),
        (Ipv6Addr::new(0x2002, 0, 0, 0, 0, 0, 0, 0), 16),
        (Ipv6Addr::new(0x3fff, 0, 0, 0, 0, 0, 0, 0), 20),
    ];
    match ip.to_canonical() {
        IpAddr::V4(ip) => !V4
            .iter()
            .any(|(network, prefix)| in_range(ip.into(), (*network).into(), *prefix)),
        IpAddr::V6(ip) => {
            let nat64 = Ipv6Addr::new(0x64, 0xff9b, 0, 0, 0, 0, 0, 0);
            if in_range(ip.into(), nat64.into(), 96) {
                let [.., a, b, c, d] = ip.octets();
                return is_public(Ipv4Addr::new(a, b, c, d).into());
            }
            let global = Ipv6Addr::new(0x2000, 0, 0, 0, 0, 0, 0, 0);
            in_range(ip.into(), global.into(), 3)
                && !V6
                    .iter()
                    .any(|(network, prefix)| in_range(ip.into(), (*network).into(), *prefix))
        }
    }
}

/// The most address and port pairs a VM's allowed lookups record; an address
/// reachable on every port counts once. A pair that would exceed it isn't
/// recorded.
const MAX_PERMISSIONS: usize = 4096;

#[derive(Clone, Debug, PartialEq)]
enum Ports {
    Some(BTreeSet<u16>),
    All,
}

impl Ports {
    fn size(&self) -> usize {
        match self {
            Self::All => 1,
            Self::Some(ports) => ports.len(),
        }
    }

    fn allows(&self, port: u16) -> bool {
        match self {
            Self::All => true,
            Self::Some(ports) => ports.contains(&port),
        }
    }
}

/// The addresses allowed names resolved to, and how many pairs they hold.
#[derive(Default)]
struct Resolved {
    ports: HashMap<IpAddr, Ports>,
    size: usize,
}

/// The sockets grant's rules, and the addresses that allowed names resolved to.
pub(crate) struct SocketPolicy {
    rules: NetworkRules,
    resolved: Mutex<Resolved>,
}

impl SocketPolicy {
    pub(crate) fn new(rules: NetworkRules) -> Arc<Self> {
        Arc::new(Self {
            rules,
            resolved: Mutex::default(),
        })
    }

    pub(crate) fn allows(&self, addr: SocketAddr, use_: SocketAddrUse) -> bool {
        match use_ {
            SocketAddrUse::TcpBind | SocketAddrUse::UdpBind => true,
            SocketAddrUse::TcpListen | SocketAddrUse::TcpAccept => false,
            SocketAddrUse::TcpConnect | SocketAddrUse::UdpSend | SocketAddrUse::UdpReceive => {
                self.reaches(addr)
            }
        }
    }

    fn reaches(&self, addr: SocketAddr) -> bool {
        let (ip, port) = (addr.ip().to_canonical(), addr.port());
        self.rules
            .iter()
            .any(|rule| rule.allows_port(port) && rule.allows_ip(ip))
            || self
                .resolved
                .lock()
                .unwrap()
                .ports
                .get(&ip)
                .is_some_and(|ports| ports.allows(port))
    }

    async fn resolve(&self, name: String) -> Result<Vec<IpAddr>, ErrorCode> {
        let literal = name.trim_start_matches('[').trim_end_matches(']');
        if let Ok(ip) = literal.parse::<IpAddr>() {
            return Ok(vec![ip]);
        }
        let name = comparison_name(&name);
        let ports: Vec<Option<u16>> = self
            .rules
            .iter()
            .filter(|rule| rule.allows_name(&name))
            .map(|rule| rule.port)
            .collect();
        let public = self.rules.iter().any(|rule| rule.target == Target::Public);
        if ports.is_empty() && !public {
            return Err(ErrorCode::AccessDenied);
        }
        let ips = lookup_absolute(&name)
            .await
            .map_err(|_| ErrorCode::NameUnresolvable)?;
        if ips.is_empty() {
            return Err(ErrorCode::NameUnresolvable);
        }
        match self.answers(ips, &ports) {
            ips if ips.is_empty() => Err(ErrorCode::AccessDenied),
            ips => Ok(ips),
        }
    }

    /// Records `ips` as reachable on `ports`, the allowed name's ports, and
    /// returns those the guest can reach: those recorded for one of `ports`,
    /// and those an address rule allows.
    fn answers(&self, ips: Vec<IpAddr>, ports: &[Option<u16>]) -> Vec<IpAddr> {
        ips.into_iter()
            .filter(|ip| {
                self.record(*ip, ports) || self.rules.iter().any(|rule| rule.allows_ip(*ip))
            })
            .collect()
    }

    /// Records `ip` as reachable on each of `ports` that no address rule
    /// already allows, while that stays within `MAX_PERMISSIONS`. Returns
    /// whether `ip` is then recorded for one of `ports`.
    fn record(&self, ip: IpAddr, ports: &[Option<u16>]) -> bool {
        let unlisted: Vec<Option<u16>> = ports
            .iter()
            .copied()
            .filter(|port| {
                !self.rules.iter().any(|rule| {
                    rule.allows_ip(ip) && port.map_or(rule.port.is_none(), |p| rule.allows_port(p))
                })
            })
            .collect();
        let mut resolved = self.resolved.lock().unwrap();
        let Resolved {
            ports: recorded,
            size,
        } = &mut *resolved;
        for port in unlisted {
            match (recorded.get_mut(&ip), port) {
                (Some(Ports::All), _) => {}
                (Some(Ports::Some(set)), Some(port)) => {
                    if !set.contains(&port) && *size < MAX_PERMISSIONS {
                        set.insert(port);
                        *size += 1;
                    }
                }
                // All ports count once, never more than the ports they replace.
                (Some(entry), None) => {
                    *size = *size - entry.size() + 1;
                    *entry = Ports::All;
                }
                (None, port) => {
                    if *size < MAX_PERMISSIONS {
                        let entry =
                            port.map_or(Ports::All, |port| Ports::Some(BTreeSet::from([port])));
                        recorded.insert(ip, entry);
                        *size += 1;
                    }
                }
            }
        }
        recorded.get(&ip).is_some_and(|entry| {
            ports
                .iter()
                .any(|port| port.is_none_or(|port| entry.allows(port)))
        })
    }
}

/// A host name as rules compare it: lowercase, without a trailing root dot.
fn comparison_name(name: &str) -> String {
    name.strip_suffix('.').unwrap_or(name).to_ascii_lowercase()
}

/// Looks up `name` as an absolute name, so the host's search domains can't
/// turn an allowed name into another one: from `/etc/hosts`, then the
/// resolver. musl, which the static Linux launcher uses, doesn't match a name
/// with a trailing dot against `/etc/hosts`.
pub(crate) async fn lookup_absolute(name: &str) -> std::io::Result<Vec<IpAddr>> {
    let name = comparison_name(name);
    let listed = {
        let name = name.clone();
        tokio::task::spawn_blocking(move || {
            hosts_file(
                &std::fs::read_to_string("/etc/hosts").unwrap_or_default(),
                &name,
            )
        })
        .await?
    };
    if !listed.is_empty() {
        return Ok(listed);
    }
    Ok(tokio::net::lookup_host((format!("{name}."), 0))
        .await?
        .map(|addr| addr.ip().to_canonical())
        .collect())
}

/// The addresses a hosts file lists for `name`, a comparison name.
fn hosts_file(hosts: &str, name: &str) -> Vec<IpAddr> {
    hosts
        .lines()
        .filter_map(|line| {
            let mut fields = line.split('#').next()?.split_whitespace();
            let ip: IpAddr = fields.next()?.parse().ok()?;
            fields
                .any(|alias| comparison_name(alias) == name)
                .then_some(ip.to_canonical())
        })
        .collect()
}

/// `wasi:sockets/ip-name-lookup` for a VM with a sockets allowlist.
pub(crate) struct Lookup;

pub(crate) struct LookupView<'a>(pub(crate) Option<&'a Arc<SocketPolicy>>);

impl HasData for Lookup {
    type Data<'a> = LookupView<'a>;
}

impl Host for LookupView<'_> {}

impl<U> HostWithStore<U> for Lookup {
    async fn resolve_addresses(
        store: &Accessor<U, Self>,
        name: String,
    ) -> wasmtime::Result<Result<Vec<IpAddress>, ErrorCode>> {
        let Some(policy) = store.with(|mut view| view.get().0.cloned()) else {
            return Ok(Err(ErrorCode::AccessDenied));
        };
        Ok(policy
            .resolve(name)
            .await
            .map(|ips| ips.into_iter().map(IpAddress::from).collect()))
    }
}

/// Whether `rules` allow an HTTP request to `uri`, by its host and port.
#[cfg(feature = "http")]
pub(crate) fn allows_url(rules: &[NetworkRule], uri: &http::Uri) -> bool {
    let Some(host) = uri.host() else {
        return false;
    };
    let port = uri
        .port_u16()
        .unwrap_or(if uri.scheme_str() == Some("http") {
            80
        } else {
            443
        });
    let literal = host.trim_start_matches('[').trim_end_matches(']');
    let mut rules = rules.iter().filter(|rule| rule.allows_port(port));
    match literal.parse::<IpAddr>() {
        Ok(ip) => rules.any(|rule| rule.allows_ip(ip.to_canonical())),
        Err(_) => {
            let name = comparison_name(host);
            rules.any(|rule| rule.allows_name(&name))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rule(rule: &str) -> NetworkRule {
        rule.parse().unwrap()
    }

    fn addr(addr: &str) -> SocketAddr {
        addr.parse().unwrap()
    }

    #[test]
    fn rules_parse_and_print_in_one_form() {
        for text in [
            "api.example.com",
            "api.example.com:443",
            "*.example.com",
            "10.0.0.0/8",
            "10.1.2.3:5432",
            "[fd00::/8]:443",
            "[::1]",
            "public",
            "public:443",
        ] {
            assert_eq!(rule(text).to_string(), text);
        }
        assert_eq!(rule("API.Example.COM").to_string(), "api.example.com");
        // Keywords are recognized in any case.
        assert_eq!(rule("PUBLIC"), rule("public"));
        // IPv4-mapped rules take their IPv4 form, which destinations are matched in.
        assert_eq!(rule("[::ffff:10.0.0.1]").to_string(), "10.0.0.1");
        assert_eq!(
            rule("[::ffff:10.0.0.0/104]:443").to_string(),
            "10.0.0.0/8:443"
        );
        assert!(rule("[::ffff:10.0.0.1]").allows_ip("10.0.0.1".parse().unwrap()));
        // Other IPv6 ranges, even ones containing the mapped block, stay IPv6.
        assert_eq!(rule("[::/0]").to_string(), "[::/0]");
        assert!(rule("[::/0]").allows_ip("2606:4700::1".parse().unwrap()));
        for bad in [
            "[::ffff:0:0/95]",
            "",
            "fd00::1",
            "[api.example.com]",
            "[10.0.0.1]",
            "10.0.0.0/33",
            "api.example.com:0",
            "api.example.com:70000",
            "-bad.example.com",
            "bad_name.example.com",
            "[::1]443",
        ] {
            assert!(bad.parse::<NetworkRule>().is_err(), "{bad}");
        }
    }

    #[test]
    fn names_match_exactly_or_as_subdomains() {
        assert!(rule("api.example.com").allows_name("api.example.com"));
        assert!(!rule("api.example.com").allows_name("x.api.example.com"));
        assert!(rule("*.example.com").allows_name("api.example.com"));
        assert!(rule("*.example.com").allows_name("a.b.example.com"));
        assert!(!rule("*.example.com").allows_name("example.com"));
        assert!(!rule("*.example.com").allows_name("badexample.com"));
    }

    #[test]
    fn public_excludes_special_purpose_addresses() {
        for private in [
            "127.0.0.1",
            "10.1.2.3",
            "172.16.0.1",
            "192.168.1.1",
            "169.254.169.254",
            "100.64.0.1",
            "0.0.0.0",
            "::1",
            "fd00::1",
            "fe80::1",
            "::ffff:10.0.0.1",
            "64:ff9b::a00:1",
            // IPv6 outside global unicast, or special-purpose within it.
            "64:ff9b:1::1",
            "4000::1",
            "100::1",
            "2001:db8::1",
            "2001::1",
            "2002:101:101::1",
        ] {
            assert!(!is_public(private.parse().unwrap()), "{private}");
        }
        for public in [
            "1.1.1.1",
            "2606:4700:4700::1111",
            "2001:4860:4860::8888",
            "64:ff9b::101:101",
        ] {
            assert!(is_public(public.parse().unwrap()), "{public}");
        }
    }

    fn rules(list: &[&str]) -> NetworkRules {
        NetworkRules::new(list.iter().map(|r| rule(r))).unwrap()
    }

    fn ip(n: u32) -> IpAddr {
        IpAddr::from(Ipv4Addr::from(0x0a00_0000 + n))
    }

    #[test]
    fn sockets_reach_listed_addresses_and_ports_and_never_listen() {
        let policy = SocketPolicy::new(rules(&["10.0.0.0/8:443", "public"]));
        let connect = |a| policy.allows(addr(a), SocketAddrUse::TcpConnect);
        assert!(connect("10.1.2.3:443"));
        assert!(!connect("10.1.2.3:80"));
        assert!(connect("1.1.1.1:80"));
        assert!(!connect("192.168.1.1:443"));
        assert!(!connect("[::ffff:192.168.1.1]:443"));
        assert!(policy.allows(addr("0.0.0.0:0"), SocketAddrUse::TcpBind));
        assert!(!policy.allows(addr("0.0.0.0:8080"), SocketAddrUse::TcpListen));
        assert!(!policy.allows(addr("1.1.1.1:5000"), SocketAddrUse::TcpAccept));
    }

    #[tokio::test]
    async fn lookups_are_limited_to_allowed_names() {
        let policy = SocketPolicy::new(rules(&["allowed.invalid:443", "localhost:8080"]));
        assert!(matches!(
            policy.resolve("other.example.com".into()).await,
            Err(ErrorCode::AccessDenied)
        ));
        // Literal addresses resolve to themselves; the connection is checked.
        assert_eq!(
            policy.resolve("10.0.0.1".into()).await.unwrap(),
            vec!["10.0.0.1".parse::<IpAddr>().unwrap()]
        );
        assert!(!policy.allows(addr("10.0.0.1:443"), SocketAddrUse::TcpConnect));
        // The absolute form of a name still resolves locally.
        for name in ["localhost", "LOCALHOST."] {
            let ips = policy.resolve(name.into()).await.unwrap();
            assert!(ips.iter().all(IpAddr::is_loopback), "{ips:?}");
            let reached = SocketAddr::new(ips[0], 8080);
            assert!(policy.allows(reached, SocketAddrUse::TcpConnect));
        }
        // An allowed name's addresses are reachable on the rule's port only.
        assert_eq!(policy.answers(vec![ip(2)], &[Some(443)]), vec![ip(2)]);
        assert!(policy.allows(addr("10.0.0.2:443"), SocketAddrUse::TcpConnect));
        assert!(!policy.allows(addr("10.0.0.2:80"), SocketAddrUse::TcpConnect));
    }

    #[test]
    fn hosts_file_entries_match_comparison_names() {
        let hosts = "127.0.0.1 localhost\n::1 localhost ip6-localhost\n\
                     # 10.0.0.9 db.internal\n10.0.0.5\tDB.Internal. db # comment\n\
                     fe80::1%eth0 db\n";
        let ips = |name| hosts_file(hosts, &comparison_name(name));
        assert_eq!(ips("db.internal."), vec![ip(5)]);
        assert_eq!(ips("db"), vec![ip(5)]);
        assert_eq!(ips("localhost").len(), 2);
        assert!(ips("comment").is_empty());
        assert!(ips("db.example").is_empty());
    }

    #[test]
    fn recorded_permissions_are_unique_and_bounded() {
        let policy = SocketPolicy::new(rules(&["allowed.invalid", "10.0.0.0/8:22"]));
        let entry = |n| policy.resolved.lock().unwrap().ports.get(&ip(n)).cloned();
        let size = || policy.resolved.lock().unwrap().size;
        // Repeated lookups keep one entry per address; any port subsumes the rest.
        for _ in 0..3 {
            policy.record(ip(0), &[Some(443), Some(80)]);
        }
        assert_eq!(entry(0), Some(Ports::Some(BTreeSet::from([80, 443]))));
        assert_eq!(size(), 2);
        policy.record(ip(0), &[None]);
        policy.record(ip(0), &[Some(443)]);
        assert_eq!(entry(0), Some(Ports::All));
        assert_eq!(size(), 1);
        // A port an address rule allows costs nothing.
        policy.record(ip(1), &[Some(22)]);
        assert_eq!(entry(1), None);
        // The cap counts address and port pairs; ports that fit are recorded.
        for n in 1..MAX_PERMISSIONS as u32 {
            policy.record(ip(n), &[Some(443)]);
        }
        assert_eq!(size(), MAX_PERMISSIONS);
        policy.record(ip(1), &[Some(443), Some(8443)]);
        assert_eq!(entry(1), Some(Ports::Some(BTreeSet::from([443]))));
        policy.record(ip(1), &[None]);
        assert_eq!(entry(1), Some(Ports::All));
        assert_eq!(size(), MAX_PERMISSIONS);
    }

    #[test]
    fn answers_past_the_cap_keep_addresses_still_reachable() {
        let policy = SocketPolicy::new(rules(&["allowed.invalid", "10.0.0.0/8:22", "public"]));
        let private = |n: u32| IpAddr::from(Ipv4Addr::from(0xac10_0000 + n));
        for n in 0..MAX_PERMISSIONS as u32 {
            policy.record(private(n), &[Some(443)]);
        }
        let public = "1.1.1.1".parse().unwrap();
        // Recorded for 443, 8443 doesn't fit; an address rule allows ip(1).
        let answers = policy.answers(
            vec![private(0), ip(1), public, private(5000)],
            &[Some(443), Some(8443)],
        );
        assert_eq!(answers, vec![private(0), ip(1), public]);
        // A name the rules don't list gets only the addresses its rules allow.
        assert_eq!(
            policy.answers(vec![private(5000), public], &[]),
            vec![public]
        );
    }

    #[test]
    fn http_access_rejects_public_rules() {
        assert!(NetworkRules::new([]).is_none());
        assert!(HttpAccess::try_from(NetworkAccess::Only(rules(&["public"]))).is_err());
        assert!(HttpAccess::try_from(NetworkAccess::Only(rules(&["10.0.0.0/8"]))).is_ok());
    }
}
