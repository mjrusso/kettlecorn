//! Outbound `wasi:http` requests go through this sender. It enforces the
//! allowlist for both direct and proxied requests.
//!
//! The connection, timeouts, and TLS roots follow Wasmtime's default sender
//! (Apache-2.0 WITH LLVM-exception).

use super::NetworkRules;
use base64::Engine as _;
use bytes::Bytes;
use core::future::poll_fn;
use core::pin::{Pin, pin};
use core::task::{Context, Poll, ready};
use http::header::{HOST, PROXY_AUTHORIZATION};
use http::uri::Scheme;
use http::{HeaderValue, Method, Request, Response, Uri};
use http_body_util::{BodyExt, Empty};
use hyper_util::rt::TokioIo;
use std::env;
use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::TcpStream;
use wasmtime_wasi_http::{Error, RequestOptions, WasiBody};

pub(crate) struct HttpHooks {
    pub(crate) rules: Option<NetworkRules>,
    pub(crate) proxies: Option<Proxies>,
    pub(crate) tls: Arc<rustls::ClientConfig>,
}

impl Default for HttpHooks {
    fn default() -> Self {
        Self {
            rules: None,
            proxies: None,
            tls: tls_client(rustls::RootCertStore {
                roots: webpki_roots::TLS_SERVER_ROOTS.into(),
            }),
        }
    }
}

// Select ring explicitly. rustls's default builder can set the embedding
// application's process-wide provider or panic if multiple providers are enabled.
fn tls_provider() -> Arc<rustls::crypto::CryptoProvider> {
    Arc::new(rustls::crypto::ring::default_provider())
}

fn tls_client(roots: rustls::RootCertStore) -> Arc<rustls::ClientConfig> {
    let config = rustls::ClientConfig::builder_with_provider(tls_provider())
        .with_safe_default_protocol_versions()
        .expect("ring supports the default protocol versions")
        .with_root_certificates(roots)
        .with_no_client_auth();
    Arc::new(config)
}

type IoFuture = Box<dyn Future<Output = Result<(), Error>> + Send>;

impl wasmtime_wasi_http::WasiHttpHooks for HttpHooks {
    fn send_request(
        &mut self,
        request: Request<WasiBody>,
        options: Option<RequestOptions>,
        fut: IoFuture,
    ) -> Box<dyn Future<Output = wasmtime_wasi_http::Result<(Response<WasiBody>, IoFuture)>> + Send>
    {
        _ = fut;
        if let Some(rules) = &self.rules
            && !super::network::allows_url(rules, request.uri())
        {
            return Box::new(async { Err(Error::HttpRequestDenied) });
        }
        let proxy = self
            .proxies
            .as_ref()
            .and_then(|proxies| proxies.for_uri(request.uri()))
            .cloned();
        let tls = self.tls.clone();
        let absolute = self.rules.is_some();
        Box::new(async move {
            let (response, io) = send(request, options, proxy, absolute, tls).await?;
            Ok((
                response.map(BodyExt::boxed_unsync),
                Box::new(io) as IoFuture,
            ))
        })
    }
}

/// The proxies from the launcher's environment.
pub(crate) struct Proxies {
    http: Option<Proxy>,
    https: Option<Proxy>,
    /// Lowercase host names, domains and addresses.
    direct: Vec<String>,
}

#[derive(Clone)]
struct Proxy {
    /// `host:port`.
    authority: String,
    /// `Proxy-Authorization` for credentials in the proxy URL.
    authorization: Option<HeaderValue>,
}

impl Proxies {
    pub(crate) fn from_env() -> anyhow::Result<Option<Self>> {
        Self::from_vars(|name| env::var(name).ok())
    }

    fn from_vars(var: impl Fn(&str) -> Option<String>) -> anyhow::Result<Option<Self>> {
        let get = |lower: &str, upper: &str| {
            [lower, upper].into_iter().find_map(|name| {
                var(name)
                    .filter(|value| !value.trim().is_empty())
                    .map(|value| (name.to_owned(), value))
            })
        };
        let proxy = |lower, upper| {
            get(lower, upper)
                .map(|(name, url)| Proxy::parse(&name, &url))
                .transpose()
        };
        let direct: Vec<String> = get("no_proxy", "NO_PROXY")
            .map(|(_, value)| value)
            .unwrap_or_default()
            .split(',')
            .map(|entry| {
                entry
                    .trim()
                    .trim_start_matches("*.")
                    .trim_start_matches('.')
                    .trim_end_matches('.')
            })
            .filter(|entry| !entry.is_empty())
            .map(str::to_ascii_lowercase)
            .collect();
        if direct.iter().any(|entry| entry == "*") {
            return Ok(None);
        }
        let http = proxy("http_proxy", "HTTP_PROXY")?;
        let https = proxy("https_proxy", "HTTPS_PROXY")?;
        if http.is_none() && https.is_none() {
            return Ok(None);
        }
        Ok(Some(Self {
            http,
            https,
            direct,
        }))
    }

