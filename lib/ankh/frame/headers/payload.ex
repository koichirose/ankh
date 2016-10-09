defmodule Ankh.Frame.Headers.Payload do
  @moduledoc """
  HEADERS frame payload
  """

  @type t :: %__MODULE__{pad_length: Integer.t, exclusive: boolean,
  stream_dependency: Integer.t, weight: Integer.t,
  header_block_fragment: binary}
  defstruct [pad_length: 0, exclusive: false, stream_dependency: 0, weight: 0,
  header_block_fragment: <<>>]
end

defimpl Ankh.Frame.Payload, for: Ankh.Frame.Headers.Payload do
  import Ankh.Frame.Utils

  def encode!(%{pad_length: pl, exclusive: ex, stream_dependency: sd,
  weight: wh, header_block_fragment: hbf}, flags: %{padded: true,
  priority: true})
  do
    <<pl::8, bool_to_int!(ex)::1, sd::31, wh::8>> <> hbf <> padding(pl)
  end

  def encode!(%{pad_length: pl, header_block_fragment: hbf},
  flags: %{padded: true, priority: false}) do
    <<pl::8>> <> hbf <> padding(pl)
  end

  def encode!(%{exclusive: ex, stream_dependency: sd, weight: wh,
  header_block_fragment: hbf}, flags: %{padded: false, priority: true}) do
    <<bool_to_int!(ex)::1, sd::31, wh::8, hbf::binary>>
  end

  def encode!(%{header_block_fragment: hbf}, flags: %{padded: false,
  priority: false}) do
    hbf
  end

  def decode!(struct, <<pl::8, ex::1, sd::31, wh::8, data::binary>>,
  flags: %{padded: true, priority: true}) do
    hbf = binary_part(data, 0, byte_size(data) - pl)
    %{struct | pad_length: pl, exclusive: int_to_bool!(ex), weight: wh,
      stream_dependency: sd, header_block_fragment: hbf}
  end

  def decode!(struct, <<pl::8, data::binary>>, flags: %{padded: true,
  priority: false}) do
    hbf = binary_part(data, 0, byte_size(data) - pl)
    %{struct | pad_length: pl, header_block_fragment: hbf}
  end

  def decode!(struct, <<ex::1, sd::31, wh::8, hbf::binary>>,
  flags: %{padded: false, priority: true}) do
      %{struct | exclusive: int_to_bool!(ex), weight: wh,
        stream_dependency: sd, header_block_fragment: hbf}
  end

  def decode!(struct, <<hbf::binary>>, flags: %{padded: false, priority: false})
  do
    %{struct | header_block_fragment: hbf}
  end
end
