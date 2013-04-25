#!/usr/bin/env ruby

# I am GossBot!
# GossBot is a xmpp chat bot designed to live in a PartyChat (http://partychapp.appspot.com/) room
# GossBot reinvites anybody who has been kicked (and kicks the kicker), answers questions, and occassionally speaks

require 'rubygems'
require 'bundler/setup'
require 'time'
require 'xmpp4r/client'
require 'set'
require 'net/http'
require 'omegle'
require 'yaml'
require 'thread'
include Jabber

Thread.abort_on_exception=true
DEBUG_OUTPUT = {:enabled => false}

class OmegleChat
  def initialize(&callback)
    out "entering omegle chat..."
    @callback         = callback
    @omegle           = Omegle.new
    @omegle.start
    spawn_receive_loop()
  end

  def spawn_receive_loop
    @receive_thread = Thread.new do
      @omegle.listen do |type, data|
        out "omegle listen received type: #{type}, data: #{data}"
        case type
          when 'gotMessage'
            out "omegle message, sending to callback: #{data}"
            send_to_callback(:message, data)
          when 'strangerDisconnected'
            out "omegle disconnected"
            send_to_callback(:disconnected)
        end
      end
      out "omegle listen loop terminated"
    end
  end

  def say(str)
    out "sending to omegle chat #{str}"
    begin
      @omegle.send(str)
    rescue => e
      out "exception sending to omegle, #{e.class}, #{e.message}"
    end
  end

  def send_to_callback(type, data = nil)
    @callback.call(self, type, data)
  end

  def connected?
    @omegle && @omegle.connected?
  end

  def close
    if @omegle
      @omegle.disconnect rescue nil
      @omegle = nil
    end
  end

  def closed?
    nil == @receive_thread && nil == @omegle
  end
end

# ask a question of some random person on Omegle
def ask_omegle(question, timeout)
  answer = false
  msg    = question
  t = Thread.new do
    Omegle.start() do |omegle|
      out "asking omegle '#{msg}' ..."
      omegle.send(msg)
      omegle.listen do |type, data|
        out "type: #{type}, data: #{data}"
        case type
        when 'gotMessage'
          omegle.send('Thanks!')
          omegle.disconnect
          out "got answer from omegle inside thread: #{data}"
          answer = data
        end
      end
    end
  end
  out "waiting #{timeout} seconds for answer from omegle"
  if t.join(timeout)
    out "omegle thread completed"
  else
    t.kill
    out "omegle thread timed out"
  end
  out "omegle answer: #{answer.inspect}"
  (answer && answer !~ /^\s*$/) ? answer : false
end

# Responds to the sender of a message with a new message
def respond(m, cl, msg)
  m2 = Message.new(m.from, msg)
  m2.type = m.type
  cl.send(m2)
end

# output to the local console for debugging / information
def out(msg)
  puts "#{Time.now.strftime("%Y-%m-%d %H:%M:%S")} #{msg}" if DEBUG_OUTPUT[:enabled]
end

# establishes and returns a jabber connection (throws an error on failure)
def connect(config)
  myJID = JID.new(config["account"])
  myPassword = config["password"]
  cl = Client.new(myJID)
  cl.connect
  cl.auth(myPassword)
  cl.send(Presence.new.set_status('I am GossBot'))
  out "Connected as: #{myJID.strip.to_s}."
  return cl
end

# update the mapping of users to email addresses on a new /list
def listing_refresh(state, body)
  lines = body.split("\n")
  state[:user_map] = {}
  lines.each do |line|

    # /list results can look like:
    # * alias (email)
    # * alias (email) state
    # * alias (email) (state)
    if(match = /^\* (.*) \((.*)\) \(.*\)/.match(line))
      state[:user_map][match[1]] = match[2]
    elsif (match = /^\* (.*) \((.*)\)/.match(line))
      state[:user_map][match[1]] = match[2]
    end
  end
end

# an emote sent to the chatroom
def chatroom_emote(msg, cl, state, config)
  body = msg.body.to_s
  body = body[1..body.length - 2]

  # Being invited back to a chat room: '_henry invited thisbot@gmail.com_'
  if(match = /^(.*) invited you to '#{config["room_name"]}'/.match(body))
    out("coming back after being kicked")
    respond(msg, cl, "hello again")
    return
  end

  # handle users being kicked
  if (match = /(\S*) kicked (\S*)/.match(body))
    out("User was kicked. match: #{match.inspect}")
    kick_user(match[1], msg, cl, state, config)
    invite_user(match[2], msg, cl, state)
  end
end