    fn for_uri(&self, uri: &Uri) -> Option<&Proxy> {
        let host = uri
            .host()?
            .trim_start_matches('[')
            .trim_end_matches(']')
            .trim_end_matches('.')
            .to_ascii_lowercase();
        let loopback = host == "localhost"
            || host.ends_with(".localhost")
            || host
                .parse::<IpAddr>()
                .is_ok_and(|ip| ip.to_canonical().is_loopback());
        let direct = self.direct.iter().any(|entry| {
            host == *entry
                || host
                    .strip_suffix(entry.as_str())
                    .is_some_and(|rest| rest.ends_with('.'))
        });
        if loopback || direct {
            return None;
        }
        if uri.scheme() == Some(&Scheme::HTTPS) {
            self.https.as_ref()
        } else {
            self.http.as_ref()
        }
    }
}

impl Proxy {
    /// Parses `http://[user:password@]host[:port]` from the variable `name`; the
    /// scheme may be omitted. Errors name the variable, never its value, which
    /// can hold credentials.
    fn parse(name: &str, url: &str) -> anyhow::Result<Self> {
        let invalid = |reason: &str| anyhow::anyhow!("invalid HTTP proxy in {name}: {reason}");
        let rest = match url.split_once("://") {
            Some(("http", rest)) => rest,
            Some(_) => return Err(invalid("only http:// proxies are supported")),
            None => url,
        };
        let rest = rest.trim_end_matches('/');
        let (credentials, host) = match rest.rsplit_once('@') {
            Some((credentials, host)) => (Some(credentials), host),
            None => (None, rest),
        };
        let authority: http::uri::Authority =
            host.parse().map_err(|_| invalid("bad host or port"))?;
        let port_given = host
            .rsplit_once(']')
            .map_or(host, |(_, rest)| rest)
            .contains(':');
        if port_given && authority.port_u16().is_none() {
            return Err(invalid("bad port"));
        }
        let authorization = credentials
            .map(|credentials| {
                let credentials = percent_encoding::percent_decode_str(credentials)
                    .decode_utf8()
                    .map_err(|_| invalid("credentials aren't UTF-8"))?;
                let encoded = base64::engine::general_purpose::STANDARD.encode(&*credentials);
                HeaderValue::try_from(format!("Basic {encoded}"))
                    .map_err(|_| invalid("bad credentials"))
            })
            .transpose()?;
        Ok(Self {
            authority: format!(
                "{}:{}",
                authority.host(),
                authority.port_u16().unwrap_or(80)
            ),
            authorization,
        })
    }
}

trait Stream: AsyncRead + AsyncWrite + Send + Unpin + 'static {}
impl<T> Stream for T where T: AsyncRead + AsyncWrite + Send + Unpin + 'static {}

/// Sends `request` to its origin, or through `proxy`, verifying TLS with
/// `tls`. With `absolute`, a direct connection looks up the origin's host name
/// with `lookup_absolute`.
async fn send(
    mut request: Request<WasiBody>,
    options: Option<RequestOptions>,
    proxy: Option<Proxy>,
    absolute: bool,
    tls: Arc<rustls::ClientConfig>,
) -> Result<
    (
        Response<impl http_body::Body<Data = Bytes, Error = Error> + use<>>,
        impl Future<Output = Result<(), Error>> + Send + use<>,
    ),
    Error,
