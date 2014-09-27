
Q = require('q')

Q.linearise = (promises) ->
	result = Q.resolve()
	result = result.then(f) for f in promises
	result

