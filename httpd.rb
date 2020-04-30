#!/usr/bin/env ruby

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
      # writeable notify.
      return unless @handlers.key?(handle)
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

  class RequestHandler
    def initialize(app)
      @handler = handler
      @app = app
    end

    def call(reactor, event, socket)
      @handler.resume(reactor, event, socket)
    end

    def handler
      Fiber.new do |reactor, event, socket|
        context = {
          server_name: socket.local_address.getnameinfo[0],
          server_port: socket.local_address.ip_port.to_s,
          remote_addr: socket.remote_address.ip_address,
          remote_port: socket.remote_address.ip_port.to_s
        }

        loop do
          case event
          when :read
            chunk = read_request(context, socket)
            if chunk.nil?
              puts "Client #{socket} is gone on read"
              reactor.notify(:close, socket)
              break
            else
              process_request(context, chunk)
            end
          when :write
            if context[:read_done]
              run_app(context, socket)
              write_response(context, socket)
              reactor.notify(:disconnect, socket)
              break
            end
          end

          reactor, event, socket = Fiber.yield
        end
      end
    end

    def read_request(context, socket)
      socket.gets(context[:content_length] ? context[:socket_length] : "\r\n")
    end

    def process_request(context, chunk)
      context[:request_buffer] ||= ""
      context[:request_buffer] += chunk.to_s

      consume_headers(context) if chunk == "\r\n" || chunk == "\n"
        
      context[:read_done] = case context[:method]
        when "GET"
          true
        when "POST"
          context[:request_buffer].bytesize == context[:content_length] 
        else
          false
        end
    end

    def write_response(context, socket)
      ret = socket.write context[:response_buffer]
      if ret.nil? || ret < 0
	      puts "Client is gone on write"
      else
	      socket.flush
      end
    end

    def run_app(context, socket)
      env = rack_env(socket, context[:request_buffer]) 
      status, headers, body = @app.call(env)
      context[:response_buffer] = response(status, headers, body)
    end

    def response(status, headers, body)
      status = "HTTP/1.1 #{status}\r\n"
      head = ""

      headers.each do |name,values|
        case values
        when String
          values.each_line("\n") do |value|
            head += "#{name}: #{value.chomp}\r\n"
          end
        when Time
          head += "#{name}: #{values.httpdate}\r\n"
        when Array
          values.each do |value|
            head += "#{name}: #{value}\r\n"
          end
        end
      end

      main = ""

      body.each do |chunk|
        main += chunk
      end

      head += "Content-Length: #{main.bytesize}\r\n"
      head += "\r\n"

      status + head + main
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

        'SERVER_SOFTWARE' => "HTTPServer/0.0.1 (MRuby/#{RUBY_VERSION})",
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

  class ConnectionHandler
    def initialize(app)
      @handler = handler
      @app = app
    end

    def call(reactor, event, socket)
      @handler.resume(reactor, event, socket)
    end

    def handler
      Fiber.new do |reactor, event, socket|
        loop do
          case event
          when :read
            client = socket.accept_nonblock
            request_handler = RequestHandler.new(@app)
            reactor.register(client, :read, request_handler)
            reactor.register(client, :write, request_handler)
            reactor.register(client, :disconnect, self)
          when :disconnect
            reactor.deregister(socket)
            socket.close
          end

          reactor, event, socket = Fiber.yield
        end
      end
    end
  end

  def self.run(app)
    server = TCPServer.new('localhost', 9292)
    connection_handler = ConnectionHandler.new(app)

    reactor = Reactor.new
    reactor.register(server, :read, connection_handler)
    reactor.run
  end
end

app = Proc.new do |env|
  [200, env.slice('SERVER_STATS'), ['OK']]
end

Filament.run(app)
