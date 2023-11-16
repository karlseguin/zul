const sass = require('sass');
const cheerio = require('cheerio');
const pluginSass = require('@grimlink/eleventy-plugin-sass');
const syntaxHighlight = require('@11ty/eleventy-plugin-syntaxhighlight');

const env = require('./src/_data/env.js');
const package = require('./package.json');

module.exports = function(config) {
	config.addPassthroughCopy('src/assets/docs.js');
	config.addPassthroughCopy('src/assets/favicon.png');
	config.setTemplateFormats(['html', 'njk']);

	config.addCollection("sorted", function(collectionApi) {
		return collectionApi.getAll().sort(function(a, b) {
			return a.url.localeCompare(b.url);
		});
	});

	config.addPlugin(syntaxHighlight);
	config.addPlugin(pluginSass, {
		sass: sass,
		outputPath: '/assets/',
		outputStyle: (env.prod) ? 'compressed' : 'expanded',
	});

	config.addNunjucksGlobal('postMeta', function(post) {
		const $ = cheerio.load(post.content);
		const example = $('pre:first-of-type');
		return {
			desc: $('p').eq(0).text(),
			example: {raw: example.text(), html: example.prop('outerHTML')},
		};
	});

	config.addAsyncFilter('asset_url', async function(url) {
		return env.baseURL + '/assets/' + url + '?v=' + package.version;
	});

	return {
		dir: {
			input: 'src'
		}
	};
};