> {
    let uri = request.uri();
    let authority = uri.authority().ok_or(Error::HttpRequestUriInvalid)?;
    let use_tls = uri.scheme() == Some(&Scheme::HTTPS);
    let host = authority.host().to_owned();
    let port = authority
        .port_u16()
        .unwrap_or(if use_tls { 443 } else { 80 });
    let origin = format!("{host}:{port}");
    let timeout = |pick: fn(&RequestOptions) -> Option<Duration>| {
        options
            .as_ref()
            .and_then(pick)
            .unwrap_or(Duration::from_secs(600))
    };
    let connect_timeout = timeout(|o| o.connect_timeout);
    let first_byte_timeout = timeout(|o| o.first_byte_timeout);
    let between_bytes_timeout = timeout(|o| o.between_bytes_timeout).max(Duration::new(0, 1));

    let connect = async {
        let stream = match &proxy {
            Some(proxy) => TcpStream::connect(&proxy.authority).await,
            None if absolute && !host.starts_with('[') && host.parse::<IpAddr>().is_err() => {
                let ips = super::network::lookup_absolute(&host)
                    .await
                    .map_err(Error::Connect)?;
                let addresses: Vec<SocketAddr> = ips
                    .into_iter()
                    .map(|ip| SocketAddr::new(ip, port))
                    .collect();
                TcpStream::connect(&addresses[..]).await
            }
            None => TcpStream::connect(&origin).await,
        }
        .map_err(Error::Connect)?;
        let stream: Box<dyn Stream> = match &proxy {
            Some(proxy) if use_tls => Box::new(tunnel(stream, &origin, proxy).await?),
            _ => Box::new(stream),
        };
        if !use_tls {
            return Ok::<_, Error>(stream);
        }
        let name = host
            .trim_start_matches('[')
            .trim_end_matches(']')
            .parse::<IpAddr>()
            .map(rustls::pki_types::ServerName::from)
            .or_else(|_| rustls::pki_types::ServerName::try_from(host.clone()))
            .map_err(|_| Error::HttpRequestUriInvalid)?;
        let stream = tokio_rustls::TlsConnector::from(tls)
            .connect(name, stream)
            .await
            .map_err(Error::Tls)?;
        Ok(Box::new(stream) as Box<dyn Stream>)
    };
    let stream = tokio::time::timeout(connect_timeout, connect)
        .await
        .map_err(|_| Error::ConnectionTimeout)??;
    let (mut sender, conn) = tokio::time::timeout(
        connect_timeout,
        hyper::client::conn::http1::Builder::new().handshake(TokioIo::new(stream)),
    )
    .await
    .map_err(|_| Error::ConnectionTimeout)??;

    match &proxy {
        // A proxy forwarding plain HTTP gets the absolute URL, and the credentials.
        Some(proxy) if !use_tls => {
            if let Some(authorization) = &proxy.authorization {
                request
                    .headers_mut()
                    .insert(PROXY_AUTHORIZATION, authorization.clone());
            }
        }
        // The origin gets the path only.
        _ => {
            *request.uri_mut() = Uri::builder()
                .path_and_query(
                    request
                        .uri()
                        .path_and_query()
                        .map_or("/", |path| path.as_str()),
                )
                .build()
                .expect("comes from a valid request");
        }
    }

    let send = async move {
        let response = tokio::time::timeout(first_byte_timeout, sender.send_request(request))
            .await
            .map_err(|_| Error::ConnectionReadTimeout)??;
        let mut timeout = tokio::time::interval(between_bytes_timeout);
        timeout.reset();
        Ok(response.map(|incoming| ResponseBody { incoming, timeout }))
    };
    let mut send = pin!(send);
    let mut conn = Some(conn);
    let response = poll_fn(|cx| match send.as_mut().poll(cx) {
        Poll::Ready(result) => Poll::Ready(result),
        Poll::Pending => {
            let Some(fut) = conn.as_mut() else {
                return Poll::Pending;
            };
            let result = ready!(Pin::new(fut).poll(cx));
            conn = None;
            match result {
                Ok(()) => send.as_mut().poll(cx),
                Err(error) => Poll::Ready(Err(Error::from(error))),
            }
        }
    })
    .await?;
    Ok((response, async move {
        let Some(conn) = conn.take() else {
            return Ok(());
        };
        conn.await.map_err(|error| {
            if error.is_timeout() {
                Error::HttpResponseTimeout
            } else {
                error.into()
            }
        })
    }))
}

/// Opens a `CONNECT` tunnel to `origin` (`host:port`) through the proxy.
async fn tunnel(
    stream: TcpStream,
    origin: &str,
    proxy: &Proxy,
) -> Result<TokioIo<hyper::upgrade::Upgraded>, Error> {
    let (mut sender, conn) = hyper::client::conn::http1::handshake(TokioIo::new(stream)).await?;
    let mut connect = Request::builder()
        .method(Method::CONNECT)
        .uri(origin)
        .header(HOST, origin);
    if let Some(authorization) = &proxy.authorization {
        connect = connect.header(PROXY_AUTHORIZATION, authorization);
    }
    let connect = connect
        .body(Empty::<Bytes>::new())
        .map_err(|_| Error::HttpRequestUriInvalid)?;
    let exchange = async {
        let response = sender.send_request(connect).await?;
        if !response.status().is_success() {
            return Err(Error::Connect(std::io::Error::other(format!(
                "the proxy refused the tunnel to {origin}: {}",
                response.status()
            ))));
        }
        Ok(hyper::upgrade::on(response).await?)
    };
    // The connection finishes by handing its socket to the upgrade. Both run
    // in this future, so dropping it, on a timeout or shutdown, closes the socket.
    let driver = async { conn.with_upgrades().await.map_err(Error::from) };
    let (upgraded, ()) = tokio::try_join!(exchange, driver)?;
    Ok(TokioIo::new(upgraded))
}

