#!/usr/bin/env bash
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# Config files
tags_config_file="config/tags.config"
# shellcheck disable=SC2034
hotspot_config_file="config/hotspot.config"

# Test lists
# shellcheck disable=SC2034
test_image_types_file="config/test_image_types.list"
# shellcheck disable=SC2034
test_image_types_all_file="config/test_image_types_all.list"
# shellcheck disable=SC2034
test_buckets_file="config/test_buckets.list"

# All supported JVMs
# shellcheck disable=SC2034 # used externally
all_jvms="hotspot"

# Supported arches for each of the os_families
os_families="linux alpine-linux windows"
linux_arches="aarch64 armv7l ppc64le s390x x86_64"
alpine_linux_arches="x86_64"
windows_arches="windows-amd windows-nano"

# All supported packages
# shellcheck disable=SC2034 # used externally
all_packages="jdk jre"

# All supported runtypes
# shellcheck disable=SC2034 # used externally
all_runtypes="build test"

# Setting the OS's built in test
PR_TEST_OSES="ubuntu"

# `runtype` specifies the reason for running the script, i.e for building images or to test for a PR check
# Supported values for runtype : "build", "test"
# setting default runtype to build (can be changed via `set_runtype` function)
runtype="build"

# Current JVM versions supported
export supported_versions="8 11 16 17"
export latest_version="17"

# Current builds supported
export supported_builds="releases"

function check_version() {
	local version=$1
	case ${version} in
	8|11|16|17)
		;;
	*)
		echo "ERROR: Invalid version"
		;;
	esac
}

# Set a valid version
function set_version() {
	version=$1
	if [ -n "$(check_version "${version}")" ]; then
		echo "ERROR: Invalid Version: ${version}"
		echo "Usage: $0 [${supported_versions}]"
		exit 1
	fi
}

# Set runtype
function set_runtype() {
	runtype=$1
	if [ "${runtype}" != "build" ] && [ "${runtype}" != "test" ]; then
		echo "ERROR: Invalid RunType : ${runtype}"
		echo "Supported Runtypes : ${all_runtypes}"
		exit 1
	fi
}

# Set the valid OSes for the current architecure.
function set_arch_os() {
	if [ ! -z "$TARGET_ARCHITECTURE" ]; then
		# Use buildx environment for build https://www.docker.com/blog/multi-platform-docker-builds/
		echo "overiding machine to $TARGET_ARCHITECTURE"
		machine="$TARGET_ARCHITECTURE"
	else
		machine=$(uname -m)
	fi
	case ${machine} in
	armv7l|linux/arm/v7)
		current_arch="armv7l"
		oses="centos ubuntu"
		os_family="linux"
		;;
	aarch64)
		current_arch="aarch64"
		oses="centos ubuntu"
		os_family="linux"
		;;
	ppc64el|ppc64le)
		current_arch="ppc64le"
		oses="centos ubuntu"
		os_family="linux"
		;;
	s390x)
		current_arch="s390x"
		oses="clefos ubuntu"
		os_family="linux"
		;;
	amd64|x86_64)
		case $(uname) in
			MINGW64*|MSYS_NT*)
				current_arch="x86_64"
				#  windowsservercore-1809 windowsservercore-1803 are not included as Adopt can't build them
				oses="windowsservercore-ltsc2016"
				# this variable will only be set when running under GitHub Actions
				if [ -n "${BUILD_OS}" ]; then
					case ${BUILD_OS} in
					windows-2019)
						oses="windowsservercore-1809 nanoserver-1809 windowsservercore-ltsc2019"
						;;
					windows-2016)
						oses="windowsservercore-ltsc2016"
						;;
					esac
				fi
				os_family="windows"
				;;
			*)
			# shellcheck disable=SC2034 # used externally
			current_arch="x86_64"
			# shellcheck disable=SC2034 # used externally
			oses="alpine centos ubuntu"
			# shellcheck disable=SC2034 # used externally
			os_family="alpine-linux linux"
			;;
		esac
		;;
	*)
		echo "ERROR: Unsupported arch:${machine}, Exiting"
		exit 1
		;;
	esac
}

