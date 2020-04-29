#!/usr/bin/env ruby

if RUBY_ENGINE != "mruby"
  require 'socket'
  require 'byebug'
  require 'pico_http_parser'
end

class HttpServer
  def initialize(app, options)
    @app = app
    @options = options

    @reading = []
    @writing = []

    @clients = {}
    @requests = {}
  end

  def self.run(app, options = {})
    new(app, options).run
  end

  def run
    @server_socket = TCPServer.new('localhost', 9292)
    @reading.push(@server_socket)
    start
  rescue Exception => e
    puts "#{e.class} #{e.message}"
    puts e.backtrace.join("\n")
    raise
  end

  def handler(socket)
    Fiber.new do |response|
      begin
        loop do
          if response.nil?
            req = @requests[socket]
            request = if req[:body_size]
              socket.gets(req[:body_size])
            else
              socket.gets
            end
            socket.flush
            response = Fiber.yield(request)
          else
            socket.write response
            socket.flush
            response = Fiber.yield
          end
        end
      rescue Exception => e
        puts "Error in Fiber loop #{e.class} #{e.message}"
        raise
      end
    end
  end

  def add_client
    socket = @server_socket.accept_nonblock
    remote_addr = socket.remote_address
    local_addr = socket.local_address

    @reading.push(socket)
    @clients[socket] = handler(socket)
    @requests[socket] = {
      buffer: "",
      headers: {},
      server_name: local_addr.getnameinfo[0],
      server_port: local_addr.ip_port.to_s,
      remote_addr: remote_addr.ip_address,
      remote_port: remote_addr.ip_port.to_s
    }
  end

  def remove_client(socket)
    @reading.delete(socket)
    @clients.delete(socket)
    @requests.delete(socket)
    socket.flush
    socket.close
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

  def response(status, headers, body)
    response = ""
    response += "HTTP/1.1 #{status}\r\n"

    headers.each do |name,values|
      case values
      when String
        values.each_line("\n") do |value|
          response += "#{name}: #{value.chomp}\r\n"
        end
      when Time
        response += "#{name}: #{values.httpdate}\r\n"
      when Array
        values.each do |value|
          response += "#{name}: #{value}\r\n"
        end
      end
    end

    response += "\r\n"

    body.each do |chunk|
      response += chunk
    end

    response
  end

  def process(socket, request)
    env = rack_env(socket, request[:buffer]) 
    status, headers, body = @app.call(env)
    response(status, headers, body)
  end

  def parse_headers(request)
    if RUBY_ENGINE == "mruby"
      parser = Phr.new
      parser.parse_request(request[:buffer])

      parser.headers.each do |name, val|
        key = name.dup
        key.upcase!
        key.tr('-', '_')

        unless ['content-type', 'content-length'].include?(name)
          key = "HTTP_#{key}"
        end

        request[:headers][key] = val.is_a?(Array) ? val.join("\n") : val.to_s
      end

      request[:method] = parser.method.to_s
      request[:path] = parser.path.split("?", 2)[0].to_s
      request[:query_string] = parser.path.split("?", 2)[1].to_s
      request[:body_size] = request[:headers]["CONTENT_LENGTH"].to_i
      request[:server_protocol] = parser.minor_version

      parser.reset
    else
      headers = {}

      PicoHTTPParser.parse_http_request(request[:buffer], headers)
      
      request[:headers] = headers
      request[:method] = headers["REQUEST_METHOD"]
      request[:path] = headers["PATH_INFO"]
      request[:query_string] = headers["QUERY_STRING"]
      request[:body_size] = headers["CONTENT_LENGTH"].to_i
      request[:server_protocol] = headers['SERVER_PROTOCOL']
    end
  end

  def start
    puts "Starting HTTP server on localhost:9292"

    loop do
      readable, writable = IO.select(@reading)

      readable.each do |socket|
        if socket == @server_socket
          add_client
        else
          handler = @clients[socket]
          req = @requests[socket]

          chunk = handler.resume

          # Client disconnected 
          if chunk.nil?
            remove_client(socket)
            next 
          end

          req[:buffer] += chunk

          # Got complete headers
          if chunk == "\r\n"
            parse_headers(req) 
            req[:buffer] = ""
          end

          case req[:method]
          when "GET", "OPTIONS", "HEAD", "CONNECT"
            response = process(socket, req)
            handler.resume(response)
            remove_client(socket)
          when "POST", "PUT"
            # Got complete headers, see what's next
            if req[:buffer].empty?
              next
            elsif req[:buffer].bytesize < req[:body_size]
              next
            else
              # Got complete body, call the app
              response = process(socket, req)
              handler.resume(response)
              remove_client(socket)
            end
          else
            # NOOP
          end

        end
      end
    end
  end
end

app = Proc.new do |env|
  [200, {}, ['OK']]
end

HttpServer.run(app)
