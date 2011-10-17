/**
 * Really basic test cases only
 */
var testCase = require('nodeunit').testCase;
var helper = require('./lib/helper')

module.exports = testCase({
	/**
	 * Repos can be added after createServer()
	 */
    testAddRepo: function (test) {
		var proxy = require('..').createServer()

		test.equal(proxy.repos.toString(), [].toString(), 'Repos should be empty to start with');

		proxy.repos.push({
			'type': 'foo',
		});

		test.equal(proxy.repos.toString(), [ {type: 'foo'} ].toString(), 'There should be exactly one repo now');

        test.done();
    },
});