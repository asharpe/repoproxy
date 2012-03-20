var testCase = require('nodeunit').testCase;
var fs = require('fs');
var wrench = require('wrench');
var path = require('path');
var util = require('util');

module.exports = testCase({
	setUp: function (callback) {
		var proxy = this.proxy = require('..').createServer();
		proxy.log.disable();
		
		proxy.addRepo(
			require('../lib/repo').createRepo(
				{prefix: '/foo',}
			)
		);
		proxy.addRepo(
			require('../lib/repo').createRepo(
				{prefix: '/bar',}
			)
		);
		proxy.addRepo(
			require('../lib/repo').createRepo(
				{
					prefix: '/dummy',
					type: 'Dummy',
					paths: {
						foo: {},
						bar: {
							baz: {}
						},
					}
				}
			)
		);
		
		proxy.listen(callback);
    },
    tearDown: function (callback) {
        // clean up
		if (this.proxy) {
			this.proxy.close();
		}
        callback();
    },
	testImmediateChildren: function(test) {
		var http = require('http')

		// timeout test (avoid deadlocks)
		var deadlockTimeout = setTimeout(function() {
			throw("test appears to be deadlocked")
		}, 1000);

		var address = this.proxy.address();

		var client = http.createClient(address.port, '127.0.0.1');

		var req = client.request('GET', '/', {});

		req.end();
		req.on('response', function(res) {
			test.equal('200', res.statusCode);
			res.on('data', function(chunk) {
				if (!this.body) this.body = '';
				this.body += chunk;
			});
			res.on('end', function() {
				test.ok(this.body.match(/href="\/foo\/"/));
				test.ok(this.body.match(/href="\/bar\/"/));
				clearTimeout(deadlockTimeout);
				test.done();
			});
		});
	},
	testTopLevelRepoList: function(test) {
		var http = require('http')

		// timeout test (avoid deadlocks)
		var deadlockTimeout = setTimeout(function() {
			throw("test appears to be deadlocked")
		}, 1000);

		var address = this.proxy.address();

		var client = http.createClient(address.port, '127.0.0.1');

		var req = client.request('GET', '/', {});

		req.end();
		req.on('response', function(res) {
			test.equal('200', res.statusCode);
			res.on('data', function(chunk) {
				if (!this.body) this.body = '';
				this.body += chunk;
			});
			res.on('end', function() {
				test.ok(this.body.match(/href="\/foo\/"/));
				test.ok(this.body.match(/href="\/bar\/"/));
				clearTimeout(deadlockTimeout);
				test.done();
			});
		});
	},
	testRepoIndex: function(test) {
		var http = require('http');

		// timeout test (avoid deadlocks)
		var deadlockTimeout = setTimeout(function() {
			throw("test appears to be deadlocked")
		}, 1000);

		var address = this.proxy.address();

		var client = http.createClient(address.port, '127.0.0.1');

		var req = client.request('GET', '/dummy/', {});

		req.end();
		req.on('response', function(res) {
			test.equal('200', res.statusCode);
			res.on('data', function(chunk) {
				if (!this.body) this.body = '';
				this.body += chunk;
			});
			res.on('end', function() {
				test.ok(this.body.match(/href="foo\/"/));
				test.ok(this.body.match(/href="bar\/"/));
				clearTimeout(deadlockTimeout);
				test.done();
			});
		});
	},
});
