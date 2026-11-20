use kettlecorn::{EvalOptions, Language, Runtime, Value, VmOptions};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::Notify;

#[tokio::test]
async fn oversized_eval_results_keep_inspected_output_and_leave_the_vm_running() {
    let Some(directory) = std::env::var_os("KETTLECORN_TEST_RUNTIME") else {
        return;
    };
    let runtime = Runtime::load(directory).unwrap();
    let vm = runtime.start(VmOptions::default()).await.unwrap();

    for source in [
        "Enum.to_list(1..200_000)",
        "Enum.reduce(1..70, :leaf, fn _, term -> {term} end)",
        ":binary.copy(<<0>>, 9_000_000)",
    ] {
        let evaluation = vm
            .eval(
                source,
                EvalOptions {
                    timeout: Duration::from_secs(5),
                    ..EvalOptions::default()
                },
            )
            .await
            .unwrap_or_else(|error| panic!("{source}: {error:#}"));
        let value = evaluation
            .result
            .unwrap_or_else(|error| panic!("{source}: {error}"));
        assert!(value.value.is_none());
        assert!(!value.inspected.is_empty());
        let next = vm.eval("2 + 2", EvalOptions::default()).await.unwrap();
        assert_eq!(next.result.unwrap().value, Some(Value::Integer(4.into())));
    }
    vm.shutdown().await.unwrap();
}

#[tokio::test]
async fn evaluates_scripts_and_dispatches_host_calls_in_one_vm() {
    let Some(directory) = std::env::var_os("KETTLECORN_TEST_RUNTIME") else {
        return;
    };
    let runtime = Runtime::load(directory).unwrap();
    let mut options = VmOptions::default();
    options.register("lookup", |args| async move {
        if args
            != Value::map([(
                Value::Binary(b"item".to_vec()),
                Value::Binary(b"tea".to_vec()),
            )])
        {
            return Err("unexpected arguments".into());
        }
        Ok(Value::Integer(7.into()))
    });
    let started = Arc::new(Notify::new());
    let notify = started.clone();
    options.register("started", move |_| {
        let notify = notify.clone();
        async move {
            notify.notify_one();
            Ok(Value::Tuple(vec![]))
        }
    });
    runtime.clone().warm_up(&options).await.unwrap();
    let vm = runtime.start(options).await.unwrap();

    let mut eval = EvalOptions::default();
    eval.binding
        .insert("item".into(), Value::Binary(b"tea".to_vec()));
    let result = vm
        .eval(
            r#"
        {:ok, amount} = Kettlecorn.Host.call("lookup", %{"item" => item})
        IO.puts(item)
        amount * 2
        "#,
            eval,
        )
        .await
        .unwrap();
    assert_eq!(result.output, "tea\n");
    let result = result.result.unwrap();
    assert_eq!(result.inspected, "14");
    assert_eq!(result.value, Some(Value::Integer(14.into())));

    let mut eval = EvalOptions {
        language: Language::Erlang,
        ..Default::default()
    };
    eval.binding.insert("N".into(), Value::Integer(12.into()));
    let result = vm.eval("N * 2.", eval).await.unwrap();
    assert_eq!(
        result.result.unwrap().value,
        Some(Value::Integer(24.into()))
    );

    let result = vm
        .eval(
            r#"IO.puts("before"); raise "problem""#,
            EvalOptions::default(),
        )
        .await
        .unwrap();
    assert_eq!(result.output, "before\n");
    assert_eq!(result.result.unwrap_err().kind, "error");

    let slow = EvalOptions {
        timeout: Duration::from_millis(25),
        ..Default::default()
    };
    let result = vm.eval("Process.sleep(:infinity)", slow).await.unwrap();
    assert_eq!(result.result.unwrap_err().kind, "timeout");

    {
        let eval = vm.eval(
            r#"Kettlecorn.Host.call("started", %{}); Process.sleep(:infinity)"#,
            EvalOptions::default(),
        );
        tokio::pin!(eval);
        tokio::select! {
            _ = started.notified() => {},
            result = &mut eval => panic!("evaluation finished before host call: {result:?}"),
        }
    }
    let next = vm.eval("2 + 2", EvalOptions::default()).await.unwrap();
    assert_eq!(next.result.unwrap().value, Some(Value::Integer(4.into())));
    vm.shutdown().await.unwrap();
}