# get shasums for a given architecture and os_family
# This is based on the hotspot_shasums_latest.sh
# arch = aarch64, armv7l, ppc64le, s390x, x86_64
# os_family = linux, windows
function get_shasum() {
	local arch=$2;
	local os_family=$3;

	if ! declare -p "$1" >/dev/null 2>/dev/null; then
		return;
	fi
	# shellcheck disable=SC2154,SC1083
	local shasum=$(sarray=$1[${os_family}_${arch}]; eval esum=\${"$sarray"}; echo "${esum}");
	echo "${shasum}"
}

# Get the supported architectures for a given VM (Hotspot).
# This is based on the hotspot_shasums_latest.sh
function get_arches() {
	# Check if the array has been defined. Array might be undefined if the
	# corresponding build combination does not exist.
	if ! declare -p "$1" >/dev/null 2>/dev/null; then
		return;
	fi
	local archsums="$(declare -p "$1")";
	eval "declare -A sums=""${archsums#*=}";
	local arch=""
	for arch in "${!sums[@]}";
	do
		if [[ "${arch}" == version* ]] ; then
			continue;
		fi
		# Arch is supported only if the shasum is not empty !
		# alpine-linux is for musl based images
		# shellcheck disable=SC2154,SC1083
		local shasum=$(sarray=$1[${arch}]; eval esum=\${"$sarray"}; echo "${esum}");
		if [ -n "${shasum}" ]; then
			local arch_val=$(echo ${arch} | sed 's/alpine-linux_//; s/linux_//; s/windows_//')
			echo "${arch_val} "
		fi
	done
}

# Check if the given VM is supported on the current architecture.
# This is based on the hotspot_shasums_latest.sh
function vm_supported_onarch() {
	local vm=$1
	local sums=$2

	if [ -n "$3" ]; then
		test_arch=$3;
	else
		test_arch=$(uname -m)
	fi

	local suparches=$(get_arches "${sums}")
	local sup=$(echo "${suparches}" | grep "${test_arch}")
	echo "${sup}"
}

function cleanup_images() {
	# Delete any old containers that have exited.
	docker rm "$(docker ps -a | grep -e 'Exited' | awk '{ print $1 }')" 2>/dev/null
	docker container prune -f 2>/dev/null

	# Delete any old images for our target_repo on localhost.
	for image in $(docker images | grep -e 'adoptopenjdk' | awk -v OFS=':' '{ print $1, $2 }');
	do
		docker rmi -f "${image}";
	done

	# Remove any dangling images
	docker image prune -f 2>/dev/null
}

function cleanup_manifest() {
	# Remove any previously created manifest lists.
	# Currently there is no way to do this using the tool.
	rm -rf ~/.docker/manifests
}

# Check if a given docker image exists on the server.
# This script errors out if the image does not exist.
function check_image() {
	local img=$1

	docker pull "${img}" >/dev/null
	ret=$?
	echo ${ret}
}

# Parse hotspot.config file for an entry as specified by $4
# $1 = VM
# $2 = Version
# $3 = Package
# $4 = OS
# $5 = String to look for.
function parse_vm_entry() {
	entry=$( < config/"$1".config grep -B 4 -E "$2\/$3\/$4$|$2\/$3\/windows\/$4$" | grep "$5" | sed "s/$5 //")
	echo "${entry}"
}

# Parse the hotspot.config file for the supported OSes
# $1 = VM
function parse_os_entry() {
	entry=$( < config/"$1".config grep "^OS:" | sed "s/OS: //")
	echo "${entry}"
}

# Read the tags file and parse the specific tag.
# $1 = OS
# $2 = Package
# $3 = Build (releases / nightly)
# $4 = Type (full / slim)
function parse_tag_entry() {
	tag="$1-$2-$3-$4-tags:"
	entry=$( < "${tags_config_file}" grep "${tag}" | sed "s/${tag} //")
	echo "${entry}"
}

