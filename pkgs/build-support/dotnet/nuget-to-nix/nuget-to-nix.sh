#!@runtimeShell@

set -euo pipefail
shopt -s nullglob

export SSL_CERT_FILE=@cacert@/etc/ssl/certs/ca-bundle.crt
export PATH="@binPath@:$PATH"
# used for glob ordering of package names
export LC_ALL=C

if [ $# -eq 0 ]; then
  >&2 echo "Usage: $0 <packages directory> [path to a file with a list of excluded packages] > deps.nix"
  exit 1
fi

pkgs=$1
tmp=$(realpath "$(mktemp -td nuget-to-nix.XXXXXX)")
trap 'rm -r "$tmp"' EXIT

excluded_list=$(realpath "${2:-/dev/null}")

export DOTNET_NOLOGO=1
export DOTNET_CLI_TELEMETRY_OPTOUT=1

mapfile -t sources < <(dotnet nuget list source --format short | awk '/^E / { print $2 }')
wait "$!"

declare -a remote_sources
declare -A base_addresses

nuget_config_path="@nugetConfig@"

for index in "${sources[@]}"; do
    if [[ -d "$index" ]]; then
        continue
    fi

    remote_sources+=($index)

    base_address=$(
    curl --compressed --netrc -fsL "$index" | \
      jq -r '.resources[] | select(."@type" == "PackageBaseAddress/3.0.0")."@id"')
    if [[ ! "$base_address" == */ ]]; then
      base_address="$base_address/"
    fi
    base_addresses[$index]="$base_address"
done

echo "{ fetchNuGet }: ["

cd "$pkgs"
for package in *; do
  [[ -d "$package" ]] || continue
  cd "$package"
  for version in *; do
    id=$(xmlstarlet sel -t -v /_:package/_:metadata/_:id "$version"/*.nuspec)

    if grep -qxF "$id.$version.nupkg" "$excluded_list"; then
      continue
    fi

    # packages in the nix store should have an empty metadata file
    used_source="$(jq -r 'if has("source") then .source else "" end' "$version"/.nupkg.metadata)"
    found=false

    if [[ -z "$used_source" || -d "$used_source" ]]; then
      continue
    fi

    for source in "${remote_sources[@]}"; do
      url="${base_addresses[$source]}$package/$version/$package.$version.nupkg"
      if [[ "$source" == "$used_source" ]]; then
        hash="$(nix-hash --type sha256 --flat --sri "$version/$package.$version".nupkg)"
        found=true
        break
      else
        if hash=$(nix-prefetch-url "$url" 2>"$tmp"/error); then
          hash="$(nix-hash --to-sri --type sha256 "$hash")"
          # If multiple remote sources are enabled, nuget will try them all
          # concurrently and use the one that responds first. We always use the
          # first source that has the package.
          echo "$package $version is available at $url, but was restored from $used_source" 1>&2
          found=true
          break
        else
          if ! grep -q 'HTTP error 404' "$tmp/error"; then
            cat "$tmp/error" 1>&2
            exit 1
          fi
        fi
      fi
    done

    if [[ $found = false ]]; then
      echo "couldn't find $package $version" >&2
      exit 1
    fi

    if [[ "$source" != https://api.nuget.org/v3/index.json ]]; then
      if [ $nuget_config_path ]; then
        NUGET_NAME="$(xq -r '.configuration.packageSources.add[] | select(.["@value"] == "'$source'").["@key"]' ${nuget_config_path})"
        if [ $NUGET_NAME ]; then
          NUGET_USER="$(xq -r '.configuration.packageSourceCredentials.["'$NUGET_NAME'"].add[] | select(.["@key"] == "Username").["@value"]' ${nuget_config_path})"
          NUGET_PASS="$(xq -r '.configuration.packageSourceCredentials.["'$NUGET_NAME'"].add[] | select(.["@key"] == "ClearTextPassword").["@value"]' ${nuget_config_path})"
          nuget_config_param="nugetUser = \"$NUGET_USER\"; nugetPass = \"$NUGET_PASS\"; "
        fi
      fi
      echo "  (fetchNuGet { pname = \"$id\"; version = \"$version\"; hash = \"$hash\"; url = \"$url\"; $nuget_config_param})"
    else
      echo "  (fetchNuGet { pname = \"$id\"; version = \"$version\"; hash = \"$hash\"; })"
    fi
  done
  cd ..
done

cat << EOL
]
EOL
