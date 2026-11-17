use kettlecorn_launcher::{
    Cancellation, ExecutionOutcome, GuestOptions, Mode, Runtime, streams::Streams,
};
use std::num::NonZeroUsize;
use std::path::Path;
use tokio::io::{AsyncReadExt, AsyncWriteExt, DuplexStream};

fn fixture() -> Option<(Runtime, tempfile::TempDir, GuestOptions)> {
    let directory = std::env::var_os("KETTLECORN_TEST_RUNTIME")?;
    let directory = Path::new(&directory);
    let root = tempfile::tempdir().unwrap();
    let runtime = Runtime::load(directory).unwrap();
    let guest_root = root.path().join("root");
    runtime
        .populate_root(&guest_root, &kettlecorn_launcher::RootOptions::default())
        .unwrap();
    let options = GuestOptions::new(guest_root);
    Some((runtime, root, options))
}

async fn frame(peer: &mut DuplexStream) -> Vec<u8> {
    let length = peer.read_u32().await.unwrap();
    assert!(length <= 1_048_576);
    let mut body = vec![0; length as usize];
    peer.read_exact(&mut body).await.unwrap();
    body
}

async fn ready(peer: &mut DuplexStream) {
    loop {
        let body = frame(peer).await;
        if body
            .windows(b"echo_ready".len())
            .any(|bytes| bytes == b"echo_ready")
        {
            return;
        }
    }
}

fn echo_options(options: &mut GuestOptions) {
    options.mode = Mode::Cli {
        iex: false,
        args: vec![
            "-e".into(),
            r#"
      pid = spawn(fn ->
        receive do {:wasm, value} -> Kettlecorn.Host.send(value) end
      end)
      Process.register(pid, :library_echo)
      Kettlecorn.Host.send(:echo_ready)
      Process.sleep(:infinity)
    "#
            .into(),
        ],
    };
}

async fn ping(peer: &mut DuplexStream) {
    let name = b"library_echo";
    let mut payload = vec![16, 0, 0, 0, 1, 0];
    payload.extend((name.len() as u32).to_be_bytes());
    payload.extend(name);
    payload.extend([131, 97, 42]);
    peer.write_u32(payload.len() as u32).await.unwrap();
    peer.write_all(&payload).await.unwrap();
    loop {
        let reply = frame(peer).await;
        if reply.first() == Some(&3) {
            assert!(reply.windows(10).any(|bytes| bytes == b"vm_message"));
            assert!(reply.windows(2).any(|bytes| bytes == [97, 42]));
            return;
        }
    }
}

#[tokio::test]
async fn framed_exchange_and_cancellation() {
    let Some((_runtime, _root, mut options)) = fixture() else {
        return;
    };
    let source = tempfile::tempdir().unwrap();
    let original = std::env::var_os("KETTLECORN_TEST_RUNTIME").unwrap();
    for name in ["manifest.json", "launch", "beam.wasm", "beam-http.wasm"] {
        std::os::unix::fs::symlink(Path::new(&original).join(name), source.path().join(name))
            .unwrap();
    }
    let runtime = Runtime::load(source.path()).unwrap();
    echo_options(&mut options);
    let prepared = runtime.prepare(&options).unwrap();
    std::fs::remove_file(source.path().join("beam.wasm")).unwrap();
    std::fs::remove_file(source.path().join("beam-http.wasm")).unwrap();
    let (streams, mut peer) = Streams::memory(NonZeroUsize::new(4096).unwrap());
    let cancel = Cancellation::default();
    let host = async {
        ready(&mut peer).await;
        ping(&mut peer).await;
        cancel.cancel();
    };
    let (result, ()) = tokio::time::timeout(std::time::Duration::from_secs(300), async {
        tokio::join!(prepared.run(options, streams, cancel.clone()), host)
    })
    .await
    .unwrap();
    assert!(matches!(result, ExecutionOutcome::Cancelled), "{result:?}");
}

#[tokio::test]
async fn cancelling_busy_guest_leaves_another_guest_running() {
    let Some((runtime, _root, mut busy_options)) = fixture() else {
        return;
    };
    let (_, _other_root, mut other_options) = fixture().unwrap();
    busy_options.mode = Mode::Cli { iex: false, args: vec!["-e".into(),
        "Kettlecorn.Host.send(:echo_ready); Process.flag(:priority, :max); Stream.repeatedly(fn -> 1 end) |> Stream.run()".into()] };
    echo_options(&mut other_options);
    let prepared = runtime.prepare(&busy_options).unwrap();
    let (busy_streams, mut busy_peer) = Streams::memory(NonZeroUsize::new(4096).unwrap());
    let (other_streams, mut other_peer) = Streams::memory(NonZeroUsize::new(4096).unwrap());
    let busy_cancel = Cancellation::default();
    let other_cancel = Cancellation::default();
    let host = async {
        ready(&mut busy_peer).await;
        ready(&mut other_peer).await;
        busy_cancel.cancel();
        ping(&mut other_peer).await;
        other_cancel.cancel();
    };
    let (busy, other, ()) = tokio::time::timeout(std::time::Duration::from_secs(300), async {
        tokio::join!(
            prepared.run(busy_options, busy_streams, busy_cancel.clone()),
            prepared.run(other_options, other_streams, other_cancel.clone()),
            host
        )
    })
    .await
    .unwrap();
    assert!(matches!(busy, ExecutionOutcome::Cancelled), "{busy:?}");
    assert!(matches!(other, ExecutionOutcome::Cancelled), "{other:?}");
}

