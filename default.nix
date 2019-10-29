with import <nixpkgs> {};
stdenv.mkDerivation {
	name="status-check";
	buildInputs = with ocamlPackages;
		[ ocaml ocamlbuild findlib ];
	installPhase = "bash ./install.sh $out";
	src = builtins.fetchGit { url = ./.; };
}
