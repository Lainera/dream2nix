{
  jq,
  lib,
  pkgs,
  runCommand,
  stdenv,
  writeText,

  # dream2nix inputs
  builders,
  externals,
  node2nix ? externals.node2nix,
  utils,
  ...
}:

{
  # funcs
  getDependencies,
  getSource,
  buildPackageWithOtherBuilder,

  # attributes
  buildSystemAttrs,
  cyclicDependencies,
  mainPackageName,
  mainPackageVersion,
  packageVersions,
  

  # overrides
  packageOverrides ? {},

  # custom opts:
  standalonePackageNames ? [],
  ...
}@args:

let

  b = builtins;

  # tells if a dependency introduces a cycle
  #   -> needs to be built in a combined derivation
  isCyclic = name: version:
    cyclicDependencies ? "${name}"."${version}";

  mainPackageKey =
    "${mainPackageName}#${mainPackageVersion}";

  nodejsVersion = buildSystemAttrs.nodejsVersion;

  nodejs =
    pkgs."nodejs-${builtins.toString nodejsVersion}_x"
    or (throw "Could not find nodejs version '${nodejsVersion}' in pkgs");

  nodeSources = runCommand "node-sources" {} ''
    tar --no-same-owner --no-same-permissions -xf ${nodejs.src}
    mv node-* $out
  '';

  defaultPackage = packages."${mainPackageName}"."${mainPackageVersion}";

  packages =
    lib.mapAttrs
      (name: versions:
        lib.genAttrs
          versions
          (version:
            if isCyclic name version
                || b.elem name standalonePackageNames then
              makeCombinedPackage name version
            else
              makePackage name version))
      packageVersions;
  
  makeCombinedPackage = name: version:
    let
      built =
        buildPackageWithOtherBuilder {
          inherit name version;
          builder = builders.nodejs.node2nix;
          inject =
            lib.optionalAttrs (cyclicDependencies ? "${name}"."${version}") {
              "${name}"."${version}" =
                cyclicDependencies."${name}"."${version}";
            };
        };
    in
      built.defaultPackage;

  # Generates a derivation for a specific package name + version
  makePackage = name: version:
    let

      deps = getDependencies name version;

      nodeDeps =
        lib.forEach
          deps
          (dep: packages."${dep.name}"."${dep.version}" );

      dependenciesJson = b.toJSON 
        (lib.listToAttrs
          (b.map
            (dep: lib.nameValuePair dep.name dep.version)
            deps));

      pkg =
        stdenv.mkDerivation rec {

          packageName = name;
        
          pname = utils.sanitizeDerivationName name;

          inherit dependenciesJson nodeDeps nodeSources version;

          src = getSource name version;

          buildInputs = [ jq nodejs nodejs.python ];

          # prevents running into ulimits
          passAsFile = [ "dependenciesJson" "nodeDeps" ];

          preBuildPhases = [ "d2nPatchPhase" "d2nInstallDependenciesPhase" ];

          preFixupPhases = [ "d2nPostInstallPhase" ];

          # not used by default but can be enabled if needed
          dontConfigure = true;
          dontBuild = true;

          # can be overridden to define alternative install command
          # (defaults to 'npm run postinstall')
          installScript = null;

          # python script to modify some metadata to support installation
          # (see comments below on d2nPatchPhase)
          fixPackage = "${./fix-package.py}";

          # costs performance and doesn't seem beneficial in most scenarios
          dontStrip = true;
          
          # The default unpackPhase seemed to fail on setting permissions
          # for some packages.
          # TODO: debug nixpkgs unpackPhase and upstream improvement.
          unpackPhase = ''
            runHook preUnpack

            nodeModules=$out/lib/node_modules

            export sourceRoot="$nodeModules/$packageName"

            unpackFile $src

            # Make the base dir in which the target dependency resides first
            mkdir -p "$(dirname "$nodeModules/$packageName")"

            # install source
            if [ -f "$src" ]
            then
                # Figure out what directory has been unpacked
                export packageDir="$(find . -maxdepth 1 -type d | tail -1)"

                # Restore write permissions
                find "$packageDir" -type d -exec chmod u+x {} \;
                chmod -R u+w "$packageDir"

                # Move the extracted tarball into the output folder
                mv "$packageDir" "$sourceRoot"
            elif [ -d "$src" ]
            then
                export strippedName="$(stripHash $src)"

                # Restore write permissions
                chmod -R u+w "$strippedName"

                # Move the extracted directory into the output folder
                mv "$strippedName" "$sourceRoot"
            fi
            
            runHook postUnpack
          '';

          # The python script wich is executed in this phase:
          #   - ensures that the package is compatible to the current system
          #   - ensures the main version in package.json matches the expected
          #   - deletes "devDependencies" and "peerDependencies" from package.json
          #     (might block npm install in case npm install is used)
          #   - pins dependency versions in package.json
          #   - creates symlinks for executables declared in package.json
          # Apart from that:
          #   - Any usage of 'link:' in package.json is replaced with 'file:'
          #   - If package-lock.json exists, it is deleted, as it might conflict
          #     with the parent package-lock.json.
          d2nPatchPhase = ''
            # delete package-lock.json as it can lead to conflicts
            rm -f package-lock.json
   
            # repair 'link:' -> 'file:'
            mv $nodeModules/$packageName/package.json $nodeModules/$packageName/package.json.old
            cat $nodeModules/$packageName/package.json.old | sed 's!link:!file\:!g' > $nodeModules/$packageName/package.json
            rm $nodeModules/$packageName/package.json.old

            # run python script (see commend above):
            cp package.json package.json.bak
            python $fixPackage \
            || \
            # exit code 3 -> the package is incompatible to the current platform
            #  -> Let the build succeed, but don't create lib/node_packages
            if [ "$?" == "3" ]; then
              rm -r $out/*
              echo "Not compatible with system $system" > $out/error
              exit 0
            else
              exit 1
            fi
          '';

          # - links all direct node dependencies into the node_modules directory
          # - adds executables of direct node dependencies to PATH
          # - adds the current node module to NODE_PATH
          # - sets HOME=$TMPDIR, as this is required by some npm scripts
          d2nInstallDependenciesPhase = ''
            # symlink dependency packages into node_modules
            for dep in $(cat $nodeDepsPath); do
              # add bin to PATH
              if [ -d "$dep/bin" ]; then
                export PATH="$PATH:$dep/bin"
              fi

              if [ -e $dep/lib/node_modules ]; then
                for module in $(ls $dep/lib/node_modules); do
                  if [[ $module == @* ]]; then
                    for submodule in $(ls $dep/lib/node_modules/$module); do
                      mkdir -p $nodeModules/$packageName/node_modules/$module
                      echo -e "creating link: $dep/lib/node_modules/$module/$submodule\n  -> $nodeModules/$packageName/node_modules/$module/$submodule"
                      ln -s $dep/lib/node_modules/$module/$submodule $nodeModules/$packageName/node_modules/$module/$submodule
                    done
                  else
                    mkdir -p $nodeModules/$packageName/node_modules/
                    echo -e "creating link: $dep/lib/node_modules/$module\n  -> $nodeModules/$packageName/node_modules/$module"
                    ln -s $dep/lib/node_modules/$module $nodeModules/$packageName/node_modules/$module
                  fi
                done
              fi
            done

            export NODE_PATH="$NODE_PATH:$nodeModules/$packageName/node_modules"

            export HOME=$TMPDIR
          '';

          # Run the install command which defaults to 'npm run postinstall'.
          # Set alternative install command by overriding 'installScript'.
          installPhase = ''
            runHook preInstall

            # execute install command
            if [ -n "$installScript" ]; then
              if [ -f "$installScript" ]; then
                exec $installScript
              else
                echo "$installScript" | bash
              fi
            elif [ "$(jq '.scripts.postinstall' ./package.json)" != "null" ]; then
              npm --production --offline --nodedir=$nodeSources run postinstall
            fi

            runHook postInstall
          '';

          # Symlinks executables and manual pages to correct directories
          d2nPostInstallPhase = ''
            # Create symlink to the deployed executable folder, if applicable
            if [ -d "$nodeModules/.bin" ]
            then
              chmod +x $nodeModules/.bin/*
              ln -s $nodeModules/.bin $out/bin
            fi

            # Create symlinks to the deployed manual page folders, if applicable
            if [ -d "$nodeModules/$packageName/man" ]
            then
              mkdir -p $out/share
              for dir in "$nodeModules/$packageName/man/"*
              do
                mkdir -p $out/share/man/$(basename "$dir")
                for page in "$dir"/*
                do
                    ln -s $page $out/share/man/$(basename "$dir")
                done
              done
            fi
          '';
        };
    in
      # apply packageOverrides to current derivation
      (utils.applyOverridesToPackage packageOverrides pkg name);


in
{
  inherit defaultPackage packages;
}