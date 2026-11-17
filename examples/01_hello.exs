# Print the guest's Elixir version, architecture and arguments.
IO.puts("Hello from Elixir #{System.version()} on OTP #{System.otp_release()}!")
IO.puts("Running on: #{:erlang.system_info(:system_architecture)}")
IO.puts("Arguments: #{inspect(System.argv())}")