#[tokio::test]
async fn a_waiting_host_callback_leaves_other_requests_available() {
    let Some(directory) = std::env::var_os("KETTLECORN_TEST_RUNTIME") else {
        return;
    };
    let runtime = Runtime::load(directory).unwrap();
    let mut options = VmOptions::default();
    let entered = Arc::new(Notify::new());
    let release = Arc::new(Notify::new());
    options.register("wait", {
        let entered = entered.clone();
        let release = release.clone();
        move |_| {
            let entered = entered.clone();
            let release = release.clone();
            async move {
                entered.notify_one();
                release.notified().await;
                Ok(Value::from(7))
            }
        }
    });
    let vm = runtime.start(options).await.unwrap();

    {
        let slow = vm.eval(
            r#"Kettlecorn.Host.call("wait")"#,
            EvalOptions {
                timeout: Duration::from_secs(8),
                ..Default::default()
            },
        );
        tokio::pin!(slow);
        tokio::select! {
            _ = entered.notified() => {},
            result = &mut slow => panic!("eval finished before the callback could wait: {result:?}"),
        }

        let fast = vm.eval("2 + 2", EvalOptions::default()).await.unwrap();
        assert_eq!(fast.result.unwrap().value, Some(Value::from(4)));
        release.notify_one();
        assert_eq!(
            slow.await.unwrap().result.unwrap().value,
            Some(Value::Tuple(vec![Value::atom("ok"), Value::from(7)]))
        );
    }
    vm.shutdown().await.unwrap();
}

