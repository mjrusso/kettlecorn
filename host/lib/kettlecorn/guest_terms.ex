defmodule Kettlecorn.Pid do
  @moduledoc """
  A process inside a guest VM.

  Received in messages from the guest. It can only be used as the target of
  `Kettlecorn.send/4` on the VM it came from (calls and casts go to
  registered names); sending it to another VM returns `{:error, :wrong_vm}`.
  It never becomes a host pid. Standalone `Kettlecorn.ETF.decode/2` calls
  produce unbound handles unless given the `:vm` option.
  """
  @enforce_keys [:etf]
  defstruct [:etf, :vm]
  @type t :: %__MODULE__{etf: binary(), vm: pid() | nil}

  defimpl Inspect do
    def inspect(_pid, _opts), do: "#Kettlecorn.Pid<guest>"
  end
end

defmodule Kettlecorn.Struct do
  @moduledoc """
  A guest struct represented as data: its module and fields.

  `Kettlecorn.ETF` produces this wrapper when the module atom exists on the
  host. Otherwise the value stays a map with
  `__struct__: {:unknown_atom, name}`.

  Decoding it as a struct of `module` would allow that module's protocol
  implementations to run on the host with guest-supplied fields. Validate
  the fields before constructing a host struct:

      case value do
        %Kettlecorn.Struct{module: MyApp.Order, fields: fields} -> MyApp.Order.new(fields)
        _other -> {:error, :unexpected_value}
      end

  The [Validating guest data notebook](guest-data.html)
  validates quotes and dates, including structs nested in other data.
  """
  @enforce_keys [:module, :fields]
  defstruct [:module, :fields]
  @type t :: %__MODULE__{module: atom(), fields: map()}

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%{module: module, fields: fields}, opts),
      do: concat(["#Kettlecorn.Struct<", to_doc(module, opts), " ", to_doc(fields, opts), ">"])
  end
end

defmodule Kettlecorn.Opaque do
  @moduledoc "A guest reference or port. Carries no usable data on the host."
  defstruct [:type]
  @type t :: %__MODULE__{type: :reference | :port}
end
