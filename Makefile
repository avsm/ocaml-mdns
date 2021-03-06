.PHONY: all clean distclean setup build doc install reinstall mirclean mirtest test
all: build

J ?= 2
PREFIX ?= /usr/local
NAME=mdns

LWT ?= $(shell if ocamlfind query lwt.unix >/dev/null 2>&1; then echo --enable-lwt; fi)
MIRAGE ?= $(shell if ocamlfind query mirage-types >/dev/null 2>&1; then echo --enable-mirage; fi)
ASYNC ?= $(shell if ocamlfind query async >/dev/null 2>&1; then echo --enable-async; fi)
TESTS ?= --enable-tests
COVERAGE ?=

-include Makefile.config

setup.data: setup.bin
	./setup.bin -configure $(LWT) $(ASYNC) $(MIRAGE) $(TESTS) $(COVERAGE) --prefix $(PREFIX)

distclean: setup.data setup.bin
	./setup.bin -distclean $(OFLAGS)
	$(RM) setup.bin

setup: setup.data

build: setup.data  setup.bin
	./setup.bin -build -j $(J) $(OFLAGS)

clean:
	ocamlbuild -clean
	rm -f setup.data setup.bin

doc: setup.data setup.bin
	./setup.bin -doc -j $(J) $(OFLAGS)

install: 
	ocamlfind remove $(NAME) $(OFLAGS)
	./setup.bin -install

reinstall: clean build install

setup.bin: setup.ml
	ocamlopt.opt -o $@ $< || ocamlopt -o $@ $< || ocamlc -o $@ $<
	$(RM) setup.cmx setup.cmi setup.o setup.cmo

mirclean:
	cd lib_test/mirage && mirage clean

mirtest: install
	cd lib_test/mirage && mirage configure --unix
	$(MAKE) -C lib_test/mirage

# https://forge.ocamlcore.org/tracker/index.php?func=detail&aid=1363&group_id=162&atid=730
test: build
	./setup.bin -test -runner sequential

coverage: build
	rm -f lib_test/ounit/bisect*.out
	./setup.bin -test -runner sequential
	bisect-report -html _build/coverage -I _build/ lib_test/ounit/bisect*.out

