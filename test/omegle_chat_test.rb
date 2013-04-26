require File.join(File.dirname(__FILE__), 'test_helper')

HIDDEN_SPACE = "\342\200\213"
UNIQUE_STR   = "what the heck is going on here my home dawg?"

class TestAdd < Test::Unit::TestCase
  def test_add
    assert_equal(1, 1)
  end

  def test_omegle
    chat = OmegleChat.new.spawn_listen_loop do |chat, type, data|

    end
    chat.say("hello")
    chat.close
  end

  def test_collision
    chat1 = OmegleChat.new.spawn_listen_loop do |chat, type, data|
      case type
      when :message
        puts "chat 1 received #{data.inspect}"
        chat.close
      end
    end
    sleep(0.5)
    chat2 = OmegleChat.new.spawn_listen_loop do |chat, type, data|
      case type
      when :message
        puts "chat 2 received #{data.inspect}"
        chat.close
      end
    end
    chat1.say(UNIQUE_STR)
    chat2.say(UNIQUE_STR)
    chat1.receive_thread.join(20)
    chat2.receive_thread.join(20)
  end
end
