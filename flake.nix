{
  description = "neominimap.nvim: a code minimap for Neovim, rendered with octant characters";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));
    in
    {
      packages = forAllSystems (pkgs: rec {
        default = neominimap;
        neominimap = pkgs.vimUtils.buildVimPlugin {
          pname = "neominimap.nvim";
          version = self.shortRev or self.dirtyShortRev or "dev";
          src = self;
          # optional integrations (gitsigns, mini.diff, snacks, ...) are
          # required from their handlers; the generic require-check would try
          # to load them in a bare nvim with none of them installed
          doCheck = false;
        };
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.neovim
            pkgs.lua-language-server
            pkgs.stylua
          ];
        };
      });
    };
}