/// A response body with Wasmtime's between-bytes timeout.
struct ResponseBody {
    incoming: hyper::body::Incoming,
    timeout: tokio::time::Interval,
}

impl http_body::Body for ResponseBody {
    type Data = Bytes;
    type Error = Error;

    fn poll_frame(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<http_body::Frame<Bytes>, Error>>> {
        match Pin::new(&mut self.incoming).poll_frame(cx) {
            Poll::Ready(None) => Poll::Ready(None),
            Poll::Ready(Some(Err(error))) => Poll::Ready(Some(Err(if error.is_timeout() {
                Error::HttpResponseTimeout
            } else {
                Error::from(error)
            }))),
            Poll::Ready(Some(Ok(frame))) => {
                self.timeout.reset();
                Poll::Ready(Some(Ok(frame)))
            }
            Poll::Pending => {
                ready!(self.timeout.poll_tick(cx));
                Poll::Ready(Some(Err(Error::ConnectionReadTimeout)))
            }
        }
    }

    fn is_end_stream(&self) -> bool {
        self.incoming.is_end_stream()
    }

    fn size_hint(&self) -> http_body::SizeHint {
        self.incoming.size_hint()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn proxies(vars: &[(&str, &str)]) -> anyhow::Result<Option<Proxies>> {
        let vars: HashMap<String, String> = vars
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        Proxies::from_vars(|name| vars.get(name).cloned())
    }

    fn route(proxies: &Proxies, url: &str) -> Option<String> {
        proxies
            .for_uri(&url.parse().unwrap())
            .map(|proxy| proxy.authority.clone())
    }

    #[test]
    fn proxies_come_from_the_environment_by_scheme() {
        assert!(proxies(&[]).unwrap().is_none());
        let p = proxies(&[
            ("HTTP_PROXY", "http://plain.example:3128"),
            ("https_proxy", "tls.example"),
            (
                "NO_PROXY",
                "internal.example, .corp.example,10.0.0.1,rooted.example.",
            ),
        ])
        .unwrap()
        .unwrap();
        assert_eq!(
            route(&p, "http://api.example/x").as_deref(),
            Some("plain.example:3128")
        );
        assert_eq!(
            route(&p, "https://api.example/x").as_deref(),
            Some("tls.example:80")
        );
        for direct in [
            "https://internal.example/",
            "https://internal.example./",
            "https://rooted.example/",
            "https://a.corp.example/",
            "https://corp.example/",
            "http://10.0.0.1/",
            "http://localhost:4000/",
            "http://127.0.0.1/",
            "http://[::1]/",
        ] {
            assert_eq!(route(&p, direct), None, "{direct}");
        }
        assert!(route(&p, "https://notcorp.example/").is_some());
    }

    /// Reads an HTTP head, through the blank line.
    async fn read_head(stream: &mut (impl AsyncRead + Unpin)) -> String {
        use tokio::io::AsyncReadExt;
        let mut head = Vec::new();
        while !head.ends_with(b"\r\n\r\n") {
            head.push(stream.read_u8().await.unwrap());
        }
        String::from_utf8(head).unwrap()
    }

    #[tokio::test]
    async fn https_reaches_the_origin_through_a_connect_tunnel() {
        use rustls::pki_types::{CertificateDer, PrivatePkcs8KeyDer};
        use tokio::io::AsyncWriteExt;
        use tokio::net::TcpListener;
        use wasmtime_wasi_http::WasiHttpHooks;

        // A CA, and a certificate it signed for origin.test, valid until 2126.
        let ca = CertificateDer::from(&include_bytes!("testdata/ca.der")[..]);
        let cert = CertificateDer::from(&include_bytes!("testdata/origin.der")[..]);
        let key = PrivatePkcs8KeyDer::from(&include_bytes!("testdata/origin.key.der")[..]);

        // The origin answers one request over TLS for origin.test.
        let server = rustls::ServerConfig::builder_with_provider(tls_provider())
            .with_safe_default_protocol_versions()
            .unwrap()
            .with_no_client_auth()
            .with_single_cert(vec![cert], key.clone_key().into())
            .unwrap();
        let acceptor = tokio_rustls::TlsAcceptor::from(Arc::new(server));
        let origin = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let origin_address = origin.local_addr().unwrap();
        let (request_head, origin_head) = tokio::sync::oneshot::channel();
        tokio::spawn(async move {
            let (stream, _) = origin.accept().await.unwrap();
            let mut stream = acceptor.accept(stream).await.unwrap();
            request_head.send(read_head(&mut stream).await).unwrap();
            let reply = "HTTP/1.1 200 OK\r\ncontent-length: 8\r\nconnection: close\r\n\r\ntunneled";
            stream.write_all(reply.as_bytes()).await.unwrap();
            stream.shutdown().await.unwrap();
        });

        // The proxy opens the tunnel to the origin, whatever name it's given.
        let proxy = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let proxy_address = proxy.local_addr().unwrap();
        let (connect_head, proxy_head) = tokio::sync::oneshot::channel();
        tokio::spawn(async move {
            let (mut client, _) = proxy.accept().await.unwrap();
            connect_head.send(read_head(&mut client).await).unwrap();
            let mut origin = TcpStream::connect(origin_address).await.unwrap();
            client
                .write_all(b"HTTP/1.1 200 Connection established\r\n\r\n")
                .await
                .unwrap();
            _ = tokio::io::copy_bidirectional(&mut client, &mut origin).await;
        });

        let mut roots = rustls::RootCertStore::empty();
        roots.add(ca).unwrap();
        let mut hooks = HttpHooks {
            proxies: proxies(&[("HTTPS_PROXY", &format!("http://{proxy_address}"))]).unwrap(),
            tls: tls_client(roots),
            ..HttpHooks::default()
        };
        let request = Request::get("https://origin.test/hello")
            .body(
                Empty::<Bytes>::new()
                    .map_err(|never| match never {})
                    .boxed_unsync(),
            )
            .unwrap();
        let sent = hooks.send_request(request, None, Box::new(async { Ok(()) }));
        let (response, io) = Box::into_pin(sent).await.unwrap();
        tokio::spawn(Box::into_pin(io));
        assert_eq!(response.status(), 200);
        let body = response.into_body().collect().await.unwrap().to_bytes();
        assert_eq!(body, "tunneled");
        assert!(
            proxy_head
                .await
                .unwrap()
                .starts_with("CONNECT origin.test:443 HTTP/1.1\r\n")
        );
        assert!(
            origin_head
                .await
                .unwrap()
                .starts_with("GET /hello HTTP/1.1\r\n")
        );
    }

    #[tokio::test]
    async fn a_dropped_tunnel_closes_its_connection() {
        use tokio::io::AsyncReadExt;
        // A proxy that accepts and never answers CONNECT.
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let client = TcpStream::connect(address).await.unwrap();
        let (mut server, _) = listener.accept().await.unwrap();
        let proxy = Proxy {
            authority: address.to_string(),
            authorization: None,
        };
        let timeout = Duration::from_millis(100);
        let tunnel = tunnel(client, "origin.test:443", &proxy);
        assert!(tokio::time::timeout(timeout, tunnel).await.is_err());
        let mut request = Vec::new();
        tokio::time::timeout(Duration::from_secs(5), server.read_to_end(&mut request))
            .await
            .expect("the connection stayed open")
            .unwrap();
        assert!(request.starts_with(b"CONNECT origin.test:443 "));
    }

    #[test]
    fn proxy_credentials_are_decoded_and_kept_out_of_errors() {
        let p = proxies(&[("HTTPS_PROXY", "http://us%40er:s3cret@proxy.example:8080/")])
            .unwrap()
            .unwrap();
        let proxy = p.https.unwrap();
        assert_eq!(proxy.authority, "proxy.example:8080");
        // "us@er:s3cret"
        assert_eq!(proxy.authorization.unwrap(), "Basic dXNAZXI6czNjcmV0");
        for bad in [
            "socks5://user:s3cret@proxy.example:1080",
            "https://user:s3cret@proxy.example",
            "http://user:s3cret@proxy.example:notaport",
        ] {
            let error = proxies(&[("HTTPS_PROXY", bad)])
                .err()
                .expect(bad)
                .to_string();
            assert!(error.contains("HTTPS_PROXY"), "{error}");
            assert!(!error.contains("s3cret"), "{error}");
        }
        // NO_PROXY=* sends everything direct, so the proxies aren't parsed.
        assert!(
            proxies(&[("HTTPS_PROXY", "socks5://proxy.example"), ("NO_PROXY", "*")])
                .unwrap()
                .is_none()
        );
    }
}
