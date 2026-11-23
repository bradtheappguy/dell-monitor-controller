PREFIX ?= /usr/local
BINDIR := $(PREFIX)/bin

.PHONY: build install uninstall clean

build:
	swift build -c release

install: build
	install -d "$(BINDIR)"
	install -m 755 .build/release/dellmon "$(BINDIR)/dellmon"
	@echo "installed $(BINDIR)/dellmon"

uninstall:
	rm -f "$(BINDIR)/dellmon"

clean:
	swift package clean
