defmodule Ankh.HTTP2.Frame.Ping do
  @moduledoc false

  defmodule Flags do
    @moduledoc false

    @type t :: %__MODULE__{ack: boolean}
    defstruct ack: false
  end

  defmodule Payload do
    @moduledoc false

    @type t :: %__MODULE__{data: binary}
    defstruct data: <<>>
  end

  alias __MODULE__.{Flags, Payload}
  use Ankh.HTTP2.Frame, type: 0x6, flags: Flags, payload: Payload
end

defimpl Ankh.HTTP2.Frame.Encodable, for: Ankh.HTTP2.Frame.Ping.Flags do
  def decode(flags, <<_::7, 1::1>>, _), do: {:ok, %{flags | ack: true}}
  def decode(flags, <<_::7, 0::1>>, _), do: {:ok, %{flags | ack: false}}
  def decode(_flags, _data, _options), do: {:error, :decode_error}

  def encode(%{ack: true}, _), do: {:ok, <<0::7, 1::1>>}
  def encode(%{ack: false}, _), do: {:ok, <<0::7, 0::1>>}
  def encode(_flags, _options), do: {:error, :encode_error}
end

defimpl Ankh.HTTP2.Frame.Encodable, for: Ankh.HTTP2.Frame.Ping.Payload do
  def decode(payload, data, _) when is_binary(data), do: {:ok, %{payload | data: data}}
  def decode(_payload, _data, _options), do: {:error, :decode_error}

  def encode(%{data: data}, _) when is_binary(data), do: {:ok, [data]}
  def encode(_payload, _options), do: {:error, :encode_error}
end
