#!/usr/bin/env ruby
#  Dependencies:
#
#  conf.gem :github => 'Asmod4n/mruby-phr'
#  conf.gem :core => 'mruby-io'
#  conf.gem :core => 'mruby-socket'
#  conf.gem :github => 'iij/mruby-env'

module Filament
  VERSION = "0.0.1"

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
    
    # Returning false/nil breaks out of the handler loop (catch is not available in
    # mruby and exceptions might be too heavy)
    def run(reactor, event, handle)
      raise "Override me"
    end
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

    class Request
      attr_reader :headers, :info, :body

      def initialize
        @info = {}

        @headers = {}
        @headers_complete = false

        @header = ""
        @body = ""
      end

      def complete?
        case @info['METHOD']
        when "GET"
          true
        when "POST"
          @body.bytesize == @headers['CONTENT_LENGTH']
        else
          false
        end
      end

      def <<(chunk)
        if @headers_complete
          @body += chunk
        else
          @header += chunk

          if chunk == "\r\n" || chunk == "\n"
            @headers, @info = parse_headers(@header)
            @headers_complete = true
          end
        end
      end

      private

      def parse_headers(header_string)
        parser = Phr.new
        parser.parse_request(header_string)

        headers = normalize_headers(parser.headers)
        info = extract_info(parser)

        parser.reset
        
        [headers, info]
      end

      def extract_info(parser)
        {
          "METHOD" => parser.method.to_s,
          "PATH" => parser.path.split("?", 2)[0].to_s,
          "QUERY_STRING" => parser.path.split("?", 2)[1].to_s,
          "SERVER_PROTOCOL" => parser.minor_version
        }
      end

      def normalize_headers(headers)
        normalized = {}

        headers.each do |name, val|
          key = name.upcase.tr('-', '_')

          unless ['content-type', 'content-length'].include?(name)
            key = "HTTP_#{key}"
          end

          normalized[key] = val.is_a?(Array) ? val.join("\n") : val.to_s
        end

        normalized
      end
    end
  end

  class RequestHandler < FiberHandler
    def run(reactor, event, handle)
      case event
      when :read
        context[:request] ||= Http::Request.new

        chunk = read_chunk(handle, context)

        if chunk.nil?
          # puts "Client #{socket} gone on read"
          reactor.notify(handle, :disconnect)
          return
        else
          context[:request] << chunk
        end
      when :write
        if context[:request].complete?
          run_app(handle, context)
          write_response(handle, context)
          # puts "Notifying server about client #{socket} disconnect"
          reactor.notify(handle, :disconnect)
          return
        end
      end

      true
    end

    def read_chunk(socket, context)
      content_length = context[:request].headers["CONTENT_LENGTH"]
      socket.gets(content_length ? content_length : "\r\n")
    end

    def write_response(socket, context)
      ret = socket.write context[:response].to_s
      if ret.nil? || ret < 0
	      # puts "Client is gone on write"
      else
	      socket.flush
      end
    end

    def run_app(socket, context)
      env = env(socket, context[:request]) 
      status, headers, body = context[:app].call(env)
      context[:response] = Http::Response.new(status, headers, body)
    end

    def env(socket, request)
      {
        'SERVER_SOFTWARE' => "Filament/#{VERSION} (#{RUBY_ENGINE}/#{RUBY_VERSION})",
        'APP_REQUEST_START' => Time.now.to_f,
        'SCRIPT_NAME' => ''
      }.merge(request.headers).merge(request.info)
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
    host = ENV.fetch("HTTP_HOST", "localhost")
    port = ENV.fetch("HTTP_PORT", 8080)

    server = TCPServer.new(host, port)
    connection_handler = ConnectionHandler.new({ app: app })

    reactor = Reactor.new
    reactor.register(server, :read, connection_handler)

    puts "Listening on #{host}:#{port}"

    reactor.run
  end
end

app = Proc.new do |env|
  case env['PATH']
  when "/"
    html=<<-EOF
      <html>
        <title>Hello from Filament HTTP server</title>
        <body>
        <h1>Hello</h1>
        <p>Running on #{env['SERVER_SOFTWARE']}</p>
        <p>Processing took #{((Time.now.to_f - env['APP_REQUEST_START']) * 1000.0).round(5)}ms.</p>
        <p>Feel free to read the <a href="/_source">source code</a>.
        </body>
      </html>
    EOF

    [200, {'Content-Type': "text/html"}, [html]]
  when "/_source"
    [200, {'Content-Type': "text/plain"}, [File.read(__FILE__)]]
  else
    [404, {'Content-Type': "text/plain"}, ["Not found"]]
  end
end

Filament.run(app)
