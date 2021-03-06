defmodule Ankh.HTTP2.Frame.WindowUpdate do
  @moduledoc false

  defmodule Payload do
    @moduledoc false

    @type t :: %__MODULE__{increment: integer}
    defstruct increment: 0
  end

  alias __MODULE__.Payload
  use Ankh.HTTP2.Frame, type: 0x8, payload: Payload
end

defimpl Ankh.HTTP2.Frame.Encodable, for: Ankh.HTTP2.Frame.WindowUpdate.Payload do
  def decode(payload, <<_::1, increment::31>>, _) do
    {:ok, %{payload | increment: increment}}
  end

  def decode(_payload, _data, _options), do: {:error, :decode_error}

  def encode(%{increment: increment}, _), do: {:ok, [<<0::1, increment::31>>]}
  def encode(_payload, _options), do: {:error, :encode_error}
end
