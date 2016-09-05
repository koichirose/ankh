defmodule Ankh.Frame.Data.Payload do
  defstruct [pad_length: 0, data: <<>>]
end

defimpl Ankh.Frame.Encoder, for: Ankh.Frame.Data.Payload do
  alias Ankh.Frame.Data.{Flags, Payload}

  import Ankh.Frame.Encoder.Utils

  def decode!(struct, <<pad_length::8, padded_data::binary>>,
  flags: %Flags{padded: true}) do
    data = binary_part(padded_data, 0, byte_size(padded_data) - pad_length)
    %{struct | pad_length: pad_length, data: data}
  end

  def decode!(struct, <<data::binary>>, flags: %Flags{padded: false})
  do
    %{struct | data: data}
  end

  def encode!(%Payload{pad_length: pad_length, data: data},
  flags: %Flags{padded: true}) do
    <<pad_length::8, data>> <> padding(pad_length)
  end

  def encode!(%Payload{data: data}, flags: %Flags{padded: false}) do
    data
  end
end