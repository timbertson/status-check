with import <nixpkgs> {};
stdenv.mkDerivation {
	name="statusprompt";
	buildInputs = with ocamlPackages;
		[ ocaml ocamlbuild findlib ];
}
