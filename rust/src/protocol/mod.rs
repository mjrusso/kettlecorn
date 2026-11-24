mod etf;

use anyhow::{Context, Result, bail, ensure};
pub use etf::Value;

pub(crate) const VERSION: u32 = 2;
pub(crate) const EMBEDDED_API: u32 = 1;
pub(crate) const MAX_FRAME_BYTES: usize = 8 * 1024 * 1024;

pub(crate) fn evaluation_value_limits() -> Value {
    // The event map, proxy reply, evaluation reply, and field map add four levels.
    Value::Tuple(vec![
        Value::Integer((etf::MAX_TERMS - 32).into()),
        Value::Integer((etf::MAX_DEPTH - 4).into()),
        Value::Integer((MAX_FRAME_BYTES - 1024).into()),
    ])
}

pub(crate) enum Event<'a> {
    Ready(Option<u32>),
    BootFailed,
    Undecodable(anyhow::Error),
    Output {
        stderr: bool,
        bytes: &'a [u8],
    },
    GuestMessage(Value),
    SendResult {
        id: u32,
        status: u8,
    },
    Reply {
        id: u32,
        result: Result<Value>,
    },
    HostCall {
        name: String,
        args: Value,
        token: Vec<u8>,
    },
    RejectedHostCall(Vec<u8>),
}

pub(crate) fn event(frame: &[u8]) -> Result<Option<Event<'_>>> {
    match frame {
        [3, payload @ ..] => {
            Ok(message(payload).unwrap_or_else(|error| Some(Event::Undecodable(error))))
        }
        [fd @ (1 | 2), body @ ..] => Ok(Some(Event::Output {
            stderr: *fd == 2,
            bytes: body,
        })),
        [4, reason @ ..] => bail!("guest fatal error: {}", String::from_utf8_lossy(reason)),
        [5, a, b, c, d, status] => Ok(Some(Event::SendResult {
            id: u32::from_be_bytes([*a, *b, *c, *d]),
            status: *status,
        })),
        [] => bail!("empty guest frame"),
        _ => Ok(None),
    }
}

fn message(payload: &[u8]) -> Result<Option<Event<'static>>> {
    let [
        kind,
        event,
        id,
        result,
        name,
        args,
        token,
        data,
        embedded_api,
    ] = etf::envelope(
        payload,
        [
            b"type",
            b"event",
            b"id",
            b"result",
            b"name",
            b"args",
            b"reply_to",
            b"data",
            b"embedded_api",
        ],
    )?;
    let kind = kind.context("missing envelope type")?.atom()?;
    Ok(match kind.as_ref() {
        "kettlecorn" => match event.context("missing event type")?.atom()?.as_ref() {
            "boot_ready" => Some(Event::Ready(
                embedded_api.and_then(|api| api.unsigned().ok()),
            )),
            "boot_failed" => Some(Event::BootFailed),
            "proxy_reply" => Some(Event::Reply {
                id: id.context("missing proxy reply ID")?.unsigned()?,
                result: result
                    .context("missing proxy reply result")
                    .and_then(etf::Term::value),
            }),
            _ => None,
        },
        "host_call" => {
            let token = token.context("missing host call reply token")?.binary()?;
            ensure!(token.len() <= 256, "host call reply token too long");
            let token = token.to_vec();
            let request = (|| {
                let name = name.context("missing host function name")?.binary()?;
                let name = std::str::from_utf8(name)?;
                let args = args.context("missing host call arguments")?.value()?;
                ensure!(
                    matches!(args, Value::Map(_)),
                    "expected a host call argument map"
                );
                Ok::<_, anyhow::Error>((name, args))
            })();
            Some(match request {
                Ok((name, args)) => Event::HostCall {
                    name: name.into(),
                    args,
                    token,
                },
                Err(_) => Event::RejectedHostCall(token),
            })
        }
        "vm_message" => Some(Event::GuestMessage(
            data.context("missing guest message data")?.value()?,
        )),
        _ => None,
    })
}

impl Value {
    pub fn as_atom(&self) -> Option<&str> {
        match self {
            Self::Atom(name) => Some(name),
            _ => None,
        }
    }

    pub fn into_string(self) -> Option<String> {
        match self {
            Self::Binary(bytes) => String::from_utf8(bytes).ok(),
            _ => None,
        }
    }

    pub(crate) fn into_pair(self) -> Result<(Self, Self)> {
        if let Self::Tuple(items) = self
            && let Ok([first, second]) = <[Self; 2]>::try_from(items)
        {
            return Ok((first, second));
        }
        bail!("expected a two-element guest tuple")
    }
}