#[tokio::test]
async fn named_operations_deliver_events_and_report_oversized_host_calls() {
    use kettlecorn::Error;
    use tokio::sync::{broadcast, mpsc};
    use tokio::time::timeout;

    let Some(directory) = std::env::var_os("KETTLECORN_TEST_RUNTIME") else {
        return;
    };
    let runtime = Runtime::load(directory).unwrap();
    let (stderr, mut diagnostics) = mpsc::channel(16);
    let (event_sender, mut early_events) = broadcast::channel(4);
    let mut options = VmOptions::default();
    options.stderr = Some(stderr);
    options.events = Some(event_sender);
    let vm = runtime.start(options).await.unwrap();

    let loaded = vm
        .eval(
            r#"
        defmodule HostCounter do
          use GenServer
          def init(value), do: {:ok, value}
          def handle_call(:value, _from, value), do: {:reply, value, value}
              def handle_call(:bits, _from, value), do: {:reply, <<1::1>>, value}
          def handle_cast({:add, amount}, value) do
            Kettlecorn.Host.send("counter updated")
            {:noreply, value + amount}
          end
        end
        IO.puts(:stderr, "counter diagnostic")
        {:ok, _} = GenServer.start(HostCounter, 1, name: HostCounter)
        Kettlecorn.Host.send("counter ready")
        :ok
        "#,
            EvalOptions::default(),
        )
        .await
        .unwrap();
    loaded.result.unwrap();
    assert_eq!(
        timeout(Duration::from_secs(5), early_events.recv())
            .await
            .unwrap()
            .unwrap(),
        Value::from("counter ready")
    );
    let mut events = vm.subscribe();

    let name = "Elixir.HostCounter";
    vm.cast(name, Value::Tuple(vec![Value::atom("add"), Value::from(2)]))
        .await
        .unwrap();
    assert_eq!(
        timeout(Duration::from_secs(5), events.recv())
            .await
            .unwrap()
            .unwrap(),
        Value::from("counter updated")
    );
    assert_eq!(
        vm.call(name, Value::atom("value")).await.unwrap(),
        Value::from(3)
    );
    assert!(matches!(
        vm.call("Elixir.NoSuchProcess", Value::atom("value")).await,
        Err(Error::GuestCall(reason)) if reason.as_atom() == Some("noproc")
    ));
    assert!(matches!(
        vm.call(name, Value::atom("bits")).await,
        Err(Error::Protocol(_))
    ));

    timeout(Duration::from_secs(5), async {
        let mut output = Vec::new();
        while let Some(chunk) = diagnostics.recv().await {
            output.extend(chunk);
            if String::from_utf8_lossy(&output).contains("counter diagnostic") {
                return;
            }
        }
        panic!("diagnostics closed before the guest stderr message");
    })
    .await
    .unwrap();

    for args in [
        r#"%{"items" => Enum.to_list(1..100_001)}"#,
        r#"%{"bits" => <<1::1>>}"#,
        r#"%{"pid" => self(), "ref" => make_ref()}"#,
    ] {
        let rejected = vm
            .eval(
                &format!(r#"Kettlecorn.Host.call("invalid", {args}, timeout: :infinity)"#),
                EvalOptions {
                    timeout: Duration::from_secs(8),
                    ..Default::default()
                },
            )
            .await
            .unwrap();
        assert_eq!(
            rejected.result.unwrap().value,
            Some(Value::Tuple(vec![
                Value::atom("error"),
                Value::from("invalid or oversized host call arguments"),
            ]))
        );
    }

    let sent = vm
        .eval(
            "Enum.each(1..40, &Kettlecorn.Host.send/1)",
            EvalOptions::default(),
        )
        .await
        .unwrap();
    sent.result.unwrap();
    assert!(matches!(
        events.recv().await,
        Err(broadcast::error::RecvError::Lagged(36))
    ));
    vm.shutdown().await.unwrap();
}

#[tokio::test]
async fn oversized_guest_frames_leave_the_vm_running() {
    let Some(directory) = std::env::var_os("KETTLECORN_TEST_RUNTIME") else {
        return;
    };
    let runtime = Runtime::load(directory).unwrap();
    let vm = runtime.start(VmOptions::default()).await.unwrap();
    let transferred = vm
        .eval(
            r#"
            defmodule LargeReply do
              use GenServer
              def init(:ok), do: {:ok, :ok}
              def handle_call(:large, _from, state), do: {:reply, :binary.copy(<<0>>, 8 * 1024 * 1024), state}
              def handle_call(:small, _from, state), do: {:reply, :ok, state}
            end

            {:ok, _} = GenServer.start(LargeReply, :ok, name: LargeReply)
            :ok = :wasm.send_raw(:binary.copy(<<0>>, 8 * 1024 * 1024))
            :ok
            "#,
            EvalOptions {
                timeout: Duration::from_secs(30),
                ..Default::default()
            },
        )
        .await
        .unwrap()
        .result
        .unwrap();
    assert_eq!(transferred.value, Some(Value::atom("ok")));

    for source in [
        r#"Kettlecorn.Host.send(fn -> :ok end)"#,
        r#"Kettlecorn.Host.send(:records.create(:test, :native, [], %{is_exported: true}))"#,
        r#"Kettlecorn.Host.call("oversized", %{"body" => :binary.copy(<<0>>, 8 * 1024 * 1024)}, timeout: :infinity)"#,
        r#"Kettlecorn.Host.send(:binary.copy(<<0>>, 8 * 1024 * 1024))"#,
        r#"Kettlecorn.Host.send(List.duplicate(:binary.copy(<<0>>, 1024 * 1024), 1024))"#,
        r#"Kettlecorn.Host.call("oversized", %{"shared" => List.duplicate(:binary.copy(<<0>>, 1024 * 1024), 1024)}, timeout: :infinity)"#,
    ] {
        let rejected = vm
            .eval(source, EvalOptions::default())
            .await
            .unwrap()
            .result
            .unwrap();
        assert_eq!(
            rejected.value,
            Some(Value::Tuple(vec![
                Value::atom("error"),
                Value::atom("frame_too_large")
            ])),
        );
    }
    let name = "Elixir.LargeReply";
    assert!(matches!(
        vm.call(name, Value::atom("large")).await,
        Err(kettlecorn::Error::GuestCall(reason)) if reason.as_atom() == Some("frame_too_large")
    ));
    assert_eq!(
        vm.call(name, Value::atom("small")).await.unwrap(),
        Value::atom("ok")
    );
    vm.shutdown().await.unwrap();
}
