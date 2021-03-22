prefix ?= /usr/local
bindir = $(prefix)/bin
libdir = $(prefix)/lib

APP = core-bluetooth-tool

build:
	swift build -c release --disable-sandbox

install: build
	install ".build/release/$(APP)" "$(bindir)"

uninstall:
	rm -rf "$(bindir)/$(APP)"

clean:
	rm -rf .build

.PHONY: build install uninstall clean
