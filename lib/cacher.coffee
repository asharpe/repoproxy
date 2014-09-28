Cacher = (opts) ->
  @_cacheDir = opts.cacheDir
  @_hosts = opts.hosts or []
  @

Q = require("q")
CacheFile = require("./cacheFile")
_ = require("underscore")
URL = require("url")

module.exports = Cacher


###
Get the cache path for a given URL

returns a promise with the CacheFile, it might resolve with
undefined in which case it shouldn't be cached
###
Cacher::getCacheFile = (url) ->
  @getInfo(url).then (info) =>
    if info and info.cache
      new CacheFile @_cacheDir, info.url
    else
      Q()


###
Get cache info for a given url

will be {
path: 'relative storage path',
cache: boolean
}
###
Cacher::getInfo = (url) ->
  url = URL.parse(url)
  host = url.hostname

  ###
  if _.some(@_hosts, (h) ->
    h is host
  )
  ###
  if true
    Q
      url: url
      path: host + url.path

      # out right reject stuff that's obviously a directory
      cache: not url.path.match(/\/$/)
  else
    Q()

