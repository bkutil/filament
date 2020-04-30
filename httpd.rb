#!/usr/bin/env ruby
#  Dependencies:
#
#  conf.gem :github => 'Asmod4n/mruby-phr'
#  conf.gem :core => 'mruby-io'
#  conf.gem :core => 'mruby-socket'
#  conf.gem :github => 'iij/mruby-env'

if RUBY_ENGINE != "mruby"
  require 'socket'
  require 'byebug'
  require 'pico_http_parser'
end

module Filament
  class Reactor
    def initialize
      @handlers = Hash.new { |h, k| h[k] = {} }
      @demuxer = Demuxer.new(self)
    end

    def register(handle, event, handler)
      @handlers[handle][event] = handler
      @demuxer.add(handle)
    end

    def deregister(handle)
      @demuxer.remove(handle) 
      @handlers.delete(handle)
    end

    def notify(handle, event)
      # The client might have deregistered on read and we'd still get a
      # notify from writeable.
      return unless @handlers[handle][event]

      @handlers[handle][event].call(self, event, handle)
    end

    def run
      @demuxer.run
    end
  end

  class Demuxer
    def initialize(dispatcher)
      @dispatcher = dispatcher
      @readers = []
      @writers = []
    end

    def add(handle)
      @readers << handle unless @readers.include?(handle)
      @writers << handle unless @writers.include?(handle)
    end

    def remove(handle)
      @readers.delete(handle)
      @writers.delete(handle)
    end

    def run
      loop do
        readable, writable = IO.select(@readers, @writers)

        readable.each do |handle|
          @dispatcher.notify(handle, :read)
        end

        writable.each do |handle|
          @dispatcher.notify(handle, :write)
        end
      end
    end
  end

  class FiberHandler
    attr_reader :context

    def initialize(context = {})
      @context = context
      @handler = handler
    end

    def call(reactor, event, handle)
      @handler.resume(reactor, event, handle)
    end

    def handler
      Fiber.new do |reactor, event, handle|
        loop do
          run(reactor, event, handle) || break

          reactor, event, handle = Fiber.yield
        end
      end
    end
    
    # Returns false if should break the handler loop, true otherwise (catch is
    # not available in mruby and exceptions might be too heavy)
    def run(reactor, event, handle)
      raise "Override me"
    end
  end

  class RequestHandler < FiberHandler
    def run(reactor, event, handle)
      case event
      when :read
        chunk = read_request(context, handle)
        if chunk.nil?
          # puts "Client #{socket} gone on read"
          reactor.notify(handle, :disconnect)
          return false
        else
          process_request(context, chunk)
        end
      when :write
        if read_done?(context)
          run_app(context, handle)
          write_response(context, handle)
          # puts "Notifying server about client #{socket} disconnect"
          reactor.notify(handle, :disconnect)
          return false
        end
      end

      true
    end

    def read_request(context, socket)
      socket.gets(context[:content_length] ? context[:content_length] : "\r\n")
    end

    def read_done?(context)
      case context[:method]
      when "GET"
        true
      when "POST"
        context[:request_buffer].bytesize == context[:content_length] 
      else
        false
      end
    end

    def process_request(context, chunk)
      context[:request_buffer] ||= ""
      context[:request_buffer] += chunk
      if chunk == "\r\n" || chunk == "\n"
        consume_headers(context)
      end
    end

    def write_response(context, socket)
      ret = socket.write context[:response_buffer]
      if ret.nil? || ret < 0
	      # puts "Client is gone on write"
      else
	      socket.flush
      end
    end

    def run_app(context, socket)
      env = rack_env(socket, context[:request_buffer]) 
      status, headers, body = context[:app].call(env)
      context[:response_buffer] = Http::Response.new(status, headers, body).to_s
    end

    module Http
      class Response
        def initialize(status, headers, body)
          @status = "HTTP/1.1 #{status}"
          @body = body.join
          @headers = serialize_headers(headers.merge(content_length))
        end

        def headers
          "#{@status}\r\n#{@headers}\r\n"
        end

        def body
          @body
        end

        def to_s
          "#{headers}#{body}"
        end

        private

        def content_length
          if @body.empty?
            {}
          else
            { "Content-Length" => @body.bytesize.to_s }
          end
        end

        def serialize_headers(headers)
          head = ""

          headers.each do |name, values|
            case values
            when String
              values.each_line("\n") do |value|
                head += "#{name}: #{value.chomp}\r\n"
              end
            when Time
              # This is not RFC compliant, but mruby does not have
              # #strftime on Time to produce #httpdate.
              head += "#{name}: #{values.to_i}\r\n"
            when Array
              values.each do |value|
                head += "#{name}: #{value}\r\n"
              end
            end
          end

          head
        end
      end
    end

    def rack_env(socket, body)
      {
        'rack.input' => body,
        'rack.version' => "1.4.0", #Rack::VERSION,
        'rack.errors' => $stderr,
        'rack.multithread' => false,
        'rack.multiprocess' => false,
        'rack.run_once' => false,
        'rack.url_scheme' => 'http',

        'SERVER_SOFTWARE' => "Filament/0.0.1 (MRuby/#{RUBY_VERSION})",
        'SCRIPT_NAME' => ''
      }
    end

    def consume_headers(request)
      if RUBY_ENGINE == "mruby"
        parser = Phr.new
        parser.parse_request(request[:request_buffer])
        request[:headers] = {}

        parser.headers.each do |name, val|
          key = name.dup
          key.upcase!
          key.tr!('-', '_')

          unless ['content-type', 'content-length'].include?(name)
            key = "HTTP_#{key}"
          end

          request[:headers][key] = val.is_a?(Array) ? val.join("\n") : val.to_s
        end

        request[:method] = parser.method.to_s
        request[:path] = parser.path.split("?", 2)[0].to_s
        request[:query_string] = parser.path.split("?", 2)[1].to_s
        request[:content_length] = request[:headers]["CONTENT_LENGTH"].to_i
        request[:server_protocol] = parser.minor_version

        parser.reset
      else
        headers = {}

        PicoHTTPParser.parse_http_request(request[:request_buffer], headers)

        request[:headers] = headers
        request[:method] = headers["REQUEST_METHOD"]
        request[:path] = headers["PATH_INFO"]
        request[:query_string] = headers["QUERY_STRING"]
        request[:content_length] = headers["CONTENT_LENGTH"].to_i
        request[:server_protocol] = headers['SERVER_PROTOCOL']
      end

      request[:request_buffer] = ""
    end
  end

  class ConnectionHandler < FiberHandler
    def run(reactor, event, handle)
      case event
      when :read
        client = handle.accept_nonblock
        request_handler = RequestHandler.new(client_context(client))

        reactor.register(client, :read, request_handler)
        reactor.register(client, :write, request_handler)
        reactor.register(client, :disconnect, self)
      when :disconnect
        reactor.deregister(handle)
        handle.close
      end

      true
    end

    private

    def client_context(client)
      {
        server_name: client.local_address.getnameinfo[0],
        server_port: client.local_address.ip_port.to_s,
        remote_addr: client.remote_address.ip_address,
        remote_port: client.remote_address.ip_port.to_s
      }.merge(context)
    end
  end

  def self.run(app)
    host = ENV.fetch("HOST", "localhost")
    port = ENV.fetch("PORT", 8080)

    server = TCPServer.new(host, port)
    connection_handler = ConnectionHandler.new({ app: app })

    reactor = Reactor.new
    reactor.register(server, :read, connection_handler)

    puts "Listening on #{host}:#{port}"

    reactor.run
  end
end

app = Proc.new do |env|
  [200, env.slice('SERVER_STATS'), ['OK']]
end

Filament.run(app)
