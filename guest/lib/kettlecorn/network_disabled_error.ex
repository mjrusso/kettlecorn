defmodule Kettlecorn.NetworkDisabledError do
  @moduledoc """
  Returned by Req's default adapter when neither HTTP nor network access is granted.
  The `:reason` field identifies this denial with the code `:network_disabled`.
  Req's default retry policy does not retry this error.
  """

  defexception reason: :network_disabled,
               message: """
               Outgoing HTTP is disabled for this VM. \
               Enable --http (http: true) for HTTP requests, \
               or --network (network: true) for TCP/UDP and DNS.\
               """
end
