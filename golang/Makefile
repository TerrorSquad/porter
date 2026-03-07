.PHONY: build clean help

GOROOT := /home/gninkovic/go
GOPROXY := https://proxy.golang.org,direct
GOSUMDB := off

build:
	GOROOT=$(GOROOT) GOPROXY=$(GOPROXY) GOSUMDB=$(GOSUMDB) $(GOROOT)/bin/go build -o porter .

clean:
	rm -f porter

help:
	@echo "Available targets:"
	@echo "  make build    - Build the porter binary"
	@echo "  make clean    - Remove the built binary"
