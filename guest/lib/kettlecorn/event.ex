defmodule Kettlecorn.Event do
  @moduledoc false
  # Keep events in :kettlecorn envelopes. The host must treat :vm_message
  # envelopes from :wasm.send/1 as user data, even if their payload resembles an event.

  @compile {:no_warn_undefined, :wasm}

  def send(fields),
    do: :wasm.send_envelope(Map.put(fields, :type, :kettlecorn))
end
