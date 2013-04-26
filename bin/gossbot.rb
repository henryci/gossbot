#!/usr/bin/env ruby

# I am GossBot!
# GossBot is a xmpp chat bot designed to live in a PartyChat (http://partychapp.appspot.com/) room
# GossBot reinvites anybody who has been kicked (and kicks the kicker), answers questions, and occassionally speaks

$:.unshift File.join(File.dirname(__FILE__), '..', 'lib')

require 'rubygems'
require 'bundler/setup'
require 'gossbot'
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

# output to the local console for debugging / information
def out(msg)
  puts "#{Time.now.strftime("%Y-%m-%d %H:%M:%S")} #{msg}" if DEBUG_OUTPUT[:enabled]
end

class Gossbot
  def initialize(config)
    @config           = config
    @time_until_list  = 0
    @user_map         = {}
    @kick_votes       = {}
    @jabber           = GossbotJabber.new
  end

  def go
    @jabber.connect(@config)

    # Set callbacks
    @jabber.add_error_callback do |msg|
      out("ERROR: #{msg.inspect}")
    end

    @jabber.add_chat_callback do |msg|
      begin
        if(msg.from.to_s.include?(@config["room_name"]))
          chatroom_message(msg)
        else
          personal_message(msg)
        end
      rescue => e
        out "error in chat callback: #{e.class}, #{e.message}"
        e.backtrace.each do |line|
          out line
        end
      end
    end

    @jabber.wait
  end

  def respond(received_msg, body)
    @jabber.respond(received_msg, body)
  end

  # called once for every message sent to the chatroom
  def chatroom_message(msg)
    body = msg.body.to_s
    out("received chatroom message #{body}")

    # update room status every config["msgs_until_refresh"] messages
    # Use a countdown and not mod to avoid skips happenning if multiple messages come at once
    if(@time_until_list <= 0)
      respond(msg, "/list")
      @time_until_list = @config["msgs_until_refresh"]
    else
      @time_until_list -= 1
    end

    # redo the /list whenever anybody changes their name or joins the room
    if(/^\'(.*)\' is now known as \'(.*)\'/.match(body) ||
       /^.* has joined the channel with the alias '.*'/.match(body) )
         out("sending /list because of user change")
         respond(msg, "/list")
         return
    end

    # handle /list result when it comes in
    if(/^Listing members of '#{@config["room_name"]}'\n/.match(body))
      out("received a room listing.")
      listing_refresh(body)
      return
     end

    # messages starting and ending with '_' are config["emotes"]
    if body[0].chr == '_' && body[body.length - 1].chr == '_'
      chatroom_emote(msg)
      return
    end

    # getting here means the message was a regular comment from a user
    regular_user_chatroom_message(msg)
  end


  # update the mapping of users to email addresses on a new /list
  def listing_refresh(body)
    lines = body.split("\n")
    @user_map = {}
    lines.each do |line|

      # /list results can look like:
      # * alias (email)
      # * alias (email) state
      # * alias (email) (state)
      if(match = /^\* (.*) \((.*)\) \(.*\)/.match(line))
        @user_map[match[1]] = match[2]
      elsif (match = /^\* (.*) \((.*)\)/.match(line))
        @user_map[match[1]] = match[2]
      end
    end
  end

  # an emote sent to the chatroom
  def chatroom_emote(msg)
    body = msg.body.to_s
    body = body[1..body.length - 2]

    # Being invited back to a chat room: '_henry invited thisbot@gmail.com_'
    if(match = /^(.*) invited you to '#{@config["room_name"]}'/.match(body))
      out("coming back after being kicked")
      respond(msg, "hello again")
      return
    end

    # handle users being kicked
    if (match = /(\S*) kicked (\S*)/.match(body))
      out("User was kicked. match: #{match.inspect}")
      kick_user(match[1], msg)
      invite_user(match[2], msg)
    end
  end

  def kick_user(user, msg)
    return if (@config["invincible_aliases"].index(user) != nil)

    # determine if this is a username or email
    if (user.include?("@"))
      user_email = user
    else
      user_email = @user_map[user]
    end

    # if we have the user email, prefer that. otherwise just kick the username
    if (user_email)
      respond(msg, "/kick #{user_email}")
      respond(msg, "Email: #{user_email}")
      @last_kicked_email = user_email
    else
      respond(msg, "/kick #{user}")
      @last_kicked_email = nil
    end
  end

  def invite_user(user, msg)
    # invite the email address directly, if provided. otherwise attempt a lookup
    if (user.include?("@"))
      respond(msg, "/invite #{user}")
    else
      respond(msg, "/invite #{@user_map[user]}") if @user_map[user]
    end
  end

  def regular_user_chatroom_message(msg)
    return if !@config["do_speak"] # some bots should be seen and not heard
    body = msg.body.to_s

    if(match = /\[(\S*)\] (.*)/.match(body))
      person = match[1]
      stmt = match[2]

      # attempt to reinvite the last user kicked
      if (stmt == "reinvite" && @last_kicked_email)
        invite_user(@last_kicked_email, msg)
        return
      end

      # attempt to reinvite a user
      if (match = /^reinvite (.*)/.match(stmt))
        if(match.length > 0)
          invite_user(match[1], msg)
          return
        end
      end

      # vote to kick a user
      if (match = /^kick (.*)/.match(stmt))
        if(match.length > 0 && @user_map)
          kick_candidate_email = @user_map[match[1]]
          voter_email = @user_map[person]
          if (kick_candidate_email && voter_email)
            (@kick_votes[kick_candidate_email] ||= Set.new).add(voter_email)
            vote_count = @kick_votes[kick_candidate_email].size
            if(vote_count >= @config["required_kick_votes"])
              kick_user(kick_candidate_email, msg)
            else
              respond(msg, "#{match[1]} needs #{@config["required_kick_votes"] - vote_count} more vote(s) to be kicked.")
            end
          end
        end
        return
      end

      # remove a kick vote for a user
      if (match = /^unkick (.*)/.match(stmt))
        if (match.length > 0 && @user_map)
          kick_candidate_email = @user_map[match[1]]
          voter_email = @user_map[person]
          if (kick_candidate_email && voter_email)
            (@kick_votes[kick_candidate_email] ||= Set.new).delete(voter_email)
            vote_count = @kick_votes[kick_candidate_email].size
            respond(msg, "#{match[1]} needs #{@config["required_kick_votes"] - vote_count} more votes to be kicked.")
          end
        end
        return
      end

      # identify users
      if (match = /^identify (.*)/.match(stmt))
        if(match.length > 0 && @user_map && @user_map[match[1]])
          respond(msg, "#{match[1]} is #{@user_map[match[1]]}")
          return
        end
      end

      # summon Omegler
      if (stmt =~ /^\s*O(megle)?\s+O(megle)?\s+O(megle)?\s*$/i)
        current_chat = @omegle_chat
        if current_chat && !current_chat.closed?
          respond(msg, "Kicking previous omegler!")
          current_chat.close()
        end
        respond(msg, "Summoning omegler!")
        @omegle_chat = OmegleChat.new
        @omegle_chat.spawn_listen_loop do |chat, type, data|
          case type
          when :message
            out "omegle message seen callback"
            respond(msg, "Omegler says: #{data}")
          when :disconnected
            out "omegle disconnect seen callback"
            chat.close()
            @omegle_chat = nil
            respond(msg, "Omegler vanished.")
          end
        end
        respond(msg, 'Omegler summoned. See commands with "omegle help".')
        return
      end

      # Say something to Omegler
      if (match = /^\s*O\s*:\s*(.*)$/i.match(stmt))
        omegle_chat = @omegle_chat
        if omegle_chat
          something = match[1]
          omegle_chat.say(something)
        else
          respond(msg, "No omegler present.")
        end
        return
      end

      # Banish Omegler
      if (match = /^\s*banish\s+o(megle(r)?)?\s*$/i.match(stmt))
        respond(msg, "Banishing omegler!")
        @omegle_chat.close() if @omegle_chat
        @omegle_chat = nil
        return
      end

      # Get Omegle chat status
      if (match = /^\s*omegle\s+status\s*$/i.match(stmt))
        status = [
          "Omegle status:",
          @omegle_chat ?
            "o o o connected? #{@omegle_chat.connected?}" :
            "o o o not present",
          @o2o ? [
            "o2o red:0:#{@o2o[0].chat_id} connected? #{@o2o[0].connected?}, stranger_disconnected? #{@o2o[0].stranger_disconnected?}",
            "o2o blue:1:#{@o2o[1].chat_id} connected? #{@o2o[1].connected?}, stranger_disconnected? #{@o2o[1].stranger_disconnected?}"
          ] : 'o2o not present'
        ].flatten.compact.join("\n")
        respond(msg, status)
        return
      end

      # Get Omegle help
      if (match = /^\s*omegle\s+help\s*$/i.match(stmt))
        help = [
          'Summon omegler by saying "o o o".',
          'Banish omegler by saying "banish omegler".',
          'Get connection status by saying "omegle status".'
        ].join("\n")
        respond(msg, help)
        return
      end

      # man in the middle two omeglers
      if (match = /^\s*o2o\s*$/i.match(stmt))
        if @o2o
          @o2o.each {|o| o.close()}
        end
        @o2o = [OmegleChat.new, OmegleChat.new]

        listen_loop = lambda do |this_id, this_chat, other_chat, type, data|
          this_name = (0 == this_id) ? 'red' : 'blue'
          case type
          when :connected
            respond(msg, "#{this_name} connected")
          when :message
            respond(msg, "#{this_name} says: #{data}")
            other_chat.say(data)
          when :typing
            other_chat.typing
          when :stopped_typing
            other_chat.stopped_typing
          when :disconnected
            respond(msg, "#{this_name}:#{this_id}:#{this_chat.chat_id} vanished")
            #this_chat.close
          end
        end

        @o2o.each_with_index do |o, i|
          o.spawn_listen_loop do |chat, type, data|
            listen_loop.call(i, o, @o2o[(i + 1) % 2], type, data)
          end
        end
        return
      end

      # Say something to o2o omegler
      if (match = /^\s*(red|blue)\s*:\s*(.*)$/i.match(stmt))
        color   = match[1]
        this_i  = ('red' == color) ? 0 : 1
        other_i = (this_i + 1) % 2
        body    = match[2]
        other   = @o2o && @o2o[other_i]
        if other && other.connected?
          other.say(body)
          respond(msg, "#{color} puppets: #{body}")
        else
          respond(msg, "#{color} not present.")
        end
        return
      end

      # ask a question of Omegle
      if (match = /^\s*Omegle\s*[:,]\s*(.*)$/i.match(stmt))
        question = match[1]
        answer   = false
        attempt  = 0
        timeout  = @config['ask_omegle']['timeout']
        retry_n  = @config['ask_omegle']['retry']
        while !answer && attempt < retry_n
          chat = OmegleChat.new
          chat.spawn_listen_loop do |chat, type, data|
            case type
            when :message
              if data && data !~ /^\s*$/
                answer = data
              end
            when :disconnected
              chat.close()
            end
          end
          chat.say(question)
          chat.receive_thread.join(timeout)
          attempt += 1
        end
        respond(msg, answer ? answer : "Sorry, no answer.")
        return
      end

      # answer who is questions
      if (match = /^who (.*)/i.match(stmt))
        person = @config["people"][stmt.hash % (@config["people"].length) +1]
        respond(msg, person)
        return
      end

      # answer "is" questions randomly
      if (match = /is(.*)\?$/i.match(stmt))
        respond(msg, stmt.hash % 2 == 0 ? "yes" : "no")
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
          respond(msg, "No results for " + q)
        elsif
          respond(msg, arr[0][0])
        end
      end

      # randomly emote or say things
      if rand(@config["speak_likelyhood"]) == 1
        respond(msg, "/me #{@config["emotes"][rand(@config["emotes"].length)]} #{person}")
      elsif(rand(@config["speak_likelyhood"]) == 1)
        respond(msg, "#{@config["exclamations"][rand(@config["exclamations"].length)]}")
      end
    end
  end
  # called once for every message sent directly
  def personal_message(msg)
    respond(msg, "Hi. Your message was: #{msg.inspect}")
    respond(msg, "Body: #{msg.body.to_s}")
  end
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

  bot = Gossbot.new(config)
  bot.go
end

if __FILE__ == $0
  main()
end

