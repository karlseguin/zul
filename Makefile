F=

.PHONY: t
t:
	TEST_FILTER="${F}" zig build test --summary all -freference-trace

.phony: d
d:
	cd docs && npx @11ty/eleventy --serve --port 5300
