# Reach's architecture check (`mix reach.check --arch`, part of `just lint`):
# the host library's security invariants as call rules. A new caller of one
# of these changes an invariant: update the rule and its comment with it.
all = ["Kettlecorn", "Kettlecorn.*", "Mix.Tasks.Kettlecorn.*"]

[
  checks: [source_paths: ["lib"]],
  calls: [
    forbidden: [
      # Guest output is untrusted. It is decoded by Kettlecorn.ETF's own
      # parser, never by binary_to_term, which would create live pids and funs
      # and new atoms.
      {all, [":erlang.binary_to_term"]},
      # Only Kettlecorn.VM opens the launcher port.
      {all, ["Port.open", ":erlang.open_port"], except: ["Kettlecorn.VM"]},
      # Dir copies build assets; Runtime invokes native root population.
      {all, ["System.cmd", "System.shell", ":os.cmd"],
       except: ["Kettlecorn.Dir", "Kettlecorn.Runtime"]},
      # Strings from the guest never become atoms. Only Kettlecorn.Cook,
      # which reads the cooking project's own build, makes atoms from strings.
      {all, ["String.to_atom", ":erlang.binary_to_atom", ":erlang.list_to_atom"],
       except: ["Kettlecorn.Cook"]}
    ]
  ],
  effects: [
    allowed: [
      # The decoders of guest output do no I/O.
      {"Kettlecorn.ETF", [:pure, :exception, :unknown]},
      {"Kettlecorn.Protocol", [:pure, :exception, :unknown]}
    ]
  ]
]