# Where is the manifest tool installed?"
# Manifest tool (docker with manifest support) needs to be added from here
# https://github.com/clnperez/cli
# $ cd /opt/manifest_tool
# $ git clone -b manifest-cmd https://github.com/clnperez/cli.git
# $ cd cli
# $ make -f docker.Makefile cross
manifest_tool_dir="/opt/manifest_tool"
manifest_tool=${manifest_tool_dir}/cli/build/docker

function check_manifest_tool() {
	if docker manifest 2>/dev/null; then
		echo "INFO: Docker manifest found at $(command -v docker)"
		manifest_tool=$(command -v docker)
	else
		if [ ! -f "${manifest_tool}" ]; then
			echo
			echo "ERROR: Docker with manifest support not found at path ${manifest_tool}"
			exit 1
		fi
	fi
}

# Build valid image tags using the tags.config file as the base
function build_tags() {
	local vm=$1; shift
	local ver=$1; shift;
	local pkg=$1; shift;
	local rel=$1; shift;
	local os=$1; shift;
	local build=$1; shift;
	local rawtags=$*
	local tmpfile=raw_arch_tags.$$.tmp

	# For jre builds, replace the version tag to distinguish it from the jdk
	if [ "${pkg}" == "jre" ]; then
		rel="${rel//jdk/jre}"
	fi
	# Get the list of supported arches for this vm / ver /os combo
	local arches=$(parse_vm_entry "${vm}" "${ver}" "${pkg}" "${os}" "Architectures:")
	# Replace the proper version string in the tags
	local rtags=$(echo "${rawtags}" | sed "s/{{ JDK_${build}_VER }}/${rel}/gI; s/{{ OS }}/${os}/gI;");
	echo "${rtags}" | sed "s/{{ *ARCH *}}/{{ARCH}}/" |
	# Separate the arch and the generic alias tags
	awk '{ a=0; n=0;
		for (i=1; i<=NF; i++) {
			if (match($i, "ARCH") > 0) {
				atags[a++]=sprintf(" %s", $i);
			} else {
				natags[n++]=sprintf(" %s", $i);
			}
		}
	} END {
		printf("arch_tags: "); for (key in atags) { printf"%s ", atags[key] }; printf"\n";
		printf("tag_aliases: "); for (key in natags) { printf"%s ", natags[key] }; printf"\n";
	}' > ${tmpfile}

	# shellcheck disable=SC2034 # used externally
	# tag_aliases is a global variable, used for generating manifest list
	tag_aliases=$( < "${tmpfile}" grep "^tag_aliases:" | sed "s/tag_aliases: //")
	local raw_arch_tags=$( < "${tmpfile}" grep "^arch_tags:" | sed "s/arch_tags: //")
	# arch_tags is a global variable
	arch_tags=""
	# Iterate through the arch tags and expand to add the supported arches.
	local tag=""
	local arch=""
	for tag in ${raw_arch_tags}
	do
		for arch in ${arches}
		do
			windows_pat="windows.*"
			if [[ "$arch" =~ ${windows_pat} ]]; then
				arch="x86_64"
			fi
			# Check if all the supported arches are available for this build.
			# shellcheck disable=SC2154 #declared externally
			supported=$(vm_supported_onarch "${vm}" "${shasums}" "${arch}")
			if [ -z "${supported}" ]; then
				continue;
			fi
			# shellcheck disable=SC2001
			atag=$(echo "${tag}" | sed "s/{{ARCH}}/${arch}"/g)
			arch_tags="${arch_tags} ${atag}"
		done
	done
	rm -f ${tmpfile}
}

