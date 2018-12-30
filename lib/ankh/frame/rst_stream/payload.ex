defmodule Ankh.Frame.RstStream.Payload do
  @moduledoc false
  alias Ankh.Error

  @type t :: %__MODULE__{error_code: Error.t()}
  defstruct error_code: :no_error
end

defimpl Ankh.Frame.Encodable, for: Ankh.Frame.RstStream.Payload do
  alias Ankh.Error

  def decode(payload, <<error::32>>, _), do: {:ok, %{payload | error_code: Error.decode(error)}}
  def decode(_payload, _data, _options), do: {:error, :decode_error}

  def encode(%{error_code: error}, _), do: {:ok, [Error.encode(error)]}
  def encode(_payload, _options), do: {:error, :encode_error}
end
