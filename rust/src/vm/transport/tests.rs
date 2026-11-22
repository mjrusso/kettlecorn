use super::*;
use std::sync::atomic::{AtomicUsize, Ordering};

#[tokio::test]
async fn cancellation_discards_a_selected_frame_before_its_first_byte() {
    let (mut guest, mut peer) = tokio::io::duplex(64);
    peer.write_all(&[9; 64]).await.unwrap();
    let (client, inbox) = Client::new(16, None);
    let (ready, _boot) = oneshot::channel();
    let (_exit, exited) = oneshot::channel();
    let session = run(
        peer,
        inbox,
        ready,
        Callbacks {
            functions: HashMap::new(),
            deadline: Duration::from_secs(1),
            capacity: 4,
        },
        Duration::from_secs(5),
        Output::default(),
        exited,
    );
    pin_mut!(session);
    let request = client.request(
        Instant::now() + Duration::from_secs(5),
        Duration::ZERO,
        true,
        |_| Ok(vec![7; 4]),
    );
    let mut request = Box::pin(request);
    assert!(request.as_mut().now_or_never().is_none());
    assert!(session.as_mut().now_or_never().is_none());
    drop(request);
    assert!(session.as_mut().now_or_never().is_none());
    let mut filler = [0; 64];
    guest.read_exact(&mut filler).await.unwrap();
    assert_eq!(filler, [9; 64]);
    assert!(session.as_mut().now_or_never().is_none());
    let mut unwanted = [0; 4];
    assert!(guest.read(&mut unwanted).now_or_never().is_none());
}

#[tokio::test]
async fn a_boot_reply_without_the_embedded_api_does_not_open_a_session() {
    let (mut guest, peer) = tokio::io::duplex(128);
    let (_client, inbox) = Client::new(16, None);
    let (ready, boot) = oneshot::channel();
    let (_exit, exited) = oneshot::channel();
    guest
        .write_all(&protocol::message_frame(vec![
            (Value::atom("type"), Value::atom("kettlecorn")),
            (Value::atom("event"), Value::atom("boot_ready")),
        ]))
        .await
        .unwrap();
    let result = run(
        peer,
        inbox,
        ready,
        Callbacks {
            functions: HashMap::new(),
            deadline: Duration::from_secs(1),
            capacity: 4,
        },
        Duration::from_secs(5),
        Output::default(),
        exited,
    )
    .now_or_never()
    .expect("the old boot reply must fail immediately");
    assert!(
        result
            .unwrap_err()
            .to_string()
            .contains("embedded API version")
    );
    assert!(boot.await.is_err());
}

#[tokio::test]
async fn writer_runs_before_reader_drains_a_backlog() {
    const BACKLOG: usize = 64;
    let frame = protocol::host_call_frame("ping", 0);
    let (mut guest, peer) = tokio::io::duplex(frame.len() * BACKLOG);
    guest.write_all(&frame.repeat(BACKLOG)).await.unwrap();

    let (_client, inbox) = Client::new(16, None);
    let (ready, _boot) = oneshot::channel();
    let (_exit, exited) = oneshot::channel();
    let served = Arc::new(AtomicUsize::new(0));
    let calls = served.clone();
    let callback: HostFunction = Arc::new(move |_| {
        calls.fetch_add(1, Ordering::Relaxed);
        Box::pin(async { Ok(Value::atom("ok")) })
    });
    let session = run(
        peer,
        inbox,
        ready,
        Callbacks {
            functions: HashMap::from([("ping".into(), callback)]),
            deadline: Duration::from_secs(1),
            capacity: BACKLOG,
        },
        Duration::from_secs(5),
        Output::default(),
        exited,
    );
    pin_mut!(session);
    assert!(session.as_mut().now_or_never().is_none());

    let count = served.load(Ordering::Relaxed);
    assert!(
        count < BACKLOG,
        "reader drained the backlog before yielding"
    );
    let reply = read_frame(&mut guest)
        .now_or_never()
        .unwrap()
        .unwrap()
        .unwrap();
    let expected = protocol::reply(&[0], Ok(Value::atom("ok"))).unwrap();
    assert_eq!(reply, expected[4..]);
}

