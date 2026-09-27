CC := gcc

CFLAGS_COMMON := -Wall -Wextra -Wuninitialized -Wunused-parameter -std=gnu11 -D_GNU_SOURCE
CFLAGS_OPT := -O2
CFLAGS_MATH := #-ffast-math

CFLAGS := $(CFLAGS_COMMON) $(CFLAGS_OPT) $(CFLAGS_MATH)
LDLIBS := -lm

# Codec2-mod branches, each cloned into Codec2-mod-<branch>/ and built as
# codec2_mod-<branch>. They are pulled on every build (always latest).
REPO     := https://github.com/M17-Project/Codec2-mod.git
BRANCHES := main split-no-doubles

# Test settings, e.g.: make run MOD=split-no-doubles N=all SEED=3 JOBS=8
MOD  ?= main
N    ?= 20
SEED ?= 1
JOBS ?= $(shell nproc)

# A MOD outside the list above is cloned and built too.
BRANCHES += $(filter-out $(BRANCHES),$(MOD))

MOD_BINS := $(addprefix codec2_mod-,$(BRANCHES))
REF_BIN  := codec2_ref

# Pull first, then build in a sub-make, so the source lists below are
# read after the checkouts are up to date.
all: sync
	@$(MAKE) --no-print-directory build

sync:
	@set -e; for b in $(BRANCHES); do \
		if [ -d Codec2-mod-$$b/.git ]; then \
			echo "Pulling Codec2-mod ($$b)"; \
			git -C Codec2-mod-$$b pull --ff-only --quiet; \
		else \
			echo "Cloning Codec2-mod ($$b)"; \
			git clone --quiet --branch $$b --single-branch $(REPO) Codec2-mod-$$b; \
		fi; \
	done

build: $(MOD_BINS) $(REF_BIN)

# Rebuild when any source or header of that branch changes (e.g. after a pull).
.SECONDEXPANSION:
codec2_mod-%: modified.c $$(wildcard Codec2-mod-$$*/src/*.c) $$(wildcard Codec2-mod-$$*/inc/*.h)
	$(CC) $(CFLAGS) -I Codec2-mod-$*/inc $(filter %.c,$^) -o $@ $(LDLIBS) -lsndfile

$(REF_BIN): reference.c
	$(CC) $(CFLAGS) $^ -o $@ $(LDLIBS) -lcodec2 -lsndfile

run: all
	MOD=$(MOD) JOBS=$(JOBS) bash run.sh $(N) $(SEED)

clean:
	rm -f codec2_mod-* $(REF_BIN)

# Also removes test results and the Codec2-mod checkouts
# (they are cloned again on the next 'make').
distclean: clean
	rm -rf work
	rm -rf Codec2-mod-*/

.PHONY: all sync build run clean distclean
