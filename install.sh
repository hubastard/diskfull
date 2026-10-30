#!/bin/sh
# Installs diskfull from its GitHub release:
#
#   curl -fsSL https://raw.githubusercontent.com/hubastard/diskfull/main/install.sh | sh
#
# Options, as environment variables (e.g. `... | DISKFULL_VERSION=v1.0.0 sh`):
#   DISKFULL_VERSION  release to install (default: latest)
#   DISKFULL_BIN_DIR  where the diskfull command goes
#                     (default: ~/.local/bin, or /usr/local/bin as root)
#   DISKFULL_APP_DIR  macOS: where DiskFull.app goes
#                     (default: /Applications, or ~/Applications if not writable)
#
# Everything runs from main at the very end, so a partial download does nothing.

set -eu

REPO_URL=https://github.com/hubastard/diskfull
BUILD_DOCS="$REPO_URL#building-from-source"

say() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

download() { # url file
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --retry 3 -o "$2" "$1"
	elif command -v wget >/dev/null 2>&1; then
		wget -q -O "$2" "$1"
	else
		die "curl or wget is needed"
	fi
}

sha256() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d ' ' -f 1
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | cut -d ' ' -f 1
	fi
}

verify() {
	download "$base/SHA256SUMS" "$tmp/SHA256SUMS" || die "could not download $base/SHA256SUMS"
	expected=$(awk -v f="$asset" '$2 == f || $2 == "*" f { print $1 }' "$tmp/SHA256SUMS")
	[ -n "$expected" ] || die "$asset is not listed in SHA256SUMS"
	actual=$(sha256 "$tmp/$asset")
	if [ -z "$actual" ]; then
		warn "sha256sum and shasum not found, skipping the checksum"
	elif [ "$actual" != "$expected" ]; then
		die "checksum mismatch for $asset, try again"
	fi
}

check_glibc() {
	if ldd --version 2>&1 | grep -qi musl; then
		die "the prebuilt binary needs glibc (not musl, e.g. Alpine); build from source: $BUILD_DOCS"
	fi
	v=$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{ print $2 }') || v=
	major=${v%%.*}
	minor=${v#*.}
	minor=${minor%%.*}
	case "$major$minor" in
	'' | *[!0-9]*) return ;;
	esac
	if [ "$major" -lt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -lt 35 ]; }; then
		warn "glibc $v found, diskfull is built for glibc 2.35+ and may not start"
	fi
}

install_macos() {
	ditto -x -k "$tmp/$asset" "$tmp" || die "could not unpack $asset"
	[ -d "$tmp/DiskFull.app" ] || die "DiskFull.app is missing from $asset"

	if [ -n "${DISKFULL_APP_DIR:-}" ]; then
		app_dir=$DISKFULL_APP_DIR
	elif [ -w /Applications ]; then
		app_dir=/Applications
	else
		app_dir=$HOME/Applications
	fi
	app=$app_dir/DiskFull.app
	mkdir -p "$app_dir"
	rm -rf "$app"
	mv "$tmp/DiskFull.app" "$app"

	mkdir -p "$bin_dir"
	ln -sf "$app/Contents/MacOS/diskfull" "$bin_dir/diskfull"
	say "Installed $app"
	say "Installed $bin_dir/diskfull (link to the app)"
}

install_linux() {
	tar -xzf "$tmp/$asset" -C "$tmp" || die "could not unpack $asset"
	mkdir -p "$bin_dir"
	# Copy next to the target then rename, so a running diskfull is not overwritten.
	cp "$tmp/diskfull" "$bin_dir/.diskfull.new"
	chmod 755 "$bin_dir/.diskfull.new"
	mv -f "$bin_dir/.diskfull.new" "$bin_dir/diskfull"
	say "Installed $bin_dir/diskfull"

	# libX11 is linked; libGL is loaded when the window opens.
	missing=$(ldd "$bin_dir/diskfull" 2>/dev/null | awk '/not found/ { printf "%s ", $1 }') || missing=
	ldconfig=$(command -v ldconfig 2>/dev/null) || ldconfig=/sbin/ldconfig
	if [ -x "$ldconfig" ] && libs=$("$ldconfig" -p 2>/dev/null); then
		case "$libs" in
		*libGL.so.1*) ;;
		*) missing="${missing}libGL.so.1" ;;
		esac
	fi
	if [ -n "$missing" ]; then
		warn "missing libraries: $missing"
		warn "install X11 and OpenGL, e.g. 'sudo apt install libx11-6 libgl1' (Debian/Ubuntu),"
		warn "'sudo dnf install libX11 mesa-libGL' (Fedora) or 'sudo pacman -S libx11 mesa' (Arch)"
	fi
}

main() {
	version=${DISKFULL_VERSION:-latest}
	case "$version" in
	latest) base=$REPO_URL/releases/latest/download ;;
	v*) base=$REPO_URL/releases/download/$version ;;
	*)
		version=v$version
		base=$REPO_URL/releases/download/$version
		;;
	esac

	os=$(uname -s)
	arch=$(uname -m)
	case "$os" in
	Darwin)
		# A shell running under Rosetta reports x86_64 on Apple Silicon too.
		if [ "$arch" != arm64 ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" != 1 ]; then
			die "the prebuilt app is for Apple Silicon Macs only; build from source: $BUILD_DOCS"
		fi
		asset=DiskFull-macos-arm64.zip
		;;
	Linux)
		case "$arch" in
		x86_64 | amd64) asset=diskfull-linux-x64.tar.gz ;;
		aarch64 | arm64) asset=diskfull-linux-arm64.tar.gz ;;
		*) die "no prebuilt binary for $arch; build from source: $BUILD_DOCS" ;;
		esac
		check_glibc
		;;
	MINGW* | MSYS* | CYGWIN*)
		die "on Windows, download diskfull-windows-x64.zip from $REPO_URL/releases"
		;;
	*) die "no prebuilt binary for $os; build from source: $BUILD_DOCS" ;;
	esac

	if [ -n "${DISKFULL_BIN_DIR:-}" ]; then
		bin_dir=$DISKFULL_BIN_DIR
	elif [ "$(id -u)" = 0 ]; then
		bin_dir=/usr/local/bin
	else
		bin_dir=$HOME/.local/bin
	fi

	tmp=$(mktemp -d 2>/dev/null || mktemp -d -t diskfull)
	trap 'rm -rf "$tmp"' EXIT
	trap 'exit 130' INT TERM

	say "Downloading $asset ($version)..."
	download "$base/$asset" "$tmp/$asset" ||
		die "could not download $base/$asset (releases: $REPO_URL/releases)"
	verify

	case "$os" in
	Darwin) install_macos ;;
	*) install_linux ;;
	esac

	say ""
	case ":$PATH:" in
	*":$bin_dir:"*) ;;
	*)
		say "$bin_dir is not on your PATH, add it with:"
		case "${SHELL:-}" in
		*/zsh) say "  echo 'export PATH=\"$bin_dir:\$PATH\"' >> ~/.zshrc && exec zsh" ;;
		*/fish) say "  fish_add_path $bin_dir" ;;
		*) say "  echo 'export PATH=\"$bin_dir:\$PATH\"' >> ~/.bashrc && exec bash" ;;
		esac
		say ""
		;;
	esac
	say "Run 'diskfull' to scan the whole disk, or 'diskfull <folder>'."
	if [ "$os" = Darwin ]; then
		say "To see everything, give DiskFull (or your terminal) Full Disk Access:"
		say "System Settings > Privacy & Security > Full Disk Access."
	else
		say "To see everything: sudo \"$bin_dir/diskfull\""
	fi
}

main "$@"
