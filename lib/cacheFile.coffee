###
A cacheable file is a representation of a URL that should be cacheable
it can be requested for the actual cache entry (which may not exist)
and it can be told to update the actual file, the consumer of cacheable
file need not know where the file is actually stored.
###

###
Create the cacheable file

@param cacheDir - the directory containing all repository cache
@param file - the file we want relative to the cacheDir
###
CacheFile = (cacheDir, url) ->
  @_cacheDir = cacheDir
  @_url = url
  @_file = url.host + url.path
  @_writer = null

console = require('console')
Q = require("q")
FS = require("q-io/fs")
HTTP = require("q-io/http")
fs = require("fs")
Reader = require("q-io/reader")
Path = require("path")
moment = require("moment")
util = require("util")
Events = require("events")
_ = require("underscore")
ReadableFileWriter = require("./readableFileWriter")

util.inherits CacheFile, Events.EventEmitter
module.exports = CacheFile

CacheFile::exists = ->
  Q.all([
    FS.exists(@getPath())
    FS.exists(@getPath("meta"))
  ]).then (res) ->
    res[0] and res[1]

CacheFile::getPath = (type) ->
  type = "data" unless type
  @_cacheDir + "/" + type + "/" + @_file

CacheFile::getLocalMeta = ->
  path = @getPath("meta")
  FS.isFile(path).then (isFile) ->
    # we'll get the contents and the last modified, knowing that
    # the proxy will update the last modified for any requests that
    # don't come with an expiry (eg, etag, last-modified)
    if isFile
      Q.all([
        FS.read path
        FS.stat path
      ]).then (data) ->
        contents = data[0]
        stat = data[1]
        try
          meta = JSON.parse(contents)
          meta.mtime = stat.node.mtime
          meta
        catch e
          return {}
    else
      Q()

CacheFile::getMeta = ->
  path = @getPath("meta")
  FS.isFile(path).then (isFile) ->
    # we'll get the contents and the last modified, knowing that
    # the proxy will update the last modified for any requests that
    # don't come with an expiry (eg, etag, last-modified)
    if isFile
      Q.all([
        FS.read path
        FS.stat path
      ]).then (data) ->
        contents = data[0]
        stat = data[1]
        try
          meta = JSON.parse(contents)
          meta.mtime = stat.node.mtime
          meta
        catch e
          return {}
    else
      Q()


CacheFile::markUpdated = ->
  path = @getPath('meta')
  FS.isFile(path).then (isFile) ->
    try
      now = moment().toDate()
      fs.utimes(path, now, now) if isFile
    catch e
      console.log(e)


###
Once a file has been written out it should be saved with optional
cache metadata
###
CacheFile::save = (upstreamResponse) ->
  self = this
  meta = upstreamResponse.headers or {}
  # we'll only add an expiry if there's no ETag or Last-Modified headers
  if not meta.expiry and not (meta.etag or meta['last-modified'])
    meta.expiry = moment().add('minutes', 30)

  meta._status = upstreamResponse.status
  if upstreamResponse.status < 300
    Q.all([
      @makeTree("data")
      @makeTree("meta")
      @makeTree("temp-meta")
    ]).then(->
      FS.write self.getPath("temp-meta"), JSON.stringify _.omit meta, [
          'connection',
          'keep-alive',
          'accept-ranges',
        ]
    ).then(->
      Q.all [
        FS.isFile(self.getPath("data"))
        FS.isFile(self.getPath("meta"))
      ]
    ).then((files) ->
      proms = []
      proms.push FS.remove(self.getPath("data")) if files[0]
      proms.push FS.remove(self.getPath("meta")) if files[1]
      Q.all proms
    ).then(->
      self._writer.move self.getPath("data")
    ).then ->
      self._writer = null
      FS.move self.getPath("temp-meta"), self.getPath("meta")
  else
    do Q


CacheFile::saveMetadata = (meta) ->
  @makeTree("meta").then =>
    FS.write @getPath("meta"), JSON.stringify _.omit meta, [
        'connection',
        'keep-alive',
        'accept-ranges',
      ]


CacheFile::makeTree = (type) ->
  #type = "data" unless type
  dir = Path.dirname @getPath(type or 'data')
  FS.makeTree dir


###
Check simple metadata for whether it's expired or not
###
CacheFile::expired = ->
  @getMeta()
    .then (meta) ->
      not meta or (
        # if there was a time, check that
        (meta.expiry and moment(meta.expiry) < moment()) or
        # or see if it's been recently checked
        (not meta.expiry and
          moment(meta.mtime) < moment().subtract('minutes', 30)
        )
      )


###
Extra checks for files with etag or last-modified
###
CacheFile::expiredForCleaner = ->
  Q.all([
    @expired
    @getMeta
  ])
    .then (i) ->
      expired = i[0]
      meta = i[1]

      # simple case
      return false if not expired

      # if it was expired because it owns an expiry, that's valid
      return true if meta.expiry

      # we'll keep other things for a while longer
      moment(meta.mtime) < moment().subtract('months', 9)


###
Purge all data on this file
###
CacheFile::purge = ->
  self = this
  Q.all([
    FS.isFile(self.getPath("data"))
    FS.isFile(self.getPath("meta"))
  ]).then (files) ->
    proms = []
    proms.push FS.remove(self.getPath("data"))  if files[0]
    proms.push FS.remove(self.getPath("meta"))  if files[1]
    Q.all proms

###
Sets up a stream writer for a given cachefile

The writer will send data to disk + any readers
that are already attached or become attached
###
CacheFile::getWriter = ->

  # if we already have the writer return it
  return Q(@_writer) if @_writer

  # other wise if we haven't started getting it, start getting it
  @_gettingWriter ?= @_getNewWriter() # unless @_gettingWriter

  # return the promise for the new one
  @_gettingWriter


###
Ensure there's only one writer per cachefile

This relies on the OS feature that currently open file
descriptors retain their reference to the original file
even if it's unlinked from the filesystem.

This allows us to delete the old file and write a new one
without disrupting existing requests reading the file
###
CacheFile::_getNewWriter = ->
  FS.isFile(@getPath 'data').then (dataExists) =>
    if dataExists then FS.remove(@getPath 'data') else Q()
  .then =>
    @makeTree("data")
  .then =>
    ReadableFileWriter.create @getPath("data")
  .then (writer) =>
    @_writer = writer

###
CacheFile::_getNewWriter = ->
  self = this
  @makeTree("temp-data").then(->
    ReadableFileWriter.create self.getPath("temp-data")
  ).then (writer) ->
    self._writer = writer
###

###
Get a stream reader

This will check the state of the resource and either create a writer or return the resource
###
CacheFile::getReader = (request) ->
  ###
  Q.all([
    @expired()
    @getMeta()
  ]).spread (expired, meta) =>
    if expired
      @getWriter().then (writer) =>
        writer.getReader()
    else
      Q FS.open @getPath(),
        flags: 'rb'
  ###
  Q @_writer?.getReader() or FS.open @getPath(),
    flags: 'rb'


###
Check the state of the upstream resources

There should only be one of these in progress at any time
###
CacheFile::checkUpstream = (request) ->
  return Q(@_upstreamCheck) if @_upstreamCheck

  @_upstreamCheck ?= @_checkUpstream request


###
Make a request upstream, possibly returning the full response
###
CacheFile::_checkUpstream = (request) ->
  r =
    url: @_url
    headers: _.clone request.headers


