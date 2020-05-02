# Filament

- Reactor + IO.select based demuxer
- Event handler base class using Fibers
- HTTP server

## To do

- Rack interface (Does rack handle posts payload)
- Chunked encoding
- Correct POST / GET payload handling.
- MRB gem
- Perhaps split into separate gems.
- Check correct connection handling with tcpdump.

## Dependencies

- [iij/mruby-env](https://github.com/iij/mruby-env) - ENV object for mruby
- [Asmod4n/mruby-phr](https://github.com/Asmod4n/mruby-phr) - mruby wrapper for https://github.com/h2o/picohttpparser
- mruby-socket
- mruby-io
 
## Links & resources

### MRuby

- [Mgem list](https://github.com/mruby/mgem-list) - A list of all GEMs for mruby to be managed by mgem
- [katzer/mruby-logger](https://github.com/katzer/mruby-logger) - A simple but sophisticated logging utility that you can use to output messages

### Sockets

- [Detecting close 1](https://stackoverflow.com/questions/2593236/how-to-know-if-the-client-has-terminated-in-sockets#2593286)
- [Detecting close 2](https://stackoverflow.com/questions/151590/how-to-detect-a-remote-side-socket-close)
- [Detection of Half-Open (Dropped) TCP/IP Socket Connections](https://www.codeproject.com/articles/37490/detection-of-half-open-dropped-tcp-ip-socket-conne)
- [Ruby TCPServer documentation](https://ruby-doc.org/stdlib-2.7.0/libdoc/socket/rdoc/TCPServer.html) 
- [Ruby IO documentation](https://ruby-doc.org/core-2.7.0/IO.html#method-c-select)
- [Unicorn HTTP detecting socket options](https://github.com/defunkt/unicorn/blob/17de306edbbf4140df7ec49dbb7e26e59d33c0f9/lib/unicorn/http_request.rb#L156-L183)
- [mruby-io](https://github.com/mruby/mruby/tree/master/mrbgems/mruby-io)


### Reactor

- [Reactor gem](https://github.com/oldmoe/reactor/blob/master/lib/reactor.rb) - Pure Ruby implementation.
- [Reactor paper](http://www.dre.vanderbilt.edu/~schmidt/PDF/reactor-siemens.pdf) - Reactor - An Object Behavioral Pattern for Demultiplexing and Dispatching Handles for Synchronous Events (Douglas C. Schmidt) 
- [Socketry Async Reactor](https://github.com/socketry/async/blob/master/lib/async/reactor.rb)
- [Reactor pattern wikipedia](https://en.wikipedia.org/wiki/Reactor_pattern)
- [Nio4 selector](https://github.com/socketry/nio4r/blob/master/lib/nio/selector.rb)

### HTTP

- [Chunked transfer encoding](https://en.wikipedia.org/wiki/Chunked_transfer_encoding)
- [Pico HTTP Parser MRI Ruby gem](https://github.com/kazeburo/pico_http_parser)
- [Ruby webrick HTTP server](https://github.com/ruby/webrick/blob/master/lib/webrick/httpserver.rb)
- [MRuby simple http server](https://github.com/matsumotory/mruby-simplehttpserver)
- [MRuby Phr - pico http parser](https://github.com/Asmod4n/mruby-phr/blob/master/mrblib/phr.rb)
- [rack/rack](https://github.com/rack/rack)
- [SO - How are parameters sent in an HTTP POST request?](https://stackoverflow.com/questions/14551194/how-are-parameters-sent-in-an-http-post-request)
- [Puma rack handler](https://github.com/puma/puma/blob/master/lib/rack/handler/puma.rb)
- [Simple HTTP parsing example](https://gist.github.com/shtirlic/4136962)
- [postmodern/net-http-server](https://github.com/postmodern/net-http-server)
- [appsignal - building a http server](https://blog.appsignal.com/2016/11/23/ruby-magic-building-a-30-line-http-server-in-ruby.html)
- [rack wikipedia](https://en.wikipedia.org/wiki/Rack_(web_server_interface))

### Fibers

- [Ruby Fiber documentation](https://ruby-doc.org/core-2.7.1/Fiber.html)
- [Fiberchat](https://gist.github.com/pfleidi/835268) - A naive socket chat using select() and ruby fibers.