# Build the URL using adoptopenjdk.net v3 api based on the given parameters
# request_type = feature_releases
# release_type = ga / ea
# url_impl = hotspot
# url_arch = aarch64 / ppc64le / s390x / x64
# url_pkg  = jdk / jre
# url_os_family = linux / windows
function get_v3_url() {
	local request_type=$1
	local release_type=$2
	local url_impl=$3
	local url_pkg=$4
	local url_arch=$5
	local url_os_family=$6
	local url_heapsize="normal"

	if [ "${release_type}" == "releases" ]; then
		rel_type="ga"
	else
		rel_type="ea"
	fi
	baseurl="https://api.adoptium.net/v3/assets/${request_type}/${version}/${rel_type}"
	specifiers="page=0&page_size=1&sort_order=DESC&vendor=adoptium"
	specifiers="${specifiers}&jvm_impl=${url_impl}&image_type=${url_pkg}&heap_size=${url_heapsize}"
	windows_pat="windows.*"
	if [ -n "${url_arch}" ]; then
		if [[ "${url_arch}" =~ ${windows_pat} ]]; then
			specifiers="${specifiers}&architecture=x64&os=windows"
		else
			specifiers="${specifiers}&architecture=${url_arch}"
			if [ -n "${url_os_family}" ]; then
				specifiers="${specifiers}&os=${url_os_family}"
			else
				specifiers="${specifiers}&os=linux"
			fi
		fi
	else
		specifiers="${specifiers}&os=linux"
	fi

	echo "${baseurl}?${specifiers}"
}

# Get the binary github link for a release given a V3 API URL
function get_v3_binary_url() {
	local v3_url=$1
	local info_file=/tmp/info_$$.json

	if ! curl -Lso ${info_file} "${v3_url}" || [ ! -s ${info_file} ]; then
		rm -f ${info_file}
		return;
	fi
	python3 -c "import sys, json; print(json.load(sys.stdin)[0]['binaries'][0]['package']['link'])" < "${info_file}"
	rm -f ${info_file}
}

# Get the installer github link for a release given a V3 API URL
function get_v3_installer_url() {
	local v3_url=$1
	local info_file=/tmp/info_$$.json

	if ! curl -Lso "${info_file}" "${v3_url}" || [ ! -s ${info_file} ]; then
		rm -f ${info_file}
		return;
	fi
	python3 -c "import sys, json; print(json.load(sys.stdin)[0]['binaries'][0]['installer']['link'])" < "${info_file}"
	rm -f ${info_file}
}

# Get the short build version from the full version for this specific arch
# $1 = full version
function get_nightly_short_version() {
	local arch_build=$1
	local arch_full_version=$2

	if [ "${arch_build}" = "nightly" ]; then
		# Remove date and time at the end of full_version for nightly builds.
		# Handle both the old and new date-time formats used by the Adopt build system.
		# Older date-time format - 201809270034
		# shellcheck disable=SC2001
		arch_version=$(echo "${arch_full_version}" | sed 's/-[0-9]\{4\}[0-9]\{2\}[0-9]\{2\}[0-9]\{4\}$//')
		# New date-time format   - 2018-09-27-00-34
		# shellcheck disable=SC2001
		arch_version=$(echo "${arch_version}" | sed 's/-[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-[0-9]\{2\}-[0-9]\{2\}$//')
	else
		arch_version=${arch_full_version}
	fi
	echo "${arch_version}"
}

