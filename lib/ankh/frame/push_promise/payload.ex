defmodule Ankh.Frame.PushPromise.Payload do
  defstruct [pad_length: 0, promised_stream_id: 0, header_block_fragment: <<>>]
end

defimpl Ankh.Frame.Encoder, for: Ankh.Frame.PushPromise.Payload do
  alias Ankh.Frame.PushPromise.{Flags, Payload}

  import Ankh.Frame.Encoder.Utils

  def encode!(%Payload{pad_length: pl, promised_stream_id: psi,
  header_block_fragment: hbf}, flags: %Flags{padded: true})
  do
    <<pl::8, 0::1, psi::31>> <> hbf <> padding(pl)
  end

  def encode!(%Payload{promised_stream_id: psi, header_block_fragment: hbf},
   flags: %Flags{padded: false}) do
    <<0::1, psi::31>> <> hbf
  end

  def decode!(struct, <<pl::8, _::1, psi::31, data::binary>>,
  flags: %Flags{padded: true}) do
    hbf = binary_part(data, 0, byte_size(data) - pl)
    %{struct | pad_length: pl, promised_stream_id: psi,
      header_block_fragment: hbf}
  end

  def decode!(struct, <<_::8, _::1, psi::31, hbf::binary>>,
  flags: %Flags{padded: false}) do
      %{struct | promised_stream_id: psi, header_block_fragment: hbf}
  end
end