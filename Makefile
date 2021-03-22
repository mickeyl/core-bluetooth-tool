prefix ?= /usr/local
bindir = $(prefix)/bin
libdir = $(prefix)/lib

app = core-bluetooth-tool

build:
	swift build -c release --disable-sandbox

install: build
	install ".build/release/$app" "$(bindir)"
	install_name_tool -change \
		"$(bindir)/$app"

uninstall:
	rm -rf "$(bindir)/$app"

clean:
	rm -rf .build

.PHONY: build install uninstall clean
