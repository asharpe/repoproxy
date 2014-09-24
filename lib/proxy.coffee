Proxy = (opts) ->
  @_listening = false
  self = @
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
moment = require('moment')
module.exports = Proxy

###
The q-io/http application function

This is the entry point in to the proxy, a request comes in,
a response goes out.
###
Proxy::application = (request) ->
  self = @
  @normaliseRequest request

  request.k = @_counter++
  request.log = (message) ->
    self.log "{#{request.k}} #{message}"

  @log "[#{request.k}] #{request.url}"

  @_cacher.getCacheFile(request.url)
    .then (cacheFile) ->
      if cacheFile
        self._appCacheable request, cacheFile

      else
        # not cacheable, just silently proxy
        request.log 'passthrough - not caching'
        HTTP.request request.url

    .fail (err) ->
      request.log "#{err}"
      Apps.ok(
        "#{err}", # just convert the error to string for now
        'text/plain',
        502 # gateway error - probably true
      )


###
This is the entry point in to the proxy for CONNECT requests
###
Proxy::connectProxy = (res, socket, bodyHead) ->
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
  self = @
  
  # if there's a request in progress ...
  if @_collapsible[request.url] && @_collapsible[request.url] != undefined
    # we should collapse this request
    return @_appCollapse(request, @_collapsible[request.url])

  # otherwise let's check the cached file ...
  Q.all([
    cacheFile.expired()
    cacheFile.getMeta()
  ])
    .then (info) ->
      expired = info[0]
      meta = info[1]

      # expired means that it has an expiry, or it's not been used in the last 30 minutes
      if expired
        return self._appCacheFromUpstream request, cacheFile

      else
        request.log "sending cached response"
        cacheFile.getReader()
          .then (reader) ->
            self._appComplete request, cacheFile
            response = Apps.ok reader, meta['content-type'] or 'text/plain', meta._status or 200
            # TODO are we caching redirects?  I think we might be following them without caching further down
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
  delete @_collapsible[request.url]


###
Grab something from upstream that doesn't have any cache yet and store it
###
Proxy::_appCacheFromUpstream = (request, cacheFile) ->
  @_collapsible[request.url] =
    cacheFile: cacheFile
    request: request
  self = @

  # check for metadata
  cacheFile.getMeta().then (meta) ->
    # default request
    r =
      url: request.url
      headers: _.clone(request.headers)

    # we'll try to send if-none-match or if-modified-since if we can
    if meta
      r.headers['if-none-match'] = meta.etag if meta.etag
      r.headers['if-modified-since'] = meta['last-modified'] if meta['last-modified']

    # make the request
    upstreamRequest = HTTP.request(r)

    # and keep track of it
    self._active.push upstreamRequest

    upstreamRequest.then (upstreamResponse) ->
      switch
        when upstreamResponse.status == 304
          request.log "not modified, sending cached response"
          cacheFile.markUpdated()
          cacheFile.getReader().then (reader) ->
            response = Apps.ok reader, meta['content-type'], meta._status
            _.defaults response.headers, _.omit meta, [
              '_status'
              'mtime'
              'content-length'
            ]
            response

        when upstreamResponse.status > 300 and upstreamResponse.status < 400
          request.log "redirecting to " + upstreamResponse.headers.location
          Apps.redirect request, upstreamResponse.headers.location, upstreamResponse.status

        else
          request.log "sending upstream response ..."
          # we must make sure we've got the writer before getting the reader ...
          cacheFile.getWriter().then (writer) ->
            [cacheFile.getReader(), writer]
          .spread (reader, cacheWriter) ->
            upstreamResponse.body.forEach (chunk) ->
              cacheWriter.write chunk
            .then ->
              cacheWriter.close()
              cacheFile.save(upstreamResponse)
            .then ->
              request.log "done"

            response = Apps.ok reader, upstreamResponse.headers['content-type'], upstreamResponse.status
            response.headers['content-length'] = upstreamResponse.headers['content-length'] if upstreamResponse.headers['content-length']
            response

  .finally ->
    self._appComplete request, cacheFile
    self._removeCompletedRequests()



Proxy::_removeCompletedRequests = ->
  @_active = _.reject(@_active, (req) ->
    req.isFulfilled()
  )


###
Start the proxy listening
###
Proxy::listen = ->
  self = @
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

