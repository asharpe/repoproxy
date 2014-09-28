
FS = require('q-io/fs')
Q = require('q')
CacheFile = require('./cacheFile')
FindIt = require('findit')
console = require('console')

# TODO this is probably better as an event emitter
class Cleaner
	constructor: (@opts) ->
		@cacheDir = @opts.cacheDir
		@dataDir = @cacheDir + '/data'
		@active = 0
		@ended = false
		@cleaned = 0
		@invalid = 0

	debug: (messages...) ->
		console.log messages... if process.env.debug_proxy? or process.env.debug_cleaner?


	clean: ->
		FS.isDirectory(@dataDir).then (isDir) =>
			if isDir then @cleanDataDir() else {}


	cleanDataDir: ->
		deferred = Q.defer()
		finder = FindIt.find(@dataDir)

		finder.on 'file', ( (file)->
			@fileFound file, deferred
		).bind @

		finder.on 'end', ( ->
			@fileSearchEnd deferred
		).bind @

		deferred.promise


	fileFound: (file, deferred) ->
		@active++
		@cleanDataFile(file).then =>
			@active--
			if (@active == 0 && @ended)
				deferred.resolve {
					count: @cleaned
					invalid: @invalid
				}
		.fail (error) =>
			deferred.fail error


	fileSearchEnd: (deferred) ->
		@debug 'finished finding files', @active, 'files left to inspect'
		@ended = true
		if (@active == 0)
			deferred.resolve {
				count: @cleaned
				invalid: @invalid
			}


	cleanDataFile: (file) ->
		short = FS.relativeFromDirectory(@dataDir, file).split /([^\/]+)(\/.*)/
		url =
			host: short[1]
			path: short[2]

		cacheFile = new CacheFile(
			@cacheDir, url
		)
		Q.all([
			cacheFile.expiredForCleaner()
			cacheFile.getMeta()
		]).spread (expired, metadata) =>
			#@debug 'checking', file
			if expired
				@debug 'expired', file
				@cleaned++
				return cacheFile.purge()

			if not metadata
				@debug 'no metdata for', file
				@noMetadata++
				#return cacheFile.purge()

			if size = metadata?['content-length']
				return FS.stat(cacheFile.getPath 'data').then (stat) =>
					#console.log stat
					if parseInt(stat.node.size, 10) != parseInt(size, 10)
						@debug 'invalid', file, 'got', stat.node.size, 'expected', size
						@invalid++
						cacheFile.purge()
					else
						@debug 'ok', file
			else
				@debug 'ok', file
				Q()
		.fail (error) =>
			@debug 'error', file, error

module.exports = Cleaner

