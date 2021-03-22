prefix ?= /usr/local
bindir = $(prefix)/bin
libdir = $(prefix)/lib

build:
	swift build -c release --disable-sandbox

install: build
	install ".build/release/core-bluetooth-tool" "$(bindir)"
	install_name_tool -change \
		"$(bindir)/core-bluetooth-tool"

uninstall:
	rm -rf "$(bindir)/core-bluetooth-tool"

clean:
	rm -rf .build

.PHONY: build install uninstall clean
