#!/usr/bin/env node

/**
 */

var http = require('http');
var _s = require('underscore.string');
var fs = require('fs');
var firstRequest = true;
var etag = '"test-etag"';

var server = http.createServer(function (req, res) {
	if (firstRequest) {
		firstRequest = false;
		res.writeHead(200, {
			'Content-Type': 'text/plain',
			'ETag': etag
		});
		sendChunk(res);
	}
	else if (req.headers['if-none-match'] == etag) {
		res.writeHead(302, {});
		res.end();
// success, shut it down
		server.close();
	}
	else {
		res.writeHead(404, {'Content-Type': 'text/plain'});
		res.end("Oops!");
// fail, shut it down
		server.close();
	}
});

server.listen(function() {
	fs.writeFileSync(__dirname + '/server_port.tmp', server.address().port);
});

var sent = 0;
var line = _s.repeat("foo", 341) + "\n"; // 1024 characters
var limit = 100; // 100 KB

function sendChunk(res) {
	res.write(line);
	sent++;

	if (sent >= limit) {
		res.end();
	} else {
		sendChunk(res);
	}
}
