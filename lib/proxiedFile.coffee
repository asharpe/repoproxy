ProxiedFile = (request, cacheFile, complete) ->
  @request = request
  @cacheFile = cacheFile
  @response = undefined
  @_meta = undefined
  @getReader = undefined
  @complete = complete
  @clients = 1
  @

Q = require("q")
#Q.longStackSupport = true
HTTP = require("q-io/http")
Apps = require("q-io/http-apps")
_ = require("underscore")
moment = require('moment')
console = require('console')

module.exports = ProxiedFile


ProxiedFile::getMetadata = (thisRequest) ->
  @gettingMeta ?= @_getMeta(thisRequest)


ProxiedFile::_getMeta = (thisRequest) ->
  # sanity check - only the first request should get here
  throw new Error('invalid metadata fetch attempt') if @request != thisRequest

  @cacheFile.getMeta().then (meta) =>
    @request.debug 'local metadata', meta
    # if the metadata is still valid, return it
    if (
      meta and (
        (meta?.expiry and (moment(meta?.expiry) > moment())) or
        (not meta?.expiry and moment(meta?.mtime) > moment().subtract('minutes', 30))
      )
    )
      @request.debug 'metadata says not expired'
      @getReader = =>
        thisRequest.log 'not expired, serving cached file'
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
    @request.debug 'getting upstream metadata', r
    Q.all([
      thisRequest
      HTTP.request(r)
    ]).spread @_processUpstreamMetadata.bind @


ProxiedFile::_processUpstreamMetadata = (thisRequest, response) ->
  @request.debug 'upstream response', response.status
  @_meta = response.headers or {}
  meta = @_meta

  if not meta.expiry and not (meta.etag or meta['last-modified'])
    meta.expiry = moment().add('minutes', 30)

  switch
    when 304 == response.status # not modified
      # collapsed requests can request a reader immediately, which should open the file
      # and give it to them
      @getReader = =>
        thisRequest.log 'not modified, serving cached file'
        @cacheFile.getReader()

      # mark this file as fresh
      @cacheFile.markUpdated()

      # let the app know we're done
      @complete @request

      meta

    when 300 < response.status < 400 # redirect
      # we should do the redirect and pass the response to all requests
      # TODO I think there might be some recursion here - need to think this out a bit more
      #request.log "redirecting to " + upstreamResponse.headers.location
      #@_appComplete request, Apps.redirect(request, upstreamResponse.headers.location, upstreamResponse.status)

      # let the app know we're done
      @complete @request

      # TODO these will fail for now
      meta

    else # actual response
      thisRequest.log 'serving upstream file'
      meta._status = response.status
      deferredMeta = Q.defer()
      deferredReader = Q.defer()
      @getReader = ->
        deferredReader.promise

      @request.debug 'getting writer for', @cacheFile
      @cacheFile.getWriter().then (writer) =>
        # since we can only resolve the deferred once, that means there's a single
        # reader for that deferred which is likely a problem if multiple clients get
        # it - they each want their own reader
        # This has to work in combo with getMeta to ensure that subsequent requests wait
        # for their metadata until we can give them a new reader
        # HACK! this will make subsequent requests get a new reader
        @getReader = ->
          # TODO this is broken and reports this message from the main process for all collapsed
          # requests since subsequent requests were given the promise for this info
          #thisRequest.log 'serving upstream file'
          writer.getReader()

        # provide the metadata
        deferredMeta.resolve meta

        # give a reader to the first request - subsequent requests should be bocking on getMeta
        deferredReader.resolve writer.getReader()

        # write the response out
        @request.debug 'writing response body'
        response.body.forEach (chunk) ->
          writer.write chunk
        .then =>
          writer.close()
          @request.debug 'finished writing cache file'

          # write the metadata last since new requests check for this first
          @cacheFile.saveMetadata(meta).then =>
            @request.debug 'finished writing metdata'

            # and let the app know we're done
            @complete @request
            response
      .fail (error) =>
        @request.log 'failsauce', error
        error

      deferredMeta.promise