# Get the shasums for the given specific build and arch combination.
function get_sums_for_build_arch() {
	local ver=$1
	local vm=$2
	local pkg=$3
	local build=$4
	local arch=$5
	local os_family=$6

	if [ -z ${os_family} ]; then
		os_family=linux
	fi
	case ${arch} in
		armv7l)
			LATEST_URL=$(get_v3_url feature_releases "${build}" "${vm}" "${pkg}" arm "${os_family}");
			;;
		aarch64)
			LATEST_URL=$(get_v3_url feature_releases "${build}" "${vm}" "${pkg}" aarch64 "${os_family}");
			;;
		ppc64le)
			LATEST_URL=$(get_v3_url feature_releases "${build}" "${vm}" "${pkg}" ppc64le "${os_family}");
			;;
		s390x)
			LATEST_URL=$(get_v3_url feature_releases "${build}" "${vm}" "${pkg}" s390x "${os_family}");
			;;
		x86_64)
			LATEST_URL=$(get_v3_url feature_releases "${build}" "${vm}" "${pkg}" x64 "${os_family}");
			;;
		windows-amd|windows-nano)
			os_family=windows
			LATEST_URL=$(get_v3_url feature_releases "${build}" "${vm}" "${pkg}" windows "${os_family}");
			;;
		*)
			echo "Unsupported arch: ${arch}"
	esac

	while :
	do
		shasum_file="${arch}_${build}_latest"
		# Bad builds cause the latest url to return an empty file or sometimes curl fails
		if ! curl -Lso "${shasum_file}" "${LATEST_URL}" || [ ! -s "${shasum_file}" ]; then
			echo "Latest url not available at url: ${LATEST_URL}"
			break;
		fi
		# Even if the file is not empty, it might just say "No matches"
		availability=$(grep -e "No matches" -e "Not found" "${shasum_file}");
		# Print the arch and the corresponding shasums to the vm output file
		if [ -z "${availability}" ]; then
			# If there are multiple builds for a single version, then pick the latest one.
			if [ "${arch}" == "windows-amd" ]; then
				shasums_url=$(python3 -c "import sys, json; print(json.load(sys.stdin)[0]['binaries'][0]['installer']['checksum_link'])" < "${shasum_file}")
				if [ -z "$shasums_url" ]; then
					shasums_url=$(python3 -c "import sys, json; print(json.load(sys.stdin)[0]['binaries'][0]['package']['checksum_link'])" < "${shasum_file}")
				fi
			else
				shasums_url=$(python3 -c "import sys, json; print(json.load(sys.stdin)[0]['binaries'][0]['package']['checksum_link'])" < "${shasum_file}")
			fi
			shasum=$(curl -Ls "${shasums_url}" | sed -e 's/<[^>]*>//g' | awk '{ print $1 }');
			# Sometimes shasum files are missing, check for error and do not print on error.
			shasum_available=$(echo "${shasum}" | grep -e "No" -e "Not");
			if [ -n "${shasum_available}" ]; then
				echo "shasum file not available at url: ${shasums_url}"
				break;
			fi
			# Get the release version for this arch from the info file
			arch_build_version=$(python3 -c "import sys, json; print(json.load(sys.stdin)[0]['release_name'])" < "${shasum_file}")
			# For nightly builds get the short version without the date/time stamp
			arch_build_version=$(get_nightly_short_version "${build}" "${arch_build_version}")
			# We compare the JDK version info separately from the VM type info because we may have dot releases
			arch_build_base_version=$(echo "${arch_build_version}" | cut -d_ -f1)
			arch_build_vm_type=$(echo "${arch_build_version}" | cut -s -d_ -f2)
			full_version_base_version=$(echo "${full_version}" | cut -d_ -f1)
			full_version_vm_type=$(echo "${full_version}" | cut -s -d_ -f2)
			# If the latest for the current arch does not match with the latest for the parent arch,
			# then skip this arch.
			# Parent version in this case would be the "full_version" from function get_sums_for_build
			# The parent version will automatically be the latest for all arches as returned by the v2 API
			if [[ "${arch_build_base_version}" != "${full_version_base_version}"* || "${arch_build_vm_type}" != "${full_version_vm_type}" ]]; then
				echo "Parent version not matching for arch ${arch}: ${arch_build_version}, ${full_version}"
				break;
			fi
			# Get the build date for this arch tarball
			arch_last_build_date="$(curl -Lv "${shasums_url}" 2>&1 | grep "Last-Modified" | sed 's/< Last-Modified: //')"
			# Convert to time since 1-1-1970
			arch_last_build_time="$(date --date "${arch_last_build_date}" +%s)"
			# Only print the entry if the shasum is not empty
			if [ -n "${shasum}" ]; then
				printf "\t[version-%s]=\"%s\"\n" "${os_family}_${arch}" "${arch_build_version}" >> "${ofile_sums}"
				printf "\t[version-%s]=\"%s\"\n" "${os_family}_${arch}" "${arch_build_version}" >> "${ofile_build_time}"
				printf "\t[%s]=\"%s\"\n" "${os_family}_${arch}" "${shasum}" >> "${ofile_sums}"
				printf "\t[%s]=\"%s\"\n" "${os_family}_${arch}" "${arch_last_build_time}" >> "${ofile_build_time}"
			fi
		fi
		break;
	done
	rm -f "${shasum_file}"
}