#[test]
fn request_ids_stop_at_exhaustion() {
    let (client, _inbox) = Client::new(3, None);
    assert_eq!(client.next_id().unwrap(), 1);
    client.last_id.store(u32::MAX - 1, Ordering::Relaxed);
    assert_eq!(client.next_id().unwrap(), u32::MAX);
    assert!(matches!(client.next_id(), Err(Error::RequestIdsExhausted)));
    assert!(matches!(client.next_id(), Err(Error::RequestIdsExhausted)));
}

#[tokio::test]
async fn rejects_truncated_frames_and_lengths_above_the_drain_limit() {
    let oversized = ((protocol::MAX_FRAME_BYTES + 1) as u32).to_be_bytes();
    let above_drain = ((MAX_DRAIN_BYTES + 1) as u32).to_be_bytes();
    let truncated = read_frame(&mut oversized.as_slice()).await.unwrap_err();
    let above_drain = read_frame(&mut above_drain.as_slice()).await.unwrap_err();
    assert_eq!(truncated.to_string(), "truncated oversized guest frame");
    assert!(above_drain.to_string().contains("exceeds drain limit"));
}

async fn acknowledge(guest: &mut DuplexStream, id: [u8; 4]) {
    let frame = [0, 0, 0, 6, 5, id[0], id[1], id[2], id[3], 0];
    guest.write_all(&frame).await.unwrap();
}

