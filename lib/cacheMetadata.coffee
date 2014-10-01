CacheMetadata = (request, cacheFile, complete) ->
  @request = request
  @cacheFile = cacheFile
  @complete = complete
  @getReader = undefined
  @clients = 1
  @

Q = require("q")
#Q.longStackSupport = true
HTTP = require("q-io/http")
Apps = require("q-io/http-apps")
_ = require("underscore")
moment = require('moment')
console = require('console')

module.exports = CacheMetadata


###
Return a promise for the metadata

This method ensures only one request calls @_getMeta
###
CacheMetadata::getMetadata = (thisRequest) ->
  @gettingMeta ?= @_getMeta(thisRequest)


###
Check the local metadata and request it from upstream if needed
###
CacheMetadata::_getMeta = (thisRequest) ->
  # sanity check - only the first request should get here
  # TODO not sure we can guarantee this, so we may need to remove it
  throw new Error('invalid metadata fetch attempt') if @request != thisRequest

  # check the local metdata
  @cacheFile.getMeta().then (meta) =>
    @request.debug 'local metadata', meta
    # if the metadata is still valid, return it
    if (
      meta and (
        (meta?.expiry and (moment(meta?.expiry) > moment())) or
        (not meta?.expiry and moment(meta?.mtime) > moment().subtract('minutes', 30))
      )
    )
      @request.debug 'metadata says not expired. mtime:', meta.mtime, ', expiry:', meta.expiry?

      @getReader = =>
        @request.log 'not expired, serving cached file'
        @cacheFile.getReader()

      # we need to "complete" this request else we'll have indefinite collapsing
      @complete @request

      # TODO to keep the logging consistent we should listen for the 'finished' event on the
      # node response object for this request

      return meta

    # otherwise we're requesting new metadata from upstream
    r =
      url: @request.url
      headers: _.clone(@request.headers)

    # we'll try to send if-none-match or if-modified-since if we can
    if meta
      r.headers['if-none-match'] = meta.etag if meta.etag
      r.headers['if-modified-since'] = meta['last-modified'] if meta['last-modified']

    @request.debug 'getting upstream metadata', r
    Q.all([
      HTTP.request(r)
    ]).spread @_processUpstreamMetadata.bind @


###
Decide how to provide collapsed readers depending on the upstream response
###
CacheMetadata::_processUpstreamMetadata = (response) ->
  @request.debug 'upstream response', response.status
  meta = response.headers or {}

  if not meta.expiry and not (meta.etag or meta['last-modified'])
    meta.expiry = moment().add('minutes', 30)

  switch
    when 304 == response.status # not modified
      # collapsed requests can request a reader immediately, which should open the file
      # and give it to them
      @getReader = =>
        #thisRequest.log 'not modified, serving cached file'
        @cacheFile.getReader()

      # mark this file as fresh
      @cacheFile.markUpdated()

      # let the app know we're done
      @request.log '304 unmodified'
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
      @request.log 'serving upstream file'
      meta._status = response.status
      deferredMeta = Q.defer()

      @request.debug 'getting writer for', @cacheFile
      @cacheFile.getWriter().then (writer) =>
        # this makes all collapsed requests get a new reader
        # since only the one request makes it here we can't log in this method
        @getReader = ->
          #thisRequest.log 'serving upstream file'
          writer.getReader()

        # provide the metadata
        # NOTE this MUST be resolved after the reader has been made available
        deferredMeta.resolve meta

        @request.debug 'writing response body'
        Q.all([
          # we're safe to write the metadata now since any concurrent requests will be collapsed
          # until we call @complete, and if we ensure that the metadata is written before then
          # we can be sure all subsequent requests will have everything available
          @cacheFile.saveMetadata(meta).then =>
            @request.debug 'finished writing metdata'

          response.body.forEach (chunk) ->
            writer.write chunk
        ]).then =>
          writer.close()
          @request.debug 'finished writing cache file'

          # and let the app know we're done (stop collapsing)
          @request.log 'finished'
          @complete @request

      .fail (error) =>
        @request.log 'failsauce', error
        error

      deferredMeta.promise

