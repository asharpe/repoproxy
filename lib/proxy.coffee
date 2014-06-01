Proxy = (opts) ->
  @_listening = false
  self = this
  @_server = HTTP.Server((request) ->
    self.application request
  )
  @_server.node.addListener 'connect', self.connectProxy.bind(self)
  @_cacheDir = opts.cacheDir
  @_port = opts.port or null
  @_cacher = new Cacher(opts)
  @_collapsible = {}
  @_active = []
  @_counter = 0
  this

Q = require("q")
#Q.longStackSupport = true;
HTTP = require("q-io/http")
Apps = require("q-io/http-apps")
Reader = require("q-io/reader")
util = require("util")
Events = require("events")
net = require("net")
_ = require("underscore")
Cacher = require("./cacher")
util.inherits Proxy, Events.EventEmitter
module.exports = Proxy

###
The q-io/http application function

This is the entry point in to the proxy, a request comes in,
a response goes out.
###
Proxy::application = (request) ->
  self = this
  @normaliseRequest request

  request.k = @_counter++
  request.log = (message) ->
    self.log "[#{request.k}] #{message}"

  @log "{#{request.k}} #{request.url}"

  @_cacher.getCacheFile(request.url).then((cacheFile) ->
    if cacheFile
      self._appCacheable request, cacheFile
    else
      # not cacheable, just silently proxy
      request.log 'not caching'
      HTTP.request request.url
  ).fail((err) ->
    Apps.ok(
      "#{err}", # just conver the error to string for now
      'text/plain',
      502 # gateway error - probably true
    )
  )

###
This is the entry point in to the proxy for CONNECT requests
###
Proxy::connectProxy = (res, socket, bodyHead) ->
  self = this
  endpoint = res.url.split ':'

  @log "{CONNECT} #{res.url}"

  serviceSocket = new net.Socket()
    .addListener('data', (data) ->
      socket.write data
    )
    .addListener('error', () ->
      socket.destroy()
    )
    .connect (parseInt (endpoint[1] || '443')), endpoint[0]

  socket
    .addListener('data', (data) ->
      serviceSocket.write data
    )
    # tell the client it went OK, let's get to work
    .write "HTTP/1.0 200 OK\r\n\r\n"


###
We seem to get corrupted requests through when acting as a proxy
this just tries to fix them back up
###
Proxy::normaliseRequest = (request) ->
  request.url = request.path if request.path.match(/^http:\/\//)


###
The application to respond with if the request corresponds to
something that could be cached
###
Proxy::_appCacheable = (request, cacheFile) ->
  self = this
  
  # either we're the first one in
  if @_collapsible[request.url] && @_collapsible[request.url] != undefined
    # we should collapse this request
    return @_appCollapse(request, @_collapsible[request.url])
    
  cacheFile.expired().then (expired) ->
    return self._appCacheFromUpstream request, cacheFile
    if expired
      self._appCacheFromUpstream request, cacheFile
    else
      request.log "sending cached response"
      Q.all([cacheFile.getReader(), cacheFile.getMeta()]).then (i) ->
        reader = i[0]
        meta = i[1]
        self._appComplete request, cacheFile
        response = Apps.ok reader, meta['content-type'] or 'text/plain', meta._status or 200
        response.headers['location'] = meta['location'] if meta['location']
        response


###
We're attaching to a cacheable request that is already being downloaded by
another client
###
Proxy::_appCollapse = (request, active) ->
  cacheFile = active.cacheFile
  request.log "collapsing into {#{active.request.k}}"
  Q.all([cacheFile.getReader(), cacheFile.getMeta()]).then (res) ->
    reader = res[0]
    meta = res[1]
    Apps.ok reader, meta['content-type'] or 'text/plain', meta._status or 200


Proxy::_appComplete = (request, cacheFile) ->
  #@_collapsible = (x for x in @_collapsible when x != cacheFile)
  delete @_collapsible[request.url]


###
Grab something from upstream that doesn't have any cache yet and store it
###
Proxy::_appCacheFromUpstream = (request, cacheFile) ->
  @_collapsible[request.url] =
    cacheFile: cacheFile
    request: request
  cacheWriter = undefined
  appProm = undefined
  reader = undefined
  meta = undefined
  self = this
  d = Q.defer()

  p = cacheFile.getMeta().then (m) ->
    return HTTP.request(request.url) if not m

    meta = m

    # otherwise we'll try and send if-none-match etc
    r =
      url: request.url
      headers: _.clone(request.headers)

    r.headers['if-none-match'] = m.etag if m.etag
    r.headers['if-modified-since'] = m['last-modified'] if m['last-modified']
    HTTP.request(r)

  Q.all([cacheFile.getWriter(), cacheFile.getReader()]).then (res) ->
    cacheWriter = res[0]
    reader = res[1]
    req = p

    req
      .then (upstreamResponse) ->
        upstreamResponse.body.forEach (chunk) ->
          cacheWriter.write chunk
        .then ->
          cacheWriter.close()

        d.resolve
          reader: reader
          headers: upstreamResponse.headers or { 'content-type': 'text/plain' }
          status: upstreamResponse.status or 200

        upstreamResponse

      .then (upstreamResponse) ->
        cacheFile.save(upstreamResponse)

      .finally ->
        self._appComplete request, cacheFile
        self._removeCompletedRequests()

      self._active.push req

  d.promise
    .then (res_) ->
      switch
        when res_.status == 304
          request.log "not modified"
          # serve the cached version
          cacheFile.getReader().then (reader) ->
            Apps.ok reader, meta['content-type'], meta._status

        when res_.status > 300 and res_.status < 400
          request.log "redirecting to " + res_.headers.location
          Apps.redirect request, res_.headers.location, res_.status

        else
          request.log "sending upstream response"
          res = Apps.ok res_.reader, res_.headers['content-type'], res_.status
          res.headers['content-length'] = res_.headers['content-length'] if res_.headers['content-length']
          res


Proxy::_removeCompletedRequests = ->
  @_active = _.reject(@_active, (req) ->
    req.isFulfilled()
  )


###
Start the proxy listening
###
Proxy::listen = ->
  self = this
  return Q()  if @_listening
  @_server.listen(@_port).then ->
    self._listening = true
    self.log "Listening on port " + self.address().port



###
A basic logger that exports the messages out over event emitter
###
Proxy::log = (message) ->
  @emit "log", message


###
Expose the underlying address function
###
Proxy::address = ->
  @_server.address()

