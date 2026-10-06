# HoppScreen — build & service control (the single entry point)
#   make run      build if needed, then run in the FOREGROUND (ctrl-c stops)
#   make start    build if needed, then run in the background (log: server.log)
#   make stop | restart | status | log | build | help
# The background server writes to server.log and its pid to server.pid.
# Run make from this directory.

BIN     := hoppscreen
PIDFILE := server.pid
LOG     := server.log
# readiness-probe port — set this too if ARGS changes the port
PORT    ?= 8080
# server args [width_pt height_pt port fps] passed straight to the binary.
# EMPTY by default: the server then auto-fits its display to the first client
# that opens the page. Setting ARGS (e.g. ARGS="1680 1050") pins the size and
# disables auto-fit.
ARGS    ?=

.DEFAULT_GOAL := help
.PHONY: help run start stop restart status log build

help:
	@echo "HoppScreen — make <target>"
	@echo "  run        build if needed, run in the foreground (ctrl-c stops)"
	@echo "  start      build if needed, run in the background (log: $(LOG))"
	@echo "  stop       graceful stop (also removes the virtual display)"
	@echo "  restart    stop + start"
	@echo "  status     running? pid, uptime, /status json, recent log"
	@echo "  log        follow the server log (ctrl-c to leave)"
	@echo "  build      compile only (run/start do this automatically)"
	@echo "  vars:      ARGS=\"1680 1050\" pins the display size (PORT=8080 for the probe)"

# staleness (missing binary / newer sources) is make's own dependency check
$(BIN): server.m virtualdisplay.m virtualdisplay.h
	clang -fobjc-arc -O2 -I. \
	    -framework Foundation -framework CoreGraphics -framework AppKit \
	    -framework VideoToolbox -framework CoreMedia -framework CoreVideo \
	    -framework ScreenCaptureKit -framework IOSurface -framework Security \
	    server.m virtualdisplay.m -o $(BIN)

build: $(BIN)

# foreground mode (certs -> exec the server)
run: build
	@./certs.sh || echo "warning: certificate setup failed — HTTPS disabled"
	@exec ./$(BIN) $(ARGS)

start: build
	@if [ -f $(PIDFILE) ] && kill -0 $$(cat $(PIDFILE)) 2>/dev/null; then \
	    echo "already running (pid $$(cat $(PIDFILE))) — try: make restart"; exit 0; fi
	@./certs.sh || echo "warning: certificate setup failed — HTTPS disabled"
	@nohup ./$(BIN) $(ARGS) >$(LOG) 2>&1 & echo $$! >$(PIDFILE)
	@for i in $$(seq 1 40); do \
	    if curl -s -m 1 "http://127.0.0.1:$(PORT)/status" >/dev/null 2>&1; then \
	        echo "running (pid $$(cat $(PIDFILE))) — log: $(LOG)"; \
	        grep -m1 "\[auth\]" $(LOG) 2>/dev/null || true; \
	        exit 0; \
	    fi; \
	    if ! kill -0 $$(cat $(PIDFILE)) 2>/dev/null; then \
	        echo "server exited during startup — last log lines:"; \
	        tail -n 15 $(LOG) 2>/dev/null; rm -f $(PIDFILE); exit 1; \
	    fi; \
	    sleep 0.5; \
	done; \
	echo "still starting (a rebuild takes ~10s) — check with: make status"

stop:
	@if [ -f $(PIDFILE) ] && kill -0 $$(cat $(PIDFILE)) 2>/dev/null; then \
	    PIDS=$$(cat $(PIDFILE)); \
	else \
	    rm -f $(PIDFILE) 2>/dev/null; \
	    PIDS=$$(pgrep -x $(BIN) | tr '\n' ' '); \
	fi; \
	if [ -z "$$PIDS" ]; then echo "not running"; exit 0; fi; \
	echo "stopping:$$PIDS"; kill $$PIDS 2>/dev/null || true; \
	for i in $$(seq 1 20); do \
	    alive=""; for p in $$PIDS; do kill -0 $$p 2>/dev/null && alive="$$alive $$p"; done; \
	    [ -z "$$alive" ] && break; sleep 0.5; \
	done; \
	alive=""; for p in $$PIDS; do kill -0 $$p 2>/dev/null && alive="$$alive $$p"; done; \
	if [ -n "$$alive" ]; then echo "not exiting — SIGKILL:$$alive"; kill -9 $$alive 2>/dev/null || true; sleep 1; fi; \
	rm -f $(PIDFILE); echo "stopped"

restart: stop start

status:
	@if [ -f $(PIDFILE) ] && kill -0 $$(cat $(PIDFILE)) 2>/dev/null; then \
	    PID=$$(cat $(PIDFILE)); \
	else \
	    PID=$$(pgrep -x $(BIN) | head -n1); \
	fi; \
	if [ -z "$$PID" ]; then echo "$(BIN): not running"; exit 0; fi; \
	echo "$(BIN): running (pid $$PID, uptime $$(ps -p $$PID -o etime= | tr -d ' '))"; \
	echo "  /status: $$(curl -s -m 2 http://127.0.0.1:$(PORT)/status || echo unreachable)"; \
	echo "  log tail:"; tail -n 3 $(LOG) 2>/dev/null | awk '{print "    " $$0}'

log:
	@tail -n 50 -f $(LOG)
