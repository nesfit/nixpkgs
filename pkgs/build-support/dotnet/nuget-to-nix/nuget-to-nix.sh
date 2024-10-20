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
trap "printf ']\n'" EXIT

excluded_list=$(realpath "${2:-/dev/null}")

export DOTNET_NOLOGO=1
export DOTNET_CLI_TELEMETRY_OPTOUT=1

mapfile -t sources < <(dotnet nuget list source --format short | awk '/^E / { print $2 }')
wait "$!"

declare -A base_addresses
declare -A query_services

nuget_config_path="@nugetConfig@"
if [[ -z $nuget_config_path ]]; then
  nuget_config_relative_path=$(find . -iname 'NuGet.Config' | sort | head -n 1) # case-insensitive search
  if [[ -n $nuget_config_relative_path ]]; then
      nuget_config_path=$(realpath "$nuget_config_relative_path")
  else
      echo "No NuGet.Config file provided" >&2
  fi
fi

for index in "${sources[@]}"; do
  if [[ -d "$index" ]]; then
        continue
    fi
  query_services[$index]=$(
    curl --compressed --netrc -fL "$index" 2>/dev/null | \
      jq -r '[.resources[] | select(."@type" == "SearchQueryService")."@id"].[0]')

  base_address=$(
    curl --compressed --netrc -fsL "$index" 2>/dev/null | \
      jq -r '.resources[] | select(."@type" == "PackageBaseAddress/3.0.0")."@id"')
  if [[ -n "$base_address" && ! "$base_address" == */ ]]; then
    base_address="$base_address/"
  fi
  base_addresses[$index]="$base_address"
done

get_nuget_package_source () {
  # $1 = source
  # $2 = nuget_config_path
  xq -r '.configuration.packageSources.add[]? | select(.["@value"] == "'$1'").["@key"]' $2
}

get_nuget_user () {
  # $1 = NUGET_NAME
  # $2 = nuget_config_path
  xq -r '.configuration.packageSourceCredentials.["'$1'"].add[]? | select(.["@key"] == "Username").["@value"]' $2
}

get_nuget_pass () {
  # $1 = NUGET_NAME
  # $2 = nuget_config_path
  xq -r '.configuration.packageSourceCredentials.["'$1'"].add[]? | select(.["@key"] == "ClearTextPassword").["@value"]' $2
}

get_nuget_config_param () {
  # $1 = source
  # $2 nuget_config_path

  if [[ -z $nuget_config_path ]]; then
    return
  fi

  NUGET_NAME="$(get_nuget_package_source $source $nuget_config_path)"
  if [ $NUGET_NAME ]; then
    NUGET_USER="$(get_nuget_user $NUGET_NAME $nuget_config_path)"
    NUGET_PASS="$(get_nuget_pass $NUGET_NAME $nuget_config_path)"
  fi

  if [ $NUGET_USER ]; then
    echo "nugetUser = \"$NUGET_USER\"; nugetPass = \"$NUGET_PASS\"; "
  else
    echo "couldn't find nuget package source $source definition in $nuget_config_path", nugetUser=$NUGET_USER, nugetPass=$NUGET_PASS  >&2
    exit 0
  fi
}

