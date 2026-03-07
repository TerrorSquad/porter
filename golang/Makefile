.PHONY: build clean help

build:
	go build -o porter . && cp porter ~/.local/bin/porter

clean:
	rm -f porter && rm -f ~/.local/bin/porter

serve:
	./porter serve --port=8080 --output-dir=received

help:
	@echo "Available targets:"
	@echo "  make build    - Build the porter binary"
	@echo "  make clean    - Remove the built binary"
	@echo "  make serve    - Start the porter HTTP server"
	@echo "  make help     - Show this help message"