REX ?= $(HOME)/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex
LUA ?= lua

.PHONY: test unit verify reload

test: unit

unit:
	@$(LUA) scripts/test_steps.lua > /dev/null && echo "steps ok"
	@$(LUA) scripts/test.lua

verify:
	@scripts/verify.sh

reload:
	@"$(REX)" config reload
