defmodule Ankh.Connection do
  use GenServer

  alias Ankh.Frame
  alias Ankh.Frame.{Encoder, Error, GoAway, Ping, Settings}

  require Logger

  @ssl_opts binary: true, versions: [:"tlsv1.2"],
            alpn_advertised_protocols: ["h2"]
  @preface "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
  @frame_header_size 9
  @max_stream_id 2_147_483_648

  def start_link(%URI{} = uri, stream \\ false, receiver \\ nil, options \\ [])
  do
    target = if is_pid(receiver) do
      receiver
    else
      self()
    end
    mode = if is_boolean(stream) && stream do
      :stream
    else
      :full
    end
    GenServer.start_link(__MODULE__, [uri: uri, target: target, mode: mode],
    options)
  end

  def init([uri: uri, target: target, mode: mode]) do
    with settings <-  %Settings.Payload{},
         {:ok, recv_ctx} = HPack.Table.start_link(settings.header_table_size),
         {:ok, send_ctx} = HPack.Table.start_link(settings.header_table_size) do
      {:ok, %{uri: uri, target: target, mode: mode, socket: nil, streams: %{},
      last_stream_id: 0, buffer: <<>>, recv_ctx: recv_ctx, send_ctx: send_ctx,
      recv_settings: settings, send_settings: settings, window_size: 0}}
    end
  end

  def send(connection, %Frame{} = frame) do
    GenServer.call(connection, {:send, frame})
  end

  def close(pid), do: GenServer.call(pid, {:close})

  def handle_call({:send, frame}, from, %{socket: nil, uri: %URI{host: host,
  port: port}} = state) do
    hostname = String.to_charlist(host)
    ssl_options = @ssl_opts
    with {:ok, socket} <- :ssl.connect(hostname, port, ssl_options),
         :ok <- :ssl.send(socket, @preface) do
      handle_call({:send, %Frame{type: :settings, stream_id: 0,
      flags: %Settings.Flags{}, payload: %Settings.Payload{}}}, from,
      %{state | socket: socket})
      handle_call({:send, frame}, from, %{state | socket: socket})
    else
      error ->
        {:stop, :ssl.format_error(error), state}
    end
  end

  def handle_call({:send, frame}, _from, state) do
    case send_frame(state, frame) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}
      {:error, error} ->
        {:stop, error, state}
    end
  end

  def handle_call({:close}, _from, %{socket: socket} = state) do
    :ok = :ssl.close(socket)
    {:stop, :closed, state}
  end

  def handle_info({:ssl, _socket, data}, %{buffer: buffer} = state) do
    {state, frames} = buffer <> data
    |> parse_frames(state)

    state = frames
    |> Enum.reduce(state, fn frame, state -> receive_frame(state, frame) end)

    {:noreply, state}
  end

  def handle_info({:ssl_closed, _socket}, state) do
    {:stop, :closed, state}
  end

  def handle_info({:ssl_error, _socket, reason}, state) do
    {:stop, reason, state}
  end

  def handle_info(msg, state) do
    Logger.error "UNKNOWN MESSAGE: #{inspect msg}"
    {:noreply, state}
  end

  defp send_frame(%{socket: socket} = state, %Frame{stream_id: 0} = frame) do
    Logger.debug "STREAM 0 SEND #{inspect frame}"
    case :ssl.send(socket, Encoder.encode!(frame, [])) do
      :ok ->
        {:ok, state}
      error ->
        :ssl.format_error(error)
    end
  end

  defp send_frame(%{socket: socket, streams: streams, send_ctx: hpack}
  = state, %Frame{stream_id: id} = frame) do
    stream = Map.get(streams, id, Ankh.Stream.new(id))
    Logger.debug "STREAM #{id} SEND #{inspect frame}"
    {:ok, stream} = Ankh.Stream.send_frame(stream, frame)
    Logger.debug "STREAM #{id} IS #{inspect stream}"

    frame = case frame do
      %Frame{type: :headers, payload: %{header_block_fragment: headers}
      = payload} ->
        hbf = HPack.encode(headers, hpack)
        %{frame | payload: %{payload | header_block_fragment: hbf}}
      %Frame{type: :push_promise, payload: %{header_block_fragment: headers}
      = payload} ->
        hbf = HPack.encode(headers, hpack)
        %{frame | payload: %{payload | header_block_fragment: hbf}}
      _ ->
        frame
    end

    case :ssl.send(socket,  Encoder.encode!(frame, [])) do
      :ok ->
        {:ok, %{state | streams: Map.put(streams, id, stream)}}
      error ->
        :ssl.format_error(error)
    end
  end

  defp receive_frame(state, %Frame{stream_id: 0, type: :ping, length: 8,
  flags: %{ack: false}, payload: %{}} = frame) do
    Logger.debug "STREAM 0 RECEIVED #{inspect frame}"
    {:ok, state} = send_frame(state, %Frame{frame |
      flags: %Ping.Flags{ack: true}
    })
    state
  end

  defp receive_frame(%{last_stream_id: id} = state, %Frame{stream_id: 0,
  type: :ping,flags: %{ack: false}} = frame) do
    Logger.debug "STREAM 0 RECEIVED #{inspect frame}"
    {:ok, state} = send_frame(state, %Frame{
      type: :goaway, payload: %GoAway.Payload{
        last_stream_id: id, error_code: %Error{code: :frame_size_error}
      }
    })
    state
  end

  defp receive_frame(%{last_stream_id: id} = state,
  %Frame{length: 8, type: :ping, flags: %{ack: false}} = frame) do
    Logger.debug "STREAM 0 RECEIVED #{inspect frame}"
    {:ok, state} = send_frame(state, %Frame{
      type: :goaway, payload: %GoAway.Payload{
        last_stream_id: id, error_code: %Error{code: :protocol_error}
      }
    })
    state
  end

  defp receive_frame(%{hpack_send_ctx: table} = state,
  %Frame{stream_id: 0, type: :settings, flags: %{ack: false},
  payload: %{header_table_size: table_size} = payload} = frame)
  do
    Logger.debug "STREAM 0 RECEIVED #{inspect frame}"
    {:ok, state} = send_frame(state, %Frame{frame|
      flags: %Settings.Flags{ack: true}, payload: nil
    })
    :ok = HPack.Table.resize(table_size, table)
    %{state | send_settings: payload}
  end

  defp receive_frame(state, %Frame{stream_id: id, type: :window_update,
  payload: %{window_size_increment: increment}})
  when not is_integer(increment) or increment <= 0 do
    Logger.debug "STREAM #{id} ERROR window_size_increment #{increment}"
    {:ok, state} = send_frame(state, %Frame{
      type: :goaway, payload: %GoAway.Payload{
        last_stream_id: id, error_code: %Error{code: :protocol_error}
      }
    })
    state
  end

  defp receive_frame(state, %Frame{stream_id: 0, type: :window_update,
  payload: %{window_size_increment: increment}}) do
    Logger.debug "STREAM 0 window_size_increment #{increment}"
    %{state | window_size: state.window_size + increment}
  end

  defp receive_frame(state, %Frame{stream_id: id, type: :window_update,
  payload: %{window_size_increment: increment}}) do
    Logger.debug "STREAM #{id} window_size_increment #{increment}"
    stream = Map.get(state.streams, id)
    stream = %{stream | window_size: stream.window_size + increment}
    %{state | streams: Map.put(state.streams, id, stream)}
  end

  defp receive_frame(state, %Frame{stream_id: 0} = frame) do
    Logger.debug "STREAM 0 RECEIVED #{inspect frame}"
    state
  end

  defp receive_frame(%{streams: streams} = state, %Frame{stream_id: id} = frame)
  do
    stream = Map.get(streams, id)
    Logger.debug "STREAM #{id} RECEIVED #{inspect frame}"
    {:ok, stream} = Ankh.Stream.received_frame(stream, frame)
    Logger.debug "STREAM #{id} IS #{inspect stream}"
    %{state | streams: Map.put(streams, id, stream), last_stream_id: id}
  end

  defp receive_frame(state, _), do: state

  defp parse_frames(<<payload_length::24, _::binary>> = data, state)
  when @frame_header_size + payload_length > byte_size(data) do
    {%{state | buffer: data}, []}
  end

  defp parse_frames(<<payload_length::24, _::binary>> = data, state) do
    frame_size = @frame_header_size + payload_length
    frame_data = binary_part(data, 0, frame_size)
    rest_size = byte_size(data) - frame_size
    rest_data = binary_part(data, frame_size, rest_size)

    {state, frame} = %Frame{}
    |> Encoder.decode!(frame_data, [])
    |> decode_frame(state)

    {state, frames} = parse_frames(rest_data, state)
    {state, [frame | frames]}
  end

  defp parse_frames(_, state), do: {%{state | buffer: <<>>}, []}

  defp decode_frame(%Frame{stream_id: 0} = frame, state), do: {state, frame}

  defp decode_frame(%Frame{stream_id: id, type: :headers,
  flags: %{end_headers: false}, payload: payload} = frame,
  %{streams: streams} = state) do
    stream = Map.get(streams, id)
    stream = %{stream | hbf: stream.hbf <> payload.header_block_fragment}
    Logger.debug("STREAM #{id} RECEIVED PARTIAL HBF #{inspect payload.header_block_fragment}")
    {%{state | streams: Map.put(streams, id, stream)}, frame}
  end

  defp decode_frame(%Frame{stream_id: id, type: :push_promise,
  flags: %{end_headers: false}, payload: payload} = frame,
  %{streams: streams} = state) do
    stream = Map.get(streams, id)
    stream = %{stream | hbf: stream.hbf <> payload.header_block_fragment}
    Logger.debug("STREAM #{id} RECEIVED PARTIAL HBF #{inspect payload.header_block_fragment}")
    {%{state | streams: Map.put(streams, id, stream)}, frame}
  end

  defp decode_frame(%Frame{stream_id: id, type: :continuation,
  flags: %{end_headers: false}, payload: payload} = frame,
  %{streams: streams} = state) do
    stream = Map.get(streams, id)
    stream = %{stream | hbf: stream.hbf <> payload.header_block_fragment}
    Logger.debug("STREAM #{id} RECEIVED PARTIAL HBF #{inspect payload.header_block_fragment}")
    {%{state | streams: Map.put(streams, id, stream)}, frame}
  end

  defp decode_frame(%Frame{stream_id: id, type: :headers,
  flags: %{end_headers: true}, payload: payload} = frame,
  %{streams: streams, recv_ctx: hpack, target: target} = state) do
    stream = Map.get(streams, id)
    headers = HPack.decode(stream.hbf <> payload.header_block_fragment, hpack)
    Logger.debug("STREAM #{id} RECEIVED HEADERS #{inspect headers}")
    Process.send(target, {:ankh, :headers, id, headers}, [])
    stream = %{stream | hbf: <<>>}
    {%{state | streams: Map.put(streams, id, stream)}, frame}
  end

  defp decode_frame(%Frame{stream_id: id, type: :push_promise,
  flags: %{end_headers: true}, payload: payload} = frame,
  %{streams: streams, recv_ctx: hpack, target: target} = state) do
    stream = Map.get(streams, id)
    headers = HPack.decode(stream.hbf <> payload.header_block_fragment, hpack)
    Logger.debug("STREAM #{id} RECEIVED HEADERS #{inspect headers}")
    Process.send(target, {:ankh, :headers, id, headers}, [])
    stream = %{stream | hbf: <<>>}
    {%{state | streams: Map.put(streams, id, stream)}, frame}
  end

  defp decode_frame(%Frame{stream_id: id, type: :continuation,
  flags: %{end_headers: true}, payload: payload} = frame,
  %{streams: streams, recv_ctx: hpack, target: target} = state) do
    stream = Map.get(streams, id)
    headers = HPack.decode(stream.hbf <> payload.header_block_fragment, hpack)
    Logger.debug("STREAM #{id} RECEIVED HEADERS #{inspect headers}")
    Process.send(target, {:ankh, :headers, id, headers}, [])
    stream = %{stream | hbf: <<>>}
    {%{state | streams: Map.put(streams, id, stream)}, frame}
  end

  defp decode_frame(%Frame{stream_id: id, type: :data,
  flags: %{end_stream: false}, payload: payload} = frame,
  %{streams: streams, target: target, mode: mode} = state) do
    stream = Map.get(streams, id)
    stream = %{stream | data: stream.data <> payload.data}
    case mode do
      :stream ->
        Process.send(target, {:ankh, :stream_data, id, payload.data}, [])
      _ ->
      Logger.debug("Full mode, not sending partial data")
    end
    {%{state | streams: Map.put(streams, id, stream)}, frame}
  end

  defp decode_frame(%Frame{stream_id: id, type: :data,
  flags: %{end_stream: true}, payload: payload} = frame,
  %{streams: streams, target: target, mode: mode} = state) do
    stream = Map.get(streams, id)
    data = stream.data <> payload.data
    Logger.debug("STREAM #{id} RECEIVED DATA #{data} #{byte_size data}")
    case mode do
      :full ->
        Process.send(target, {:ankh, :data, id, data}, [])
      _ ->
        Logger.debug("Streaming mode, not sending reassembled hbf")
    end
    stream = %{stream | data: <<>>}
    {%{state | streams: Map.put(streams, id, stream)}, frame}
  end

  defp decode_frame(frame, state), do: {state, frame}
end