.PHONY: zig_build clean

PRIV_DIR = priv/native

zig_build:
	@command -v zig >/dev/null 2>&1 || { echo ""; echo "ERROR: Zig compiler not found."; echo ""; echo "  Install it with:  brew install zig"; echo "  Or see:           https://ziglang.org/download/"; echo ""; exit 1; }
	mkdir -p $(PRIV_DIR)
	cd zig_src && zig build -Doptimize=ReleaseSafe
	cp zig_src/zig-out/bin/pty_port $(PRIV_DIR)/pty_port

clean:
	rm -rf zig_src/zig-out zig_src/.zig-cache $(PRIV_DIR)/pty_port