#[tokio::test]
async fn host_replies_stay_bounded_while_the_guest_stops_reading() {
    timeout(Duration::from_secs(10), async {
        let host_capacity = 6;
        let (mut guest, peer) = tokio::io::duplex(64);
        let (client, inbox) = Client::new(16, None);
        let client = Arc::new(client);
        let (ready, _boot) = oneshot::channel();
        let (_exit, exited) = oneshot::channel();
        let callback: HostFunction =
            Arc::new(|_| Box::pin(async { Ok(Value::Binary(vec![0; 4096])) }));
        let (stderr, mut diagnostics) = mpsc::channel(1);
        let session = tokio::spawn(run(
            peer,
            inbox,
            ready,
            Callbacks {
                functions: HashMap::from([("large".into(), callback)]),
                deadline: Duration::from_secs(1),
                capacity: host_capacity,
            },
            Duration::from_secs(5),
            Output {
                stderr: Some(stderr),
                ..Output::default()
            },
            exited,
        ));

        let pending = tokio::spawn({
            let client = client.clone();
            async move {
                client
                    .request(
                        Instant::now() + Duration::from_secs(8),
                        Duration::ZERO,
                        true,
                        |id| Ok(id.to_be_bytes().to_vec()),
                    )
                    .await
            }
        });
        let mut pending_id = [0; 4];
        guest.read_exact(&mut pending_id).await.unwrap();
        guest
            .write_all(&protocol::host_call_frame("large", 0))
            .await
            .unwrap();
        let first_frame_len = guest.read_u32().await.unwrap() as usize;
        assert!(first_frame_len > 64);

        let reply_count = (host_capacity + REJECTIONS) as u8;
        for token in 1..=reply_count {
            guest
                .write_all(&protocol::host_call_frame("large", token))
                .await
                .unwrap();
        }
        acknowledge(&mut guest, pending_id).await;
        assert_eq!(pending.await.unwrap().unwrap(), Value::atom("ok"));
        let expired = client
            .request(
                Instant::now() + Duration::from_millis(50),
                Duration::ZERO,
                true,
                |id| Ok(id.to_be_bytes().to_vec()),
            )
            .await;
        assert!(matches!(expired, Err(Error::Deadline)));

        let (submitted, queued) = oneshot::channel();
        let next = tokio::spawn({
            let client = client.clone();
            async move {
                client
                    .request(
                        Instant::now() + Duration::from_secs(8),
                        Duration::ZERO,
                        true,
                        |id| {
                            submitted.send(()).unwrap();
                            Ok(id.to_be_bytes().to_vec())
                        },
                    )
                    .await
            }
        });
        queued.await.unwrap();

        let mut seen = vec![false; usize::from(reply_count)];
        let mut body = vec![0; first_frame_len];
        guest.read_exact(&mut body).await.unwrap();
        for index in 0..reply_count {
            if index > 0 {
                body = read_frame(&mut guest).await.unwrap().unwrap();
            }
            let token = body[10];
            assert!(!std::mem::replace(&mut seen[usize::from(token)], true));
            let expected = if usize::from(token) < host_capacity {
                Ok(Value::Binary(vec![0; 4096]))
            } else {
                Err("host call capacity exhausted".into())
            };
            let frame = protocol::reply(&[token], expected).unwrap();
            assert_eq!(body, frame[4..]);
        }

        let mut next_id = [0; 4];
        guest.read_exact(&mut next_id).await.unwrap();
        acknowledge(&mut guest, next_id).await;
        assert_eq!(next.await.unwrap().unwrap(), Value::atom("ok"));
        assert_eq!(
            diagnostics.try_recv().unwrap(),
            b"kettlecorn: guest host-call rejection queue full\n"
        );
        drop(client);
        session.await.unwrap().unwrap();
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn a_full_writer_keeps_reply_dispatch_and_deadlines_running() {
    let (mut guest, peer) = tokio::io::duplex(4 * 1024);
    let (client, inbox) = Client::new(16, None);
    let client = Arc::new(client);
    let (ready, _boot) = oneshot::channel();
    let (_exit, exited) = oneshot::channel();
    let session = tokio::spawn(run(
        peer,
        inbox,
        ready,
        Callbacks {
            functions: HashMap::new(),
            deadline: Duration::from_secs(1),
            capacity: 4,
        },
        Duration::from_millis(500),
        Output::default(),
        exited,
    ));
    let initial = tokio::spawn({
        let client = client.clone();
        async move {
            client
                .request(
                    Instant::now() + Duration::from_secs(6),
                    Duration::from_secs(1),
                    true,
                    |id| Ok(id.to_be_bytes().to_vec()),
                )
                .await
        }
    });
    let mut first_id = [0; 4];
    guest.read_exact(&mut first_id).await.unwrap();

    let (reserved, both) = oneshot::channel();
    let max_frame = protocol::MAX_FRAME_BYTES + 4;
    let blocked = tokio::spawn({
        let client = client.clone();
        async move {
            client
                .request(
                    Instant::now() + Duration::from_secs(10),
                    Duration::from_secs(1),
                    false,
                    |_| Ok(vec![1; max_frame]),
                )
                .await
        }
    });
    let mut marker = [0];
    guest.read_exact(&mut marker).await.unwrap();
    assert_eq!(marker, [1]);

    let queued = tokio::spawn({
        let client = client.clone();
        async move {
            client
                .request(
                    Instant::now() + Duration::from_secs(10),
                    Duration::from_secs(1),
                    false,
                    |_| {
                        let _ = reserved.send(());
                        Ok(vec![2; max_frame])
                    },
                )
                .await
        }
    });
    both.await.unwrap();
    let full = client
        .request(
            Instant::now() + Duration::from_millis(10),
            Duration::from_secs(1),
            false,
            |_| panic!("admission must wait for byte capacity"),
        )
        .await;
    assert!(matches!(full, Err(Error::Backpressure)));

    acknowledge(&mut guest, first_id).await;
    assert_eq!(initial.await.unwrap().unwrap(), Value::atom("ok"));
    let error = timeout(Duration::from_secs(2), session)
        .await
        .expect("a partial frame kept the session open")
        .unwrap()
        .unwrap_err();
    assert!(error.to_string().contains("partial guest frame"));
    assert!(blocked.await.unwrap().is_err());
    assert!(queued.await.unwrap().is_err());
}

#[tokio::test]
async fn after_the_guest_exits_forwards_buffered_output_and_ignores_requests_for_it() {
    let (mut guest, peer) = tokio::io::duplex(1024);
    guest
        .write_all(&protocol::message_frame(vec![
            (Value::atom("type"), Value::atom("kettlecorn")),
            (Value::atom("event"), Value::atom("boot_ready")),
            (
                Value::atom("embedded_api"),
                Value::Integer(protocol::EMBEDDED_API.into()),
            ),
        ]))
        .await
        .unwrap();
    guest
        .write_all(&protocol::host_call_frame("ping", 0))
        .await
        .unwrap();
    guest
        .write_all(&protocol::message_frame(vec![
            (Value::atom("type"), Value::atom("kettlecorn")),
            (Value::atom("event"), Value::atom("late_load")),
            (Value::atom("module"), Value::binary("kettlecorn_late")),
        ]))
        .await
        .unwrap();
    drop(guest);
    let (client, inbox) = Client::new(16, None);
    let (ready, boot) = oneshot::channel();
    let served = Arc::new(AtomicUsize::new(0));
    let calls = served.clone();
    let callback: HostFunction = Arc::new(move |_| {
        calls.fetch_add(1, Ordering::Relaxed);
        Box::pin(async { Ok(Value::atom("ok")) })
    });
    let (exit, exited) = oneshot::channel();
    let (late_loads, mut received) = mpsc::channel(1);
    // Writing this queued request to the closed stream would fail.
    let request = tokio::spawn(async move {
        client
            .request(
                Instant::now() + Duration::from_secs(5),
                Duration::ZERO,
                true,
                |_| Ok(vec![7; 4]),
            )
            .await
    });
    tokio::task::yield_now().await;
    exit.send(()).unwrap();
    let session = tokio::spawn(run(
        peer,
        inbox,
        ready,
        Callbacks {
            functions: HashMap::from([("ping".into(), callback)]),
            deadline: Duration::from_secs(1),
            capacity: 4,
        },
        Duration::from_secs(5),
        Output {
            late_loads: Some(late_loads),
            ..Output::default()
        },
        exited,
    ));
    session.await.unwrap().unwrap();
    assert_eq!(received.try_recv().as_deref(), Ok("kettlecorn_late"));
    assert!(request.await.unwrap().is_err());
    assert!(boot.await.is_err());
    assert_eq!(served.load(Ordering::Relaxed), 0);
}

#[tokio::test]
async fn guest_exit_aborts_pending_callbacks() {
    struct Dropped(Arc<AtomicUsize>);
    impl Drop for Dropped {
        fn drop(&mut self) {
            self.0.fetch_add(1, Ordering::Relaxed);
        }
    }
    let (mut guest, peer) = tokio::io::duplex(1024);
    let (_client, inbox) = Client::new(16, None);
    let (ready, _boot) = oneshot::channel();
    let (exit, exited) = oneshot::channel();
    let started = Arc::new(AtomicUsize::new(0));
    let dropped = Arc::new(AtomicUsize::new(0));
    let callback: HostFunction = {
        let (started, dropped) = (started.clone(), dropped.clone());
        Arc::new(move |_| {
            started.fetch_add(1, Ordering::Relaxed);
            let guard = Dropped(dropped.clone());
            Box::pin(async move {
                let _guard = guard;
                std::future::pending().await
            })
        })
    };
    let session = tokio::spawn(run(
        peer,
        inbox,
        ready,
        Callbacks {
            functions: HashMap::from([("wait".into(), callback)]),
            deadline: Duration::from_secs(60),
            capacity: 4,
        },
        Duration::from_secs(5),
        Output::default(),
        exited,
    ));
    guest
        .write_all(&protocol::host_call_frame("wait", 0))
        .await
        .unwrap();
    timeout(Duration::from_secs(1), async {
        while started.load(Ordering::Relaxed) == 0 {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("the callback did not start");
    // The session keeps draining until the guest's output ends.
    exit.send(()).unwrap();
    timeout(Duration::from_secs(1), async {
        while dropped.load(Ordering::Relaxed) == 0 {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("the callback was not aborted");
    assert!(!session.is_finished());
    drop(guest);
    session.await.unwrap().unwrap();
}

#[tokio::test]
async fn after_the_guest_exits_a_buffered_fatal_frame_ends_the_session_with_its_reason() {
    let (mut guest, peer) = tokio::io::duplex(1024);
    let reason = b"kettlecorn-fatal-test";
    guest
        .write_all(&(1 + reason.len() as u32).to_be_bytes())
        .await
        .unwrap();
    guest.write_all(&[4]).await.unwrap();
    guest.write_all(reason).await.unwrap();
    drop(guest);
    let (_client, inbox) = Client::new(16, None);
    let (ready, _boot) = oneshot::channel();
    let (exit, exited) = oneshot::channel();
    exit.send(()).unwrap();
    let error = run(
        peer,
        inbox,
        ready,
        Callbacks {
            functions: HashMap::new(),
            deadline: Duration::from_secs(1),
            capacity: 4,
        },
        Duration::from_secs(5),
        Output::default(),
        exited,
    )
    .await
    .unwrap_err();
    assert!(
        error.to_string().contains("kettlecorn-fatal-test"),
        "{error:#}"
    );
}
