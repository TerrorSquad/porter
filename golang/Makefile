.PHONY: build clean help

build:
	go build -o porter . && cp porter ~/.local/bin/porter

clean:
	rm -f porter && rm -f ~/.local/bin/porter

help:
	@echo "Available targets:"
	@echo "  make build    - Build the porter binary"
	@echo "  make clean    - Remove the built binary"
