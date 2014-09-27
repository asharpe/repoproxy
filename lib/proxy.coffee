Proxy = (opts) ->
  @_listening = false
  self = @
  @_server = HTTP.Server((request) ->
    self.application.call self, request
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
Q.longStackSupport = true
HTTP = require("q-io/http")
Apps = require("q-io/http-apps")
Reader = require("q-io/reader")
util = require("util")
Events = require("events")
net = require("net")
_ = require("underscore")
Cacher = require("./cacher")
moment = require('moment')

util.inherits Proxy, Events.EventEmitter
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
  request.log = (messages...) =>
    @log "{#{request.k}}", messages...

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

  # if there's no request in progress, then this one is
  if not @_collapsible[request.url]
    @_collapsible[request.url] = new class
      cacheFile: cacheFile
      request: request
      _upstreamRequest: undefined
      response: undefined
      _meta: undefined

      getMeta: (thisRequest) =>
        #thisRequest.log 'getting metadata'
        #return Q(@_meta) if @_meta
        thisRequest.log 'getting metdata promise'
        @gettingMeta ?= @_getMeta(thisRequest)

      _getMeta: (thisRequest) =>
        throw new Error('invalid metadata fetch attempt') if @request != thisRequest
        @request.log 'checking local metdata'
        @cacheFile.getLocalMeta().then (meta) =>
          @request.log 'local metadata', meta
          # if the metadata is still valid, return it
          if (
            meta and (
              (meta?.expiry and (moment(meta?.expiry) > moment())) or
              (not meta?.expiry and moment(meta?.mtime) > moment().subtract('minutes', 30))
            )
          )
            @request.log 'metadata says not expired'
            @getReader = ->
              @cacheFile.getReader()
            return meta

          # otherwise we're requesting some new metadata from upstream
          # default request
          r =
            url: @request.url
            headers: _.clone(@request.headers)

          # we'll try to send if-none-match or if-modified-since if we can
          if meta
            r.headers['if-none-match'] = meta.etag if meta.etag
            r.headers['if-modified-since'] = meta['last-modified'] if meta['last-modified']

          # make the request
          @request.log 'getting upstream metadata', r
          @_upstreamRequest = HTTP.request(r)
          @_upstreamRequest.then (response) =>
            @request.log 'upstream response', response.status
            meta = response.headers or {}
            meta._status = response.status

            if not meta.expiry and not (meta.etag or meta['last-modified'])
              meta.expiry = moment().add('minutes', 30)

            switch
              when 304 == response.status # not modified
                # collapsed requests can request a reader immediately, which should open the file
                # and give it to them
                @getReader = ->
                  @cacheFile.getReader()
                meta

              when 300 < response.status < 400 # redirect
                # we should do the redirect and pass the response to all requests
                # TODO I think there might be some recursion here - need to think this out a bit more
                #request.log "redirecting to " + upstreamResponse.headers.location
                #@_appComplete request, Apps.redirect(request, upstreamResponse.headers.location, upstreamResponse.status)
                # TODO these will fail for now
                meta

              else # actual response
                deferredMeta = Q.defer()
                deferredReader = Q.defer()
                @getReader = ->
                  deferredReader.promise

                #@request.log 'getting writer for', @cacheFile
                @cacheFile.getWriter().then (writer) =>
                  # since we can only resolve the deferred once, that means there's a single
                  # reader for that deferred which is likely a problem if multiple clients get
                  # it - they each want their own reader
                  # This has to work in combo with getMeta to ensure that subsequent requests wait
                  # for their metadata until we can give them a new reader
                  # HACK! this will make subsequent requests get a new reader
                  @getReader = ->
                    writer.getReader()

                  # provide the metadata
                  deferredMeta.resolve meta

                  # give a reader to the first request - subsequent requests should be bocking on getMeta
                  deferredReader.resolve writer.getReader()

                  # write the response out
                  @request.log 'writing response body'
                  response.body.forEach (chunk) ->
                    writer.write chunk
                  .then ->
                    writer.close()
                    request.log 'finished writing cache file'
                    #cacheFile.save(upstreamResponse)
                    #  .fail (error)
                    #    deferred.fail error

                    # write the metadata last since new requests check for this first
                    cacheFile.saveMetadata meta
                .fail (error) =>
                  @request.log 'failsauce', error
                  error

                # return metadata
                #@request.log 'metadata', meta
                #meta
                deferredMeta.promise

      @

  # all requests are considered collapsed
  _coll = @_collapsible[request.url]
  #request.log 'requesting metadata'

  # first we'll get the metadata
  _coll.getMeta(request).then (meta) =>
    request.log 'got metadata, requesting reader', _coll.getReader.toString()
    Q.all([
      meta
      _coll.getReader()
    ])
  # then the reader, and send a response
  .spread (meta, reader) =>
    response = Apps.ok reader, meta['content-type'] or 'text/plain', meta._status or 200
    # TODO are we caching redirects?  I think we might be following them without caching further down
    response.headers['location'] = meta['location'] if meta['location']
    response


###
We're attaching to a cacheable request that is already being downloaded by
another client
###
Proxy::_appCollapse = (request, active) ->
  request.log "collapsing into {#{active.request.k}}"
  Q.linearise([
    active.getReader(request)
    (reader) ->
      [
        reader
        active.cacheFile.getMeta()
      ]
  ]).spread (reader, meta) ->
    request.log 'returning collapsed response'
    Apps.ok reader, meta['content-type'] or 'text/plain', meta._status or 200
  .fail (error) ->
    request.log "#{error}"
    Apps.ok(
      "#{error}" # just convert the error to string for now
      'text/plain'
      502 # gateway error - probably true
    )
  .finally ->
    request.log 'complete'


  ###
  active.getReader(request).then (reader) ->
    active.cacheFile.getMeta().then (meta) ->
    Q.all([
      active.cacheFile.getMeta()
      active.cacheFile.getReader()
    ]).spread (reader, meta) ->
      request.log 'returning collapsed response'
      Apps.ok reader, meta['content-type'] or 'text/plain', meta._status or 200
    .fail (error) ->
      request.log "#{error}"
      Apps.ok(
        "#{error}" # just convert the error to string for now
        'text/plain'
        502 # gateway error - probably true
      )
    .finally ->
      request.log 'complete'
  ###
  ###
  Q.all([
    Q.linearise([
      active.getResponse(request)
      active.cacheFile.getReader()
    ])
    active.cacheFile.getMeta()
  ]).spread (reader, meta) ->
    request.log 'returning collapsed response'
    Apps.ok reader, meta?['content-type'] or 'text/plain', meta?._status or 200
  .fail (error) ->
    request.log "#{error}"
    Apps.ok(
      "#{error}" # just convert the error to string for now
      'text/plain'
      502 # gateway error - probably true
    )
  ###

  ###
  Q.all([cacheFile.getReader(), cacheFile.getMeta()]).then (res) ->
    reader = res[0]
    meta = res[1]
    Apps.ok reader, meta['content-type'] or 'text/plain', meta._status or 200
  .fail (error) ->
    request.log "#{error}"
    Apps.ok(
      "#{error}" # just convert the error to string for now
      'text/plain'
      502 # gateway error - probably true
    )
  ###

Proxy::_getUpstreamResource = (request, cacheFile) ->
  # check for metadata
  cacheFile.getMeta().then (meta) =>
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


Proxy::_appComplete = (request, response) ->
  request.log 'no longer collapsible'
  delete @_collapsible[request.url]
  @_removeCompletedRequests()
  response


###
Grab something from upstream that doesn't have any cache yet and store it
###
Proxy::_appCacheFromUpstream = (request, cacheFile) ->
  #@_collapsible[request.url] =
  #  cacheFile: cacheFile
  #  request: request
  self = @

  # check for metadata
  cacheFile.getMeta().then (meta) =>
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

    upstreamRequest.then (upstreamResponse) =>
      switch
        when upstreamResponse.status == 304
          request.log "not modified, sending cached response"
          cacheFile.markUpdated()
          cacheFile.getReader().then (reader) =>
            response = Apps.ok reader, meta['content-type'], meta._status
            _.defaults response.headers, _.omit meta, [
              '_status'
              'mtime'
              'content-length'
            ]
            @_appComplete request, response

        when upstreamResponse.status > 300 and upstreamResponse.status < 400
          request.log "redirecting to " + upstreamResponse.headers.location
          @_appComplete request, Apps.redirect(request, upstreamResponse.headers.location, upstreamResponse.status)

        else
          request.log "sending upstream response ..."
          # we must make sure we've got the writer before getting the reader ...
          cacheFile.getWriter().then (writer) =>
            [cacheFile.getReader(), writer]
          .spread (reader, cacheWriter) =>
            upstreamResponse.body.forEach (chunk) =>
              cacheWriter.write chunk
            .then ->
              cacheWriter.close()
              cacheFile.save(upstreamResponse)
            .then =>
              request.log "done"
              @_appComplete request, response

            response = Apps.ok reader, upstreamResponse.headers['content-type'], upstreamResponse.status
            response.headers['content-length'] = upstreamResponse.headers['content-length'] if upstreamResponse.headers['content-length']
            response

###
    .finally =>
      upstreamRequest.finally (response) =>
        request.log 'finally', arguments
        @_appComplete request, cacheFile
        @_removeCompletedRequests()
###


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
Proxy::log = (messages...) ->
  @emit "log", messages...


###
Expose the underlying address function
###
Proxy::address = ->
  @_server.address()

