{
  description = "Nix flake provide libudev library depenency for OpalKelly FrontPanel API";

  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1.*.tar.gz";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = { self, nixpkgs, flake-utils, poetry2nix }:
    flake-utils.lib.eachSystem ["x86_64-linux" "x86_64-darwin" "aarch64-linux" "aarch64-darwin"] (system:
    let
      pkgs = import nixpkgs { inherit system; };
      python3_visualize = pkgs.python3.withPackages (ps: with ps; [
        ipython
        jupyter-core
        # Include the WebIO extension here
        (
          buildPythonPackage rec {
            pname = "webio_jupyter_extension";
            version = "0.1.0";
            src = fetchPypi {
              inherit pname version;
              hash = "sha256-m0FJa4bdC1c02Z+YeFumjPSzzXWuXHBLl7usvxmO0rc=";
            };
            doCheck = false;
            propagatedBuildInputs = [
              # Specify dependencies
              jupyter-packaging
            ];
          }
        )
      ]);
      # NOTE: This uses the directory that was copied in the flake derivation rather than current path
      # This could be good for CI, but not so good for devShell, where the code changes dynamically
      # => Use this for CI only
      pwd = builtins.toString ./.;
    in
    {
      devShells = {
        default = pkgs.mkShell.override
          {
            # Override stdenv in order to change compiler:
            # stdenv = pkgs.clangStdenv;
          }
          {
            packages = with pkgs; [
              python3_visualize
              pkg-config
              udev
              # GR.jl # Runs even without Xrender and Xext, but cannot save files, so those are required
              xorg.libXt
              xorg.libX11
              xorg.libXrender
              xorg.libXext
              stdenv.cc.cc.lib qt5.qtbase qt5Full libGL
              glxinfo
              glfw
              freetype
              stdenv.cc.cc
            ] ++ (if system == "aarch64-darwin" then [ ] else [ gdb ]);

            env = {
                PYTHON = "${python3_visualize}/bin/python";
                JUPYTER = "${python3_visualize}/bin/jupyter";
            };

            NIX_LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [
              pkgs.stdenv.cc.cc
            ];

              #NIX_LD = builtins.readFile "${pkgs.stdenv.cc}/nix-support/dynamic-linker";

            shellHook = ''
              export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:${pkgs.udev}/lib:${pkgs.stdenv.cc.cc.lib}/lib
              # IJulia doesn't need to be part of this package, as this is necessary just for the example notebooks
              julia --project -e 'using Pkg; Pkg.add("IJulia"); using IJulia; installkernel("julia-qc", "--project=$(pwd())");'
            '';
          };
        };
    });
}