try_get_package_content_url_from_source () {
  source="$1"
  # Remove the protocol (https://) from the beginning of the URL
  package_source_host="${source#*://}"

  # Remove everything after the first slash to get the hostname
  package_source_host="${package_source_host%%/*}"

  netrc_filepath="$PWD"/.netrc-nuget
  api_json_tmp_path="$PWD/.temp"

  if [ $nuget_config_path ]; then
    NUGET_NAME="$(get_nuget_package_source $source $nuget_config_path)"
    if [ $NUGET_NAME ]; then
      NUGET_USER="$(get_nuget_user $NUGET_NAME $nuget_config_path)"
      NUGET_PASS="$(get_nuget_pass $NUGET_NAME $nuget_config_path)"
    else
      echo "couldn't find nuget package source $source definition in $nuget_config_path" >&2
    fi
  fi

  if [[ -n $nuget_config_path && -n $NUGET_USER ]]; then
    echo "machine $package_source_host login $NUGET_USER password $NUGET_PASS" > $netrc_filepath
  else
    echo > $netrc_filepath
  fi

  package_info_source="${query_services[$source]}"
  if [ -z $package_info_source ]; then
    echo "couldn't match corresponding nuget source address with $source" >&2
    exit 0
  fi

  curl --compressed --netrc-file $netrc_filepath -fL "${query_services[$source]}?q=${id}" 2>/dev/null > $api_json_tmp_path
  if [ $(jq -r '.totalHits' < $api_json_tmp_path) -eq 0 ]; then
    echo "couldn't find nuget package $package at ${query_services[$source]}" >&2
    exit 0
  fi

  package_info_url="$(jq -r '.data[] | select(.id | test("^'$package'$"; "i")).versions[] | select(.version == "'$version'")."@id"' < $api_json_tmp_path)"
  if [ "$package_info_url" == "null" ]; then
    echo "couldn't find nuget package $package with $version at ${query_services[$source]}, found $package_info" >&2
    exit 0
  fi

  package_content_url=$(
    curl --compressed --netrc-file "$netrc_filepath" -fL "${package_info_url}" 2>/dev/null | \
    jq -r '.packageContent // empty')

  echo $package_content_url
}

echo "{ fetchNuGet }: ["

pushd "$pkgs"  > /dev/null 2>&1
for package in *; do
  [[ -d "$package" ]] || continue
  pushd "$package"  > /dev/null 2>&1
  for version in *; do
    id=$(xmlstarlet sel -t -v /_:package/_:metadata/_:id "$version"/*.nuspec)

    if grep -qxF "$id.$version.nupkg" "$excluded_list"; then
      continue
    fi

    # packages in the nix store should have an empty metadata file
    used_source="$(jq -r 'if has("source") then .source else "" end' "$version"/.nupkg.metadata)"
    if [[ -z "$used_source" || -d "$used_source" ]]; then
      continue
    fi

    package_content_url=""
    for source in "${sources[@]}"; do
      if [[ "$source" == "$used_source" ]]; then
        hash="$(nix-hash --type sha256 --flat --sri "$version/$package.$version".nupkg)"
        break
      else
        package_content_url="${base_addresses[$source]}$package/$version/$package.$version.nupkg"
        if hash=$(nix-prefetch-url "$package_content_url" 2>"$tmp"/error); then
          hash="$(nix-hash --to-sri --type sha256 "$hash")"
          # If multiple remote sources are enabled, nuget will try them all
          # concurrently and use the one that responds first. We always use the
          # first source that has the package.
          echo "$package $version is available at $package_content_url, but was restored from $used_source" 1>&2
          break
        fi
      fi
    done

    if [[ -z ${hash} ]]; then
      echo "couldn't find $package $version" >&2
      exit 1
    fi

    # Speed-up, majority of packages are hosted on https://api.nuget.org
    if [[ "$source" =~ ^https://api.nuget.org ]]; then
      if [ -z "${package_content_url}" ]; then
        echo "  (fetchNuGet { pname = \"$id\"; version = \"$version\"; hash = \"$hash\"; })"
      else      
        echo "  (fetchNuGet { pname = \"$id\"; version = \"$version\"; hash = \"$hash\"; url = \"$package_content_url\"; })"
      fi
      continue
    fi

    # Search Nuget.Config sources for package content url
    for index in "${sources[@]}"; do
      source=$index
      package_content_url=$(try_get_package_content_url_from_source $source)
      if [[ ! -z $package_content_url ]]; then
        break
      fi
    done

    if [[ -z ${package_content_url} ]]; then
      echo "couldn't find $package $version url" >&2
      exit 1
    else      
      nuget_config_param=$(get_nuget_config_param $source $nuget_config_path)
      if [[ -z ${nuget_config_param} ]]; then # unauthenticated package source
        echo "  (fetchNuGet { pname = \"$id\"; version = \"$version\"; sha256 = \"$hash\"; url = \"$package_content_url\"; })"
      else # authenticated package source
        echo "  (fetchNuGet { pname = \"$id\"; version = \"$version\"; sha256 = \"$hash\"; url = \"$package_content_url\"; $nuget_config_param })"
      fi
    fi 
    
  done
  popd  > /dev/null 2>&1
done


