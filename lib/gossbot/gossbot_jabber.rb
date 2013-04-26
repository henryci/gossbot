require 'xmpp4r/client'
include Jabber

class GossbotJabber
  def connect(config)
    @jid      = JID.new(config['account'])
    @password = config['password']
    @client   = Client.new(@jid)
    @client.connect
    @client.auth(@password)
    @client.send(Presence.new.set_status('I am GossBot'))
    out "Connected as: #{config['account']}."
  end

  def send_msg(to, type, body)
    out "jabber send_msg to: #{to}, type: #{type}, body: #{body}"
    m      = Message.new(to, body)
    m.type = type
    @client.send(m)
  end

  def send_chat(to, body)
    send_msg(to, :chat, body)
  end

  def respond(received_msg, response_msg_body)
    send_msg(received_msg.from, received_msg.type, response_msg_body)
  end

  def add_typed_message_callback(type, &block)
    @client.add_message_callback do |msg|
      if type == msg.type
        block.call(msg)
      end
    end
  end

  def add_chat_callback(&block)
    self.add_typed_message_callback(:chat, &block)
  end

  def add_error_callback(&block)
    self.add_typed_message_callback(:error, &block)
  end

  def close
    if @client
      @client.close
      @client = nil
    end
  end

  def wait
    mainthread = Thread.current
    Thread.stop
    @client.close
  end
end