#[tokio::test]
async fn unframed_eof_is_guest_input() {
    let Some((runtime, _root, mut options)) = fixture() else {
        return;
    };
    options.framed = false;
    options.mode = Mode::Cli {
        iex: false,
        args: vec![
            "-e".into(),
            "IO.write(\"done:\" <> IO.read(:stdio, :eof))".into(),
        ],
    };
    let prepared = runtime.prepare(&options).unwrap();
    let (streams, mut peer) = Streams::memory(NonZeroUsize::new(4096).unwrap());
    let host = async {
        peer.write_all(b"hello").await.unwrap();
        peer.shutdown().await.unwrap();
        let mut output = Vec::new();
        peer.read_to_end(&mut output).await.unwrap();
        assert_eq!(output, b"done:hello");
    };
    let (result, ()) = tokio::time::timeout(std::time::Duration::from_secs(300), async {
        tokio::join!(
            prepared.run(options, streams, Cancellation::default()),
            host
        )
    })
    .await
    .unwrap();
    assert!(
        matches!(result, ExecutionOutcome::Exited { code: 0 }),
        "{result:?}"
    );
}

#[tokio::test]
async fn reports_guest_exit_fuel_and_lifetime_outcomes() {
    let Some((runtime, _root, mut options)) = fixture() else {
        return;
    };
    options.framed = false;
    options.max_fuel = Some(100_000_000_000);
    let prepared = runtime.prepare(&options).unwrap();
    for case in 0..3 {
        let mut options = options.clone();
        options.mode = Mode::Cli {
            iex: false,
            args: vec![
                "-e".into(),
                if case == 0 {
                    "System.halt(23)".into()
                } else {
                    "Stream.repeatedly(fn -> 1 end) |> Stream.run()".into()
                },
            ],
        };
        if case == 1 {
            options.max_fuel = Some(1);
        } else if case == 2 {
            options.max_lifetime = Some(std::time::Duration::from_secs(1));
        }
        let (streams, mut peer) = Streams::memory(NonZeroUsize::new(4096).unwrap());
        let host = async {
            peer.shutdown().await.unwrap();
            peer.read_to_end(&mut Vec::new()).await.unwrap();
        };
        let (outcome, ()) = tokio::time::timeout(std::time::Duration::from_secs(30), async {
            tokio::join!(
                prepared.run(options, streams, Cancellation::default()),
                host
            )
        })
        .await
        .unwrap();
        assert!(
            matches!(
                (case, &outcome),
                (0, ExecutionOutcome::Exited { code: 23 })
                    | (1, ExecutionOutcome::OutOfFuel)
                    | (2, ExecutionOutcome::Timeout)
            ),
            "{outcome:?}"
        );
    }
}

#[tokio::test]
async fn guest_boot_rejects_incompatible_copied_bundles() {
    let Some((runtime, _root, template)) = fixture() else {
        return;
    };
    let manifest: serde_json::Value =
        serde_json::from_slice(&std::fs::read(template.root.join("manifest.json")).unwrap())
            .unwrap();
    let metadata = serde_json::json!({
        "protocol": manifest["protocol"],
        "otp": manifest["otp"].as_str().unwrap().split('.').next().unwrap(),
        "elixir": manifest["elixir"],
    });
    let prepared = runtime.prepare(&template).unwrap();
    for (key, value) in [
        ("protocol", serde_json::json!(0)),
        ("extra", serde_json::json!(true)),
    ] {
        let root = tempfile::tempdir().unwrap();
        let mut options = template.clone();
        options.root = root.path().join("root");
        runtime
            .populate_root(&options.root, &kettlecorn_launcher::RootOptions::default())
            .unwrap();
        let app = options.root.join("app");
        std::fs::create_dir(&app).unwrap();
        std::fs::write(app.join("app"), "must_not_start").unwrap();
        std::fs::write(app.join("sys.config"), "[].\n").unwrap();
        let mut metadata = metadata.clone();
        metadata[key] = value;
        std::fs::write(
            app.join("kettlecorn.json"),
            serde_json::to_vec(&metadata).unwrap(),
        )
        .unwrap();
        let (streams, mut peer) = Streams::memory(NonZeroUsize::new(4096).unwrap());
        let host = async {
            let mut output = Vec::new();
            peer.read_to_end(&mut output).await.unwrap();
            output
        };
        let (outcome, output) = tokio::time::timeout(std::time::Duration::from_secs(30), async {
            tokio::join!(
                prepared.run(options, streams, Cancellation::default()),
                host
            )
        })
        .await
        .unwrap();
        assert!(
            matches!(outcome, ExecutionOutcome::Exited { code: 1 }),
            "{outcome:?}"
        );
        for expected in [
            b"boot_failed".as_slice(),
            b"incompatible cooked application",
        ] {
            assert!(
                output
                    .windows(expected.len())
                    .any(|bytes| bytes == expected)
            );
        }
    }
}
