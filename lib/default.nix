{ inputs, ... }:
# A bunch of helper utilities for the project
let
  bpInputs = inputs;
  nixpkgs = bpInputs.nixpkgs;
  lib = nixpkgs.lib;

  # A generator for the top-level attributes of the flake.
  #
  # Designed to work with https://github.com/nix-systems
  mkEachSystem =
    {
      inputs,
      flake,
      systems,
      nixpkgs,
    }:
    let

      # Memoize the args per system
      systemArgs = lib.genAttrs systems (
        system:
        let
          # Resolve the packages for each input.
          perSystem = lib.mapAttrs (
            _: flake: flake.legacyPackages.${system} or { } // flake.packages.${system} or { }
          ) inputs;

          # Handle nixpkgs specially.
          pkgs =
            if (nixpkgs.config or { }) == { } then
              perSystem.nixpkgs
            else
              import inputs.nixpkgs {
                inherit system;
                config = nixpkgs.config;
              };
        in
        lib.makeScope lib.callPackageWith (_: {
          inherit
            inputs
            perSystem
            flake
            pkgs
            system
            ;
        })
      );

      eachSystem = f: lib.genAttrs systems (system: f systemArgs.${system});
    in
    {
      inherit systemArgs eachSystem;
    };

  optionalPathAttrs = path: f: lib.optionalAttrs (builtins.pathExists path) (f path);

  # Imports the path and pass the `args` to it if it exists, otherwise, return an empty attrset.
  tryImport = path: args: optionalPathAttrs path (path: import path args);

  # Maps all the nix files and folders in a directory to name -> path.
  importDir =
    path: fn:
    let
      entries = builtins.readDir path;

      # Get paths to directories
      onlyDirs = lib.filterAttrs (_name: type: type == "directory") entries;
      dirPaths = lib.mapAttrs (name: type: {
        path = path + "/${name}";
        inherit type;
      }) onlyDirs;

      # Get paths to nix files, where the name is the basename of the file without the .nix extension
      nixPaths = builtins.removeAttrs (lib.mapAttrs' (
        name: type:
        let
          nixName = builtins.match "(.*)\\.nix" name;
        in
        {
          name = if type == "directory" || nixName == null then "__junk" else (builtins.head nixName);
          value = {
            path = path + "/${name}";
            type = type;
          };
        }
      ) entries) [ "__junk" ];

      # Have the nix files take precedence over the directories
      combined = dirPaths // nixPaths;
    in
    lib.optionalAttrs (builtins.pathExists path) (fn combined);

  entriesPath = lib.mapAttrs (_name: { path, type }: path);

  # Prefixes all the keys of an attrset with the given prefix
  withPrefix =
    prefix:
    lib.mapAttrs' (
      name: value: {
        name = "${prefix}${name}";
        value = value;
      }
    );

  filterPlatforms =
    system: attrs:
    lib.filterAttrs (
      _: x: if x.meta ? platforms then lib.elem system x.meta.platforms else true # keep every package that has no meta.platforms
    ) attrs;

  mkBlueprint' =
    {
      inputs,
      nixpkgs,
      flake,
      src,
      systems,
    }:
    let
      specialArgs = {
        inherit inputs flake;
        self = throw "self was renamed to flake";
      };

      inherit
        (mkEachSystem {
          inherit
            inputs
            flake
            nixpkgs
            systems
            ;
        })
        eachSystem
        systemArgs
        ;

      # Adds the perSystem argument to the NixOS, Darwin, and standalone Home Manager modules
      perSystemModule =
        { pkgs, ... }:
        {
          _module.args.perSystem = systemArgs.${pkgs.system}.perSystem;
        };

      homes = importDir (src + "/homes") (
        entries:
        let
          loadDefaultFn = { value }@inputs: inputs;

          loadDefault = { pkgs }: path: loadDefaultFn (import path { inherit flake inputs pkgs; });

          loadHomeConfig =
            { pkgs }:
            path: {
              value = inputs.home-manager.lib.homeManagerConfiguration {
                modules = [
                  perSystemModule
                  path
                ];
                extraSpecialArgs = specialArgs;
                inherit pkgs;
              };
            };

          loadHome =
            name:
            { path, type }:
            if builtins.pathExists (path + "/default.nix") then
              eachSystem ({ pkgs, ... }: loadDefault { inherit pkgs; } (path + "/default.nix"))
            else if builtins.pathExists (path + "/home.nix") then
              eachSystem ({ pkgs, ... }: loadHomeConfig { inherit pkgs; } (path + "/home.nix"))
            else
              throw "home profile '${name}' does not have a configuration";
        in
        lib.mapAttrs loadHome entries
      );

      flattenUsernameSystem =
        attrs:
        builtins.foldl' (
          acc: name:
          let
            systems = attrs.${name};
          in
          builtins.foldl' (acc2: system: acc2 // { "${name}@${system}" = systems.${system}; }) acc (
            builtins.attrNames systems
          )
        ) { } (builtins.attrNames attrs);

      homesBySystem = flattenUsernameSystem homes;

      hosts = importDir (src + "/hosts") (
        entries:
        let
          loadDefaultFn = { class, value }@inputs: inputs;

          loadDefault = path: loadDefaultFn (import path { inherit flake inputs; });

          loadNixOS = path: {
            class = "nixos";
            value = inputs.nixpkgs.lib.nixosSystem {
              modules = [
                perSystemModule
                path
              ];
              inherit specialArgs;
            };
          };

          loadNixDarwin = path: {
            class = "nix-darwin";
            value = inputs.nix-darwin.lib.darwinSystem {
              modules = [
                perSystemModule
                path
              ];
              inherit specialArgs;
            };
          };

          loadHost =
            name:
            { path, type }:
            if builtins.pathExists (path + "/default.nix") then
              loadDefault (path + "/default.nix")
            else if builtins.pathExists (path + "/configuration.nix") then
              loadNixOS (path + "/configuration.nix")
            else if builtins.pathExists (path + "/darwin-configuration.nix") then
              loadNixDarwin (path + "/darwin-configuration.nix")
            else
              throw "host '${name}' does not have a configuration";
        in
        lib.mapAttrs loadHost entries
      );

      hostsByCategory = lib.mapAttrs (_: hosts: lib.listToAttrs hosts) (
        lib.groupBy (
          x:
          if x.value.class == "nixos" then
            "nixosConfigurations"
          else if x.value.class == "nix-darwin" then
            "darwinConfigurations"
          else
            throw "host '${x.name}' of class '${x.value.class or "unknown"}' not supported"
        ) (lib.attrsToList hosts)
      );

      moduleDirs = builtins.attrNames (builtins.readDir (src + "/modules"));
      modules = builtins.listToAttrs (
        map (name: {
          name = name;
          value = importDir (src + "/modules/${name}") entriesPath;
        }) moduleDirs
      );
    in
    # FIXME: maybe there are two layers to this. The blueprint, and then the mapping to flake outputs.
    {
      formatter = eachSystem (
        { pkgs, perSystem, ... }: perSystem.self.formatter or pkgs.nixfmt-rfc-style
      );

      lib = tryImport (src + "/lib") specialArgs;

      # expose the functor to the top-level
      # FIXME: only if it exists
      __functor = x: inputs.self.lib.__functor x;

      devShells =
        (optionalPathAttrs (src + "/devshells") (
          path:
          importDir path (
            entries:
            eachSystem (
              { newScope, ... }:
              lib.mapAttrs (pname: { path, type }: newScope { inherit pname; } path { }) entries
            )
          )
        ))
        // (optionalPathAttrs (src + "/devshell.nix") (
          path:
          eachSystem (
            { newScope, ... }:
            {
              default = newScope { pname = "default"; } path { };
            }
          )
        ));

      packages =
        lib.traceIf (builtins.pathExists (src + "/pkgs")) "blueprint: the /pkgs folder is now /packages"
          (
            let
              entries =
                (optionalPathAttrs (src + "/packages") (path: importDir path lib.id))
                // (optionalPathAttrs (src + "/package.nix") (path: {
                  default = {
                    inherit path;
                  };
                }))
                // (optionalPathAttrs (src + "/formatter.nix") (path: {
                  formatter = {
                    inherit path;
                  };
                }));
            in
            eachSystem (
              { newScope, ... }: lib.mapAttrs (pname: { path, ... }: newScope { inherit pname; } path { }) entries
            )
          );

      darwinConfigurations = lib.mapAttrs (_: x: x.value) (hostsByCategory.darwinConfigurations or { });
      nixosConfigurations = lib.mapAttrs (_: x: x.value) (hostsByCategory.nixosConfigurations or { });
      homeConfigurations = lib.mapAttrs (_: x: x.value) homesBySystem;

      inherit modules;
      darwinModules = modules.darwin;
      homeModules = modules.home;
      # TODO: how to extract NixOS tests?
      nixosModules = modules.nixos;

      templates = importDir (src + "/templates") (
        entries:
        lib.mapAttrs (
          name:
          { path, type }:
          {
            path = path;
            # FIXME: how can we add something more meaningful?
            description = name;
          }
        ) entries
      );

      checks = eachSystem (
        { system, pkgs, ... }:
        lib.mergeAttrsList (
          [
            # add all the supported packages, and their passthru.tests to checks
            (withPrefix "pkgs-" (
              lib.concatMapAttrs (
                pname: package:
                {
                  ${pname} = package;
                }
                # also add the passthru.tests to the checks
                // (lib.mapAttrs' (tname: test: {
                  name = "${pname}-${tname}";
                  value = test;
                }) (filterPlatforms system (package.passthru.tests or { })))
              ) (filterPlatforms system (inputs.self.packages.${system} or { }))
            ))
            # build all the devshells
            (withPrefix "devshell-" (inputs.self.devShells.${system} or { }))
            # add nixos system closures to checks
            (withPrefix "nixos-" (
              lib.mapAttrs (_: x: x.config.system.build.toplevel) (
                lib.filterAttrs (_: x: x.pkgs.system == system) (inputs.self.nixosConfigurations or { })
              )
            ))
            # add darwin system closures to checks
            (withPrefix "darwin-" (
              lib.mapAttrs (_: x: x.system) (
                lib.filterAttrs (_: x: x.pkgs.system == system) (inputs.self.darwinConfigurations or { })
              )
            ))
          ]
          ++ (lib.optional (inputs.self.lib.tests or { } != { }) {
            lib-tests = pkgs.runCommandLocal "lib-tests" { nativeBuildInputs = [ pkgs.nix-unit ]; } ''
              export HOME="$(realpath .)"
              export NIX_CONFIG='
              extra-experimental-features = nix-command flakes
              flake-registry = ""
              '

              nix-unit --flake ${flake}#lib.tests ${
                toString (
                  lib.mapAttrsToList (k: v: "--override-input ${k} ${v}") (builtins.removeAttrs inputs [ "self" ])
                )
              }

              touch $out
            '';
          })
        )
      );
    };

  # Create a new flake blueprint
  mkBlueprint =
    {
      # Pass the flake inputs to blueprint
      inputs,
      # Load the blueprint from this path
      prefix ? null,
      # Used to configure nixpkgs
      nixpkgs ? {
        config = { };
      },
      # The systems to generate the flake for
      systems ? inputs.systems or bpInputs.systems,
    }:
    mkBlueprint' {
      inputs = bpInputs // inputs;
      flake = inputs.self;

      inherit nixpkgs;

      src =
        if prefix == null then
          inputs.self
        else if builtins.isPath prefix then
          prefix
        else if builtins.isString prefix then
          "${inputs.self}/${prefix}"
        else
          throw "${builtins.typeOf prefix} is not supported for the prefix";

      # Make compatible with github:nix-systems/default
      systems = if lib.isList systems then systems else import systems;
    };

  tests = {
    testPass = {
      expr = 1;
      expected = 1;
    };
  };
in
{
  inherit
    filterPlatforms
    importDir
    mkBlueprint
    tests
    tryImport
    withPrefix
    ;

  # Make this callable
  __functor = _: mkBlueprint;
}
