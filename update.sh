#!/usr/bin/env bash
set -Eeuo pipefail

set -x -v
defaultSuite='focal'
declare -A suites=(
	[10.2]='bionic'
)
declare -A dpkgArchToBashbrew=(
	[amd64]='amd64'
	[armel]='arm32v5'
	[armhf]='arm32v7'
	[arm64]='arm64v8'
	[i386]='i386'
	[ppc64el]='ppc64le'
	[s390x]='s390x'
)

getRemoteVersion() {
	local version="$1"; shift # 10.4
	local suite="$1"; shift # focal
	local dpkgArch="$1"; shift # arm64

	echo "$(
		curl -fsSL "https://ftp.osuosl.org/pub/mariadb/repo/$version/ubuntu/dists/$suite/main/binary-$dpkgArch/Packages" 2>/dev/null  \
			| tac|tac \
			| awk -F ': ' '$1 == "Package" { pkg = $2; next } $1 == "Version" && pkg == "mariadb-server-'"$version"'" { print $2; exit }'
	)"
}

cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

curl -fsSL https://downloads.mariadb.org/rest-api/mariadb/ \
	| jq '.major_releases[] | [ .release_id ], [ .release_status ]  | @tsv ' \
	| while read version
do
	version=${version//\"}
	if [ ! -d $version ]; then
		echo >&2 "warning: no rule for $version"
		continue
	fi
	suite="${suites[$version]:-$defaultSuite}"
	fullVersion="$(getRemoteVersion "$version" "$suite" 'amd64')"

	read releaseStatus
	releaseStatus=${releaseStatus//\"}

	case "$releaseStatus" in Alpha | Beta | Gamma | RC | "Old Stable" | Stable ) ;; # sanity check
		*) echo >&2 "error: unexpected 'release status' value for $mariaVersion: $releaseStatus"; exit 1 ;;
	esac

	mariaVersion=$( curl -fsSL https://downloads.mariadb.org/rest-api/mariadb/${version} | jq 'first(..|select(.release_id)) | .release_id' )
	mariaVersion=${mariaVersion//\"}

	echo "$version: $mariaVersion ($releaseStatus)"

	arches=
	sortedArches="$(echo "${!dpkgArchToBashbrew[@]}" | xargs -n1 | sort | xargs)"
	for arch in $sortedArches; do
		if ver="$(getRemoteVersion "$version" "$suite" "$arch")" && [ -n "$ver" ]; then
			arches="$arches ${dpkgArchToBashbrew[$arch]}"
		fi
	done

	cp Dockerfile.template "$version/Dockerfile"

	backup='mariadb-backup'
	if [[ "$version" < 10.3 ]]; then
		# 10.2 has mariadb major version in the package name
		backup="$backup-$version"
	fi

	cp docker-entrypoint.sh "$version/"
	sed -i \
		-e 's!%%MARIADB_VERSION%%!'"$fullVersion"'!g' \
		-e 's!%%MARIADB_MAJOR%%!'"$version"'!g' \
		-e 's!%%MARIADB_RELEASE_STATUS%%!'"$releaseStatus"'!g' \
		-e 's!%%SUITE%%!'"$suite"'!g' \
		-e 's!%%BACKUP_PACKAGE%%!'"$backup"'!g' \
		-e 's!%%ARCHES%%!'"$arches"'!g' \
		"$version/Dockerfile"

	case "$version" in
		10.2 | 10.3 | 10.4) ;;
		*) sed -i '/backwards compat/d' "$version/Dockerfile" ;;
	esac

done
