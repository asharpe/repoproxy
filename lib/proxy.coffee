Proxy = (opts) ->
  @_listening = false
  @_server = HTTP.Server @application.bind @
  @_server.node.addListener 'connect', @connectProxy.bind @
  @_cacheDir = opts.cacheDir
  @_port = opts.port or null
  @_cacher = new Cacher(opts)
  @_collapsible = {}
  @_counter = 0
  @

Q = require("q")
Q.longStackSupport = true
HTTP = require("q-io/http")
Apps = require("q-io/http-apps")
Reader = require("q-io/reader")
util = require("util")
Events = require("events")
net = require("net")
_ = require("underscore")
Cacher = require("./cacher")
ProxiedFile = require("./proxiedFile")
moment = require('moment')

util.inherits Proxy, Events.EventEmitter
module.exports = Proxy


###
The q-io/http application function

This is the entry point in to the proxy, a request comes in,
a response goes out.
###
Proxy::application = (request) ->
  @normaliseRequest request

  request.k = @_counter++
  request.log = (messages...) =>
    @log "{#{request.k}}", messages...
  request.debug = (messages...) =>
    @log "{#{request.k}}", messages... if process.env.debug_proxy?

  @log "[#{request.k}] #{request.url}"

  @_cacher.getCacheFile(request.url)
    .then (cacheFile) =>
      if cacheFile
        @_appCacheable request, cacheFile

      else
        # not cacheable, just silently proxy
        request.log 'passthrough - not caching'
        HTTP.request request.url

    .fail (error) ->
      request.log "#{error}"
      Apps.ok(
        "#{error}", # just convert the error to string for now
        'text/plain',
        502 # gateway error - probably true
      )


###
We seem to get corrupted requests through when acting as a proxy
this just tries to fix them back up
###
Proxy::normaliseRequest = (request) ->
  request.url = request.path if request.path.match(/^http:\/\//)


###
This is the entry point in to the proxy for CONNECT requests
###
Proxy::connectProxy = (res, socket, bodyHead) ->
  endpoint = res.url.split ':'

  @log "{CONNECT} #{res.url}"

  serviceSocket = new net.Socket()
    .addListener 'data', (data) ->
      socket.write data
    .addListener 'error', () ->
      socket.destroy()
    .connect (parseInt (endpoint[1] || '443')), endpoint[0]

  socket
    .addListener 'data', (data) ->
      serviceSocket.write data
    # tell the client it went OK, let's get to work
    .write "HTTP/1.0 200 OK\r\n\r\n"


###
The application to respond with if the request corresponds to
something that could be cached
###
Proxy::_appCacheable = (currentRequest, cacheFile) ->
  # if there's no request in progress, then this one is
  if not @_collapsible[currentRequest.url]
    @_collapsible[currentRequest.url] = new ProxiedFile(currentRequest, cacheFile, @_appComplete.bind @)
  else
    currentRequest.log "collapsing into {#{@_collapsible[currentRequest.url].request.k}}"

  # all requests are considered collapsed
  request = @_collapsible[currentRequest.url]

  # get metadata first
  request.getMetadata(currentRequest).then (meta) ->
    currentRequest.debug 'got metadata, requesting reader', request.getReader.toString()
    # then the reader
    [meta, request.getReader()]
  .spread (meta, reader) ->
    # then send a response
    response = Apps.ok reader, meta['content-type'] or 'text/plain', meta._status or 200
    # TODO are we caching redirects?  I think we might be following them without caching further down
    response.headers['location'] = meta['location'] if meta['location']
    response


###
A request is finished, so we don't want to collapse any future requests
###
Proxy::_appComplete = (request, response) ->
  delete @_collapsible[request.url]
  request.debug 'no longer collapsible'
  response


###
Start the proxy listening
###
Proxy::listen = ->
  return Q() if @_listening
  @_server.listen(@_port).then =>
    @_listening = true
    @log "Listening on port " + @address().port



###
A basic logger that exports the messages out over event emitter
###
Proxy::log = (messages...) ->
  @emit "log", messages...


###
Expose the underlying address function
###
Proxy::address = ->
  @_server.address()

