{ stdenv, ocamlPackages }:
stdenv.mkDerivation {
	name="status-check";
	buildInputs = with ocamlPackages;
		[ ocaml ocamlbuild findlib ];
	installPhase = "bash ./install.sh $out";
	src = ./.;
}
