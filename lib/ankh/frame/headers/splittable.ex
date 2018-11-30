defimpl Ankh.Frame.Splittable, for: Ankh.Frame.Headers do
  alias Ankh.Frame.{Continuation, Headers}

  def split(%{flags: flags, payload: %{hbf: hbf}} = frame, frame_size, end_stream)
      when byte_size(hbf) <= frame_size do
    [%{frame | flags: %{flags | end_headers: true, end_stream: end_stream}}]
  end

  def split(frame, frame_size, end_stream) do
    do_split(frame, frame_size, [], end_stream)
  end

  defp do_split(
         %{stream_id: id, flags: flags, payload: %{hbf: hbf} = payload},
         frame_size,
         end_stream,
         frames
       )
       when byte_size(hbf) <= frame_size do
    frame = %Continuation{
      stream_id: id,
      flags: %{flags | end_headers: true, end_stream: end_stream},
      payload: %{payload | hbf: hbf}
    }

    Enum.reverse([frame | frames])
  end

  defp do_split(
         %{flags: flags, payload: %{hbf: hbf} = payload} = frame,
         frame_size,
         end_stream,
         []
       ) do
    <<chunk::size(frame_size), rest::binary>> = hbf
    frames = [%{frame | payload: %{payload | hbf: chunk}}]

    do_split(
      %{frame | flags: %{flags | end_headers: false}, payload: %{hbf: rest}},
      frame_size,
      end_stream,
      frames
    )
  end

  defp do_split(
         %{stream_id: id, payload: %{hbf: hbf} = payload},
         frame_size,
         end_stream,
         frames
       ) do
    <<chunk::size(frame_size), rest::binary>> = hbf
    frames = [%Continuation{stream_id: id, payload: %{payload | hbf: chunk}} | frames]
    do_split(%Headers{payload: %{hbf: rest}}, frame_size, end_stream, frames)
  end
end