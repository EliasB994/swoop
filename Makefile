LABEL   := com.elias.swoop
APP     := build/Swoop.app
BIN     := $(APP)/Contents/MacOS/swoop
AGENT   := $(HOME)/Library/LaunchAgents/$(LABEL).plist
LOG     := $(HOME)/Library/Logs/swoop.log
DOMAIN  := gui/$(shell id -u)
BINDIR  ?= $(shell brew --prefix 2>/dev/null || echo /usr/local)/bin

.PHONY: build run status install uninstall restart logs clean

build: $(BIN)

$(BIN): Sources/main.swift Info.plist
	mkdir -p $(APP)/Contents/MacOS
	cp Info.plist $(APP)/Contents/Info.plist
	swiftc -swift-version 5 -O -o $(BIN) Sources/main.swift -framework ApplicationServices
	codesign --force --sign - --identifier $(LABEL) $(APP)

run: build
	$(BIN) run

status: build
	$(BIN) status

install: build
	mkdir -p $(dir $(AGENT))
	sed -e 's|__BIN__|$(abspath $(BIN))|' -e 's|__LOG__|$(LOG)|' launchd.plist > $(AGENT)
	@launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null || true
	launchctl bootstrap $(DOMAIN) $(AGENT)
	ln -sf $(abspath $(BIN)) $(BINDIR)/swoop
	@echo "Installed. Grant Accessibility to Swoop when prompted (System Settings → Privacy & Security → Accessibility)."

uninstall:
	@launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null || true
	rm -f $(AGENT) $(BINDIR)/swoop

restart:
	launchctl kickstart -k $(DOMAIN)/$(LABEL)

logs:
	tail -f $(LOG)

clean:
	rm -rf build
