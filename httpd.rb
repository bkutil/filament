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

  private

  def run
    @server_socket = TCPServer.new('localhost', 9292)
    @reading.push(@server_socket)
    start
  rescue Exception => e
    puts "#{e.class} #{e.message}"
  end

  def add_client
    socket = @server_socket.accept_nonblock

    @reading.push(socket)
    @requests[socket] = ""
    @clients[socket] = Fiber.new do |response|
	    begin
		    loop do
			    if response.nil?
				    request = socket.gets
				    #socket.flush
				    response = Fiber.yield(request)
			    else
begin
puts response
				    socket.puts response
rescue Exception => e
puts "Error in puts #{e.class} #{e.message}"
end
				    socket.flush
				    response = Fiber.yield
			    end
		    end
	    rescue Exception => e
		    puts "Error in Fiber loop #{e.class} #{e.message}"
	    end
    end
  end

  def remove_client(socket)
	  @reading.delete(socket)
	  @clients.delete(socket)
	  @requests.delete(socket)
	  socket.flush
	  socket.close
  end

  def request_env(socket, parser)
	  env = {}

	  remote_address = socket.remote_address
	  local_address  = socket.local_address

	  env['SERVER_NAME']     = local_address.getnameinfo[0]
	  env['SERVER_PORT']     = local_address.ip_port.to_s
	  env['SERVER_PROTOCOL'] = "HTTP/1.#{parser.minor_version}"

	  env['REMOTE_ADDR'] = remote_address.ip_address
	  env['REMOTE_PORT'] = remote_address.ip_port.to_s

	  env['REQUEST_METHOD'] = parser.method.to_s
	  env['PATH_INFO']      = parser.path.to_s
	  env['QUERY_STRING']   = parser.path.split("?", 2)[1].to_s

	  parser.headers.each do |name, val|
		  key = name.dup
		  key.upcase!
		  key.tr('-', '_')

		  unless ['Content-Type', 'Content-Length'].include?(name)
			  key = "HTTP_#{key}"
		  end

		  env[key] = val.is_a?(Array) ? val.join("\n") : val.to_s
	  end

	  env
  end
  
  def rack_env(socket, body)
p body
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
	  parser = Phr.new
	  body_idx = parser.parse_request(request)
          p request
	  payload = request[body_idx..-1]
	  env = request_env(socket, parser).merge(rack_env(socket, payload)) 
	  parser.reset

	  status, headers, body = @app.call(env)
	  response(status, headers, body)
  end

  def start
    puts "Starting HTTP server on localhost:9292"

    loop do
      readable, writable = IO.select(@reading, @writing)

      readable.each do |socket|
        if socket == @server_socket
          add_client
        else
          client = @clients[socket]
          request = client.resume
          @requests[socket] += request.to_s
          if request.nil?
	    remove_client(socket)
          else
            if @requests[socket].start_with?("GET") && request == "\r\n"
		    response = process(socket, @requests[socket])
		    client.resume(response)
		    remove_client(socket)
	    else
               p request
	       client.resume
	       #remove_client(socket)
	    end
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