pub(crate) fn call(id: u32, target: &str, request: Value, proxy_timeout: u32) -> Result<Vec<u8>> {
    send(
        id,
        2,
        b"kettlecorn_proxy",
        Value::map([
            (Value::binary("kind"), Value::binary("call")),
            (Value::binary("target"), Value::binary(target)),
            (Value::binary("request"), request),
            (
                Value::binary("proxy_timeout_ms"),
                Value::Integer(proxy_timeout.into()),
            ),
        ]),
    )
}

pub(crate) fn cast(id: u32, target: &str, request: Value) -> Result<Vec<u8>> {
    send(
        id,
        2,
        b"kettlecorn_proxy",
        Value::map([
            (Value::binary("kind"), Value::binary("cast")),
            (Value::binary("target"), Value::binary(target)),
            (Value::binary("request"), request),
        ]),
    )
}

pub(crate) fn reply(token: &[u8], result: Result<Value, String>) -> Result<Vec<u8>> {
    let (status, value) = match result {
        Ok(value) => ("ok", value),
        Err(reason) => ("error", Value::Binary(reason.into_bytes())),
    };
    // Host replies route by token. Reserve request IDs for sends that need acknowledgments.
    send(0, 1, token, Value::Tuple(vec![Value::atom(status), value]))
}

fn send(id: u32, target_kind: u8, target: &[u8], payload: Value) -> Result<Vec<u8>> {
    ensure!(
        target.len() <= MAX_FRAME_BYTES - 11,
        "target exceeds frame limit"
    );
    let mut bytes = vec![0; 4];
    bytes.push(16);
    bytes.extend(id.to_be_bytes());
    bytes.push(target_kind);
    bytes.extend(u32::try_from(target.len())?.to_be_bytes());
    bytes.extend(target);
    etf::encode(&payload, &mut bytes)?;
    let len = u32::try_from(bytes.len() - 4).context("invalid frame length")?;
    bytes[..4].copy_from_slice(&len.to_be_bytes());
    Ok(bytes)
}

#[cfg(test)]
pub(crate) fn host_call_frame(name: &str, token: u8) -> Vec<u8> {
    message_frame(vec![
        (Value::atom("type"), Value::atom("host_call")),
        (Value::atom("name"), Value::from(name)),
        (Value::atom("args"), Value::map([])),
        (Value::atom("reply_to"), Value::Binary(vec![token])),
    ])
}

#[cfg(test)]
pub(crate) fn message_frame(fields: Vec<(Value, Value)>) -> Vec<u8> {
    let mut frame = vec![0, 0, 0, 0, 3];
    etf::encode(&Value::map(fields), &mut frame).unwrap();
    let len = (frame.len() - 4) as u32;
    frame[..4].copy_from_slice(&len.to_be_bytes());
    frame
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_are_equal_and_usable_as_keys_regardless_of_entry_order() {
        let forward = [
            (Value::from("a"), Value::from(1)),
            (Value::from("b"), Value::from(2)),
        ];
        let reverse = forward.iter().rev().cloned();
        let left = Value::map(forward.clone());
        let right = Value::map(reverse);
        assert_eq!(left, right);
        let indexed = Value::map([(left, Value::from("found"))]);
        assert_eq!(indexed.get(&right), Some(&Value::from("found")));
    }

    #[test]
    fn duplicate_map_keys_keep_the_last_value_at_construction_and_decode() {
        let value = Value::map([
            (Value::from(1), Value::from(2)),
            (Value::from(1), Value::from(3)),
        ]);
        assert_eq!(value.get(&Value::from(1)), Some(&Value::from(3)));
        assert_eq!(
            etf::decode(&[131, 116, 0, 0, 0, 2, 97, 1, 97, 2, 97, 1, 97, 3]).unwrap(),
            value
        );
    }

    #[test]
    fn a_host_call_with_bitstring_arguments_keeps_its_reply_token() {
        let frame = host_call_frame("ping", 42);
        let mut payload = frame[4..].to_vec();
        let args = payload
            .windows(5)
            .position(|bytes| bytes == [116, 0, 0, 0, 0])
            .unwrap();
        payload.splice(
            args..args + 5,
            [116, 0, 0, 0, 1, 97, 1, 77, 0, 0, 0, 1, 1, 128],
        );
        assert!(matches!(
            event(&payload).unwrap(),
            Some(Event::RejectedHostCall(token)) if token == [42]
        ));
    }

    #[test]
    fn etf_rejects_forged_lengths_and_deep_terms() {
        assert!(etf::decode(&[131, 109, 255, 255, 255, 255]).is_err());
        assert!(etf::decode(&[131, 116, 255, 255, 255, 255]).is_err());
        let mut deep = vec![131];
        deep.extend([104, 1].repeat(128));
        deep.extend([106]);
        assert!(etf::decode(&deep).is_err());
    }
}
