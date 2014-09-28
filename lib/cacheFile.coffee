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


###
Return a promise for the local metadata or nothing
###
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
      ]).spread (contents, stat) ->
        try
          meta = JSON.parse(contents)
          meta.mtime = stat.node.mtime
          meta
        catch e
          return {}
    else
      Q()


###
We use the metadata mtime to check how old a resource is if it uses
etags or last-modified, this is how we "freshen" it
###
CacheFile::markUpdated = ->
  path = @getPath('meta')
  FS.isFile(path).then (isFile) ->
    try
      now = moment().toDate()
      fs.utimes(path, now, now) if isFile
    catch e
      console.log(e)


###
Write the metadata to disk
###
CacheFile::saveMetadata = (meta) ->
  @makeTree("meta").then =>
    FS.write @getPath("meta"), JSON.stringify _.omit meta, [
        'connection',
        'keep-alive',
        'accept-ranges',
      ]


CacheFile::makeTree = (type) ->
  dir = Path.dirname @getPath(type or 'data')
  FS.makeTree dir


###
Check simple metadata for whether it's expired or not
###
CacheFile::expired = ->
  @getMeta().then (meta) ->
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
  ]).spread (expired, meta) ->
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
  Q.all([
    FS.isFile(@getPath("data"))
    FS.isFile(@getPath("meta"))
  ]).spread (dataExists, metaExists) ->
    proms = []
    proms.push FS.remove(@getPath("data")) if dataExists
    proms.push FS.remove(@getPath("meta")) if metaExists
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
  @_gettingWriter ?= @_getNewWriter()


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
Get a stream reader

This will check the state of the resource and either create a writer or return the resource
###
CacheFile::getReader = (request) ->
  # TODO this check for the existence of a write may not be ideal
  Q @_writer?.getReader() or FS.open @getPath(),
    flags: 'rb'


