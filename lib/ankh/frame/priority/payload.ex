defmodule Ankh.Frame.Priority.Payload do
  defstruct [exclusive: false, stream_dependency: 0, weight: 0]
end

defimpl Ankh.Frame.Encoder, for: Ankh.Frame.Priority.Payload do
  alias Ankh.Frame.Priority.Payload

  import Ankh.Frame.Encoder.Utils

  def encode!(%Payload{exclusive: ex, stream_dependency: sd, weight: wh}, _) do
    <<bool_to_int!(ex)::1, sd::31, wh::8>>
  end

  def decode!(struct, <<ex::1, sd::31, wh::8>>, _) do
    %{struct | exclusive: int_to_bool!(ex), stream_dependency: sd, weight: wh}
  end
end