def kick_user(user, msg, cl, state, config)
  return if (config["invincible_aliases"].index(user) != nil)

  # determine if this is a username or email
  if (user.include?("@"))
    user_email = user
  else
    user_email = state[:user_map][user]
  end

  # if we have the user email, prefer that. otherwise just kick the username
  if (user_email)
    respond(msg, cl, "/kick #{user_email}")
    respond(msg, cl, "Email: #{user_email}")
    state[:last_kicked_email] = user_email
  else
    respond(msg, cl, "/kick #{user}")
    state[:last_kicked_email] = nil
  end
end

def invite_user(user, msg, cl, state)
  # invite the email address directly, if provided. otherwise attempt a lookup
  if (user.include?("@"))
    respond(msg, cl, "/invite #{user}")
  else
    respond(msg, cl, "/invite #{state[:user_map][user]}") if state[:user_map][user]
  end
end

def regular_user_chatroom_message(msg, cl, state, config)
  return if !config["do_speak"] # some bots should be seen and not heard
  body = msg.body.to_s

  if(match = /\[(\S*)\] (.*)/.match(body))
    person = match[1]
    stmt = match[2]

    # attempt to reinvite the last user kicked
    if (stmt == "reinvite" && state[:last_kicked_email])
      invite_user(state[:last_kicked_email], msg, cl, state)
      return
    end

    # attempt to reinvite a user
    if (match = /^reinvite (.*)/.match(stmt))
      if(match.length > 0)
        invite_user(match[1], msg, cl, state)
        return
      end
    end

    # vote to kick a user
    if (match = /^kick (.*)/.match(stmt))
      if(match.length > 0 && state[:user_map])
        kick_candidate_email = state[:user_map][match[1]]
        voter_email = state[:user_map][person]
        if (kick_candidate_email && voter_email)
          (state[:kick_votes][kick_candidate_email] ||= Set.new).add(voter_email)
          vote_count = state[:kick_votes][kick_candidate_email].size
          if(vote_count >= config["required_kick_votes"])
            kick_user(kick_candidate_email, msg, cl, state, config)
          else
            respond(msg, cl, "#{match[1]} needs #{config["required_kick_votes"] - vote_count} more vote(s) to be kicked.")
          end
        end
      end
      return
    end

    # remove a kick vote for a user
    if (match = /^unkick (.*)/.match(stmt))
      if (match.length > 0 && state[:user_map])
        kick_candidate_email = state[:user_map][match[1]]
        voter_email = state[:user_map][person]
        if (kick_candidate_email && voter_email)
          (state[:kick_votes][kick_candidate_email] ||= Set.new).delete(voter_email)
          vote_count = state[:kick_votes][kick_candidate_email].size
          respond(msg, cl, "#{match[1]} needs #{config["required_kick_votes"] - vote_count} more votes to be kicked.")
        end
      end
      return
    end

    # identify users
    if (match = /^identify (.*)/.match(stmt))
      if(match.length > 0 && state[:user_map] && state[:user_map][match[1]])
        respond(msg, cl, "#{match[1]} is #{state[:user_map][match[1]]}")
        return
      end
    end

    # summon Omegler
    if (stmt =~ /^\s*O(megle)?\s+O(megle)?\s+O(megle)?\s*$/i)
      current_chat = state[:omegle_chat]
      if current_chat && !current_chat.closed?
        respond(msg, cl, "Kicking previous omegler!")
        current_chat.close()
      end
      respond(msg, cl, "Summoning omegler!")
      state[:omegle_chat] = OmegleChat.new do |chat, type, data|
        case type
        when :message
          out "omegle message seen callback"
          respond(msg, cl, "Omegler says: #{data}")
        when :disconnected
          out "omegle disconnect seen callback"
          chat.close()
          state.delete(:omegle_chat)
          respond(msg, cl, "Omegler vanished.")
        end
      end
      respond(msg, cl, 'Omegler summoned. See commands with "omegle help".')
      return
    end

    # Say something to Omegler
    if (match = /^\s*O\s*:\s*(.*)$/i.match(stmt))
      omegle_chat = state[:omegle_chat]
      if omegle_chat
        something = match[1]
        omegle_chat.say(something)
      else
        respond(msg, cl, "No omegler present.")
      end
      return
    end

    # Banish Omegler
    if (match = /^\s*banish\s+o(megle(r)?)?\s*$/i.match(stmt))
      respond(msg, cl, "Banishing omegler!")
      state[:omegle_chat].close() if state[:omegle_chat]
      state.delete(:omegle_chat)
      return
    end

    # Get Omegle chat status
    if (match = /^\s*omegle\s+status\s*$/i.match(stmt))
      chat         = state[:omegle_chat]
      is_connected = chat ? chat.connected? : false
      respond(msg, cl, "Omegle status: state? #{!!chat}, connected? #{is_connected}")
      return
    end

    # Get Omegle help
    if (match = /^\s*omegle\s+help\s*$/i.match(stmt))
      help = [
        'Summon omegler by saying "o o o".',
        'Banish omegler by saying "banish omegler".',
        'Get connection status by saying "omegle status".'
      ].join("\n")
      respond(msg, cl, help)
      return
    end

    # ask a question of Omegle
    if (match = /^\s*Omegle\s*[:,]\s*(.*)$/i.match(stmt))
      question = match[1]
      answer   = false
      attempt  = 0
      timeout  = config['ask_omegle']['timeout']
      retry_n  = config['ask_omegle']['retry']
      while !answer && attempt < retry_n
        attempt += 1
        answer   = ask_omegle(question, timeout)
      end
      respond(msg, cl, answer)
      return
    end

    # answer who is questions
    if (match = /^who (.*)/i.match(stmt))
      person = config["people"][stmt.hash % (config["people"].length) +1]
      respond(msg, cl, person)
      return
    end

    # answer "is" questions randomly
    if (match = /is(.*)\?$/i.match(stmt))
      respond(msg, cl, stmt.hash % 2 == 0 ? "yes" : "no")
      return
    end

     # If someone says [word]bomb search for [word] on Google image
     # search and post the first result to the room. eg: pugbomb
     if /\w+bomb/.match(body)
       q = /(\w+)bomb/.match(body)[1]
       uri = 'http://www.google.com/search?num=1&hl=en&safe=off&site=imghp&tbm=isch&source=hp&biw=1060&bih=669&q=' + q
       response = Net::HTTP.get_response(URI.parse(uri)) # => #<Net::HTTPOK 200 OK readbody=true>
       arr = response.body.scan(/imgurl=([^&,]+)/)
       if arr.length < 1
         respond(msg, cl, "No results for " + q)
       elsif
         respond(msg, cl, arr[0][0])
       end
     end

    # randomly emote or say things
    if rand(config["speak_likelyhood"]) == 1
      respond(msg, cl, "/me #{config["emotes"][rand(config["emotes"].length)]} #{person}")
    elsif(rand(config["speak_likelyhood"]) == 1)
      respond(msg, cl, "#{config["exclamations"][rand(config["exclamations"].length)]}")
    end
  end
