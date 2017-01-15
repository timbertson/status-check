main.native: main.ml
	ocamlbuild -use-ocamlfind -package str -package unix -package bytes main.native

