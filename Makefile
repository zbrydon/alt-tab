APP := AltTab.app
BIN := $(APP)/Contents/MacOS/AltTab
# Set to a code-signing identity (e.g. a self-signed cert) so the Accessibility grant survives rebuilds.
SIGN_ID ?= AltTab Local

all: $(BIN)

$(BIN): main.swift Info.plist
	mkdir -p $(APP)/Contents/MacOS
	cp Info.plist $(APP)/Contents/
	swiftc -O -wmo -swift-version 5 -o $@ main.swift
	strip -x $@
	codesign --force --options runtime -s "$(SIGN_ID)" $(APP)

run: all
	-killall AltTab 2>/dev/null
	open $(APP)

install: all
	-killall AltTab 2>/dev/null
	rm -rf ~/Applications/$(APP)
	mkdir -p ~/Applications
	cp -R $(APP) ~/Applications/
	open ~/Applications/$(APP)

reset:
	tccutil reset Accessibility local.alttab
	tccutil reset ScreenCapture local.alttab

clean:
	rm -rf $(APP)

.PHONY: all run install reset clean
