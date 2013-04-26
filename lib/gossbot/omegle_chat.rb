require 'omegle'

class Omegle
  def stopped_typing
    ret = req('stoppedTyping', "id=#{@chat_id}")
    parse_response(ret)
  end
end

class OmegleChat
  attr_reader :receive_thread, :chat_id
  
  def initialize()
    @chat_id = (1..8).map { "%x" % rand(16)}.join
    debug_out "entering omegle chat..."
    @omegle  = Omegle.new
    @omegle.start
    @stranger_disconnected = false
    debug_out "entered omegle chat with id #{@omegle.id}"
  end

  def spawn_listen_loop(&callback)
    @receive_thread = Thread.new do
      @omegle.listen do |type, data|
        debug_out "omegle:#{@omegle.id} listen received type: #{type}, data: #{data}"
        case type
          when 'connected'
            debug_out "omegle connected"
            callback.call(self, :connected)
          when 'gotMessage'
            debug_out "omegle message, sending to callback: '#{data}'"
            callback.call(self, :message, data)
          when 'strangerDisconnected'
            @stranger_disconnected = true
            debug_out "omegle disconnected"
            callback.call(self, :disconnected)
          when 'typing'
            debug_out "omegler typing"
            callback.call(self, :typing)
          when 'stoppedTyping'
            debug_out "omegler stopped typing"
            callback.call(self, :stopped_typing)
        end
      end
      debug_out "omegle listen loop terminated"
    end
    self
  end

  def debug_out(str)
    out "omegle:#{@chat_id} #{str}"
  end

  def say(str)
    debug_out "sending to omegle chat #{str}"
    begin
      @omegle.send(str)
    rescue => e
      debug_out "exception sending to omegle, #{e.class}, #{e.message}"
    end
  end

  def typing
    debug_out "sending typing signal"
    @omegle.typing
  end

  def stopped_typing
    debug_out "sending stopped typing signal"
    @omegle.stopped_typing
  end

  def connected?
    @omegle && @omegle.connected?
  end

  def stranger_disconnected?
    @stranger_disconnected
  end

  def close
    if @omegle
      @omegle.disconnect rescue nil
    end
  end

  def closed?
    nil == @omegle || !@omegle.connected?
  end
end