# Get shasums for the build and arch combination given
# If no arch given, generate for all valid arches
function get_sums_for_build() {
	local ver=$1
	local vm=$2
	local pkg=$3
	local build=$4

	info_url=$(get_v3_url feature_releases "${build}" "${vm}" "${pkg}");
	# Repeated requests from a script triggers a error threshold on adoptopenjdk.net
	sleep 1;
	info=$(curl -Ls "${info_url}")
	err=$(echo "${info}" | grep -e "Error" -e "No matches" -e "Not found")
	if [ -n "${err}" ]; then
		return;
	fi
	full_version=$(echo "${info}" | python3 -c "import sys, json; print(json.load(sys.stdin)[0]['release_name'])")
	full_version=$(get_nightly_short_version "${build}" "${full_version}")
	# Declare the array with the proper name for shasums and write to the vm output file.
	printf "declare -A %s_%s_%s_%s_sums=(\n" "${pkg}" "${vm}" "${ver}" "${build}" >> "${ofile_sums}"
	# We have another array for storing the last build time for each arch
	printf "declare -A %s_%s_%s_%s_build_time=(\n" "${pkg}" "${vm}" "${ver}" "${build}" >> "${ofile_build_time}"
	# Capture the full version according to adoptopenjdk
	printf "\t[version]=\"%s\"\n" "${full_version}" >> "${ofile_sums}"
	printf "\t[version]=\"%s\"\n" "${full_version}" >> "${ofile_build_time}"
	# Need to get shasums for each of the OS Families
	# families = alpine-linux, linux and windows
	# alpine-linux is for musl based images
	for os_fam in ${os_families}
	do
		# bash doesnt support '-' in the name of a variable
		# So make alpine-linux as alpine_linux
		local fam="${os_fam//-/_}"
		local arches="${fam}_arches"
		for arch in ${!arches}
		do
			get_sums_for_build_arch "${ver}" "${vm}" "${pkg}" "${build}" "${arch}" "${os_fam}"
		done
	done
	printf ")\n" >> "${ofile_sums}"
	printf ")\n" >> "${ofile_build_time}"

	echo
	echo "sha256sums for the version ${full_version} for build type \"${build}\" is now available in ${ofile_sums}"
	echo
}

# get sha256sums for the specific builds and arches given.
# If no build or arch specified, do it for all valid ones.
function get_shasums() {
	local ver=$1
	local vm=$2
	local pkg=$3
	local build=$4
	local ofile_sums="${vm}_shasums_latest.sh"
	local ofile_build_time="${vm}_build_time_latest.sh"

	# Dont build the shasums array it already exists for the Ver/VM/Pkg/Build combination
	if [ -f "${ofile_sums}" ]; then
		# shellcheck disable=SC1090
		source ./"${vm}"_shasums_latest.sh
		local sums="${pkg}_${vm}_${ver}_${build}_sums"
		# File exists, which means shasums for the VM exists.
		# Now check for the specific Ver/VM/Pg/Build combo
		local suparches=$(get_arches "${sums}")
		if [ -n "${suparches}" ]; then
			return;
		fi
	fi

	if [ -n "${build}" ]; then
		get_sums_for_build "${ver}" "${vm}" "${pkg}" "${build}"
	else
		for build in ${supported_builds}
		do
			get_sums_for_build "${ver}" "${vm}" "${pkg}" "${build}"
		done
	fi
	chmod +x "${ofile_sums}" "${ofile_build_time}"
}

