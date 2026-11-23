PREFIX ?= $(HOME)/.local
SKILL_DIR ?= $(HOME)/.claude/skills/scrubshot

.PHONY: build test install install-skill uninstall fixtures

build:
	swift build -c release

test:
	swift test

install: build
	mkdir -p $(PREFIX)/bin
	install -m 0755 .build/release/scrubshot $(PREFIX)/bin/scrubshot
	@echo "installed $(PREFIX)/bin/scrubshot"

# Symlinks the agent skill so Claude Code can find it.
install-skill:
	mkdir -p $(dir $(SKILL_DIR))
	ln -sfn $(CURDIR)/skill/scrubshot $(SKILL_DIR)
	@echo "linked $(SKILL_DIR)"

uninstall:
	rm -f $(PREFIX)/bin/scrubshot
	[ -L $(SKILL_DIR) ] && rm $(SKILL_DIR) || true

fixtures:
	SCRUBSHOT_WRITE_FIXTURES=1 swift test --filter testWriteFixturesWhenAsked