end

# called once for every message sent to the chatroom
def chatroom_message(msg, cl, state, config)
  body = msg.body.to_s

  # update room status every config["msgs_until_refresh"] messages
  # Use a countdown and not mod to avoid skips happenning if multiple messages come at once
  if(state[:time_until_list] <= 0)
    respond(msg, cl, "/list")
    state[:time_until_list] = config["msgs_until_refresh"]
  else
    state[:time_until_list] -= 1
  end

  # redo the /list whenever anybody changes their name or joins the room
  if(/^\'(.*)\' is now known as \'(.*)\'/.match(body) ||
     /^.* has joined the channel with the alias '.*'/.match(body) )
       out("sending /list because of user change")
       respond(msg, cl, "/list")
       return
  end

  # handle /list result when it comes in
  if(/^Listing members of '#{config["room_name"]}'\n/.match(body))
    out("received a room listing.")
    listing_refresh(state, body)
    return
   end

  # messages starting and ending with '_' are config["emotes"]
  if body[0].chr == '_' && body[body.length - 1].chr == '_'
    chatroom_emote(msg, cl, state, config)
    return
  end

  # getting here means the message was a regular comment from a user
  regular_user_chatroom_message(msg, cl, state, config)
end

# called once for every message sent directly
def personal_message(msg, cl)
  respond(msg, cl, "Hi. Your message was: #{msg.inspect}")
  respond(msg, cl, "Body: #{msg.body.to_s}")
end

def main

  if ARGV.length < 1
    puts "Usage: ./gossbot <config_file>"
    exit
  end

  config = YAML.load_file(ARGV[0])
  DEBUG_OUTPUT[:enabled] = config['debug']
  out("RUBY_PLATFORM: #{RUBY_PLATFORM}")
  out("Gossbot launched with config: #{config.inspect}")

  state = {}
  state[:time_until_list] = 0
  state[:user_map] = {}
  state[:kick_votes] = {}

  cl = connect(config)

  # what to do when a message is received
  cl.add_message_callback do |msg|
    out "message: #{msg.inspect}" # this won't output the message body
    if msg.type == :error
      out("ERROR: #{msg.inspect}")
    elsif(msg.from.to_s.include?(config["room_name"]))
      chatroom_message(msg, cl, state, config)
    else
      personal_message(msg, cl)
    end
  end

  # sleep and let jabber thread wait for input
  mainthread = Thread.current
  Thread.stop
  cl.close
end

main

