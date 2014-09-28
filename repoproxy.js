#!/usr/bin/env node

require("coffee-script");
require('./lib/q-extensions');
var Proxy = require('./lib/proxy');
var Cleaner = require('./lib/cleaner');
var yaml = require('js-yaml');
var fs = require('fs');
var moment = require('moment');

var config = yaml.load(
	fs.readFileSync('./config.yaml', "utf-8")
);

// if cacheDir is relative, make it absolute
if (!config.cacheDir.match(/^\//)) {
	config.cacheDir = process.cwd() + '/' + config.cacheDir;
}

var proxy = new Proxy(config);
proxy.on("log", console.log);
proxy.listen();

var cleaner = new Cleaner(config);
function cleanAndQueue() {
	console.log("Cleaning");
	cleaner.clean().then(function(cleaned) {
		console.log("Clean completed at", moment().format());
		if (cleaned.count) console.log(cleaned.count, 'expired files');
		if (cleaned.invalid) console.log(cleaned.invalid, 'invalid files');
		setTimeout(function() {
			cleanAndQueue();
		}, (config.cleanInterval || 30)*60*1000);
	})
	.fail(function(error) {
		console.log('error while cleaning', error);
	});
}
cleanAndQueue();

