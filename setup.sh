#!/bin/sh
# setup.sh - install / uninstall / check / test the mux package into a prefix.
# The SINGLE entry point a consumer uses (a person, or a provisioning layer):
# mux owns its own layout, so nothing outside needs to know where bin, libexec,
# share, and man live. The runtime command stays `mux` (bin/mux); this only
# wires it in and audits it.
#
#   ./setup.sh install     link core bin + libexec + share + man (NO indicator)
#   ./setup.sh uninstall   remove those links
#   ./setup.sh check       audit install + deps; [OK]/[FAIL] markers; drift rc
#   ./setup.sh test        run the in-repo test suite (test/run)
#   ./setup.sh version     the packaged version
#   ./setup.sh all         install + the optional tray indicator
#   ./setup.sh indicator [VERB]  drive the optional indicator sub-package (a
#                          passthrough to indicator/setup.sh; VERB defaults to
#                          install). Kept OUT of `install`: it is Python + a
#                          daemon, unlike core mux (shell, no deps but tmux).
#
# POSIX sh, non-privileged. PREFIX (default ~/.local) and the XDG_* vars
# override the destinations, so a test drives it against a scratch dir. The
# <pkg> namespace lives in the INSTALL prefix (~/.local/libexec/mux), applied
# here; the source tree carries none (libexec/, share/), as a package should.
set -eu

PKG=mux
_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

PREFIX=${PREFIX:-$HOME/.local}
_bin=${XDG_BIN_HOME:-$PREFIX/bin}
_lib=$PREFIX/libexec
_shr=${XDG_DATA_HOME:-$PREFIX/share}
_man=$_shr/man
RC=0

# marker contract: plain [OK]/[FAIL]/[WARN] a host styles; coloured at a tty,
# plain when piped or under NO_COLOR.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  _G=$(printf '\033[1;32m'); _R=$(printf '\033[1;31m')
  _Y=$(printf '\033[1;33m'); _O=$(printf '\033[0m')
else _G=; _R=; _Y=; _O=; fi
ok()   { printf '  %s[OK]%s   %s\n' "$_G" "$_O" "$1"; }
bad()  { printf '  %s[FAIL]%s %s\n' "$_R" "$_O" "$1"; RC=1; }
warn() { printf '  %s[WARN]%s %s\n' "$_Y" "$_O" "$1"; }

_ln()  { mkdir -p "$(dirname "$2")"; ln -sfn "$1" "$2"; }
_rmln() { [ "$(readlink "$2" 2>/dev/null)" = "$1" ] && rm -f "$2" || :; }

_man_pages() { for _m in "$_root"/man/man*/*.[0-9]; do
  [ -e "$_m" ] && printf '%s\n' "$_m"; done; }

do_install() {
  mkdir -p "$_bin" "$_lib" "$_shr"
  for _t in "$_root"/bin/*; do _ln "$_t" "$_bin/$(basename "$_t")"; done
  _ln "$_root/libexec" "$_lib/$PKG"      # ~/.local/libexec/mux -> clone/libexec
  _ln "$_root/share"   "$_shr/$PKG"      # ~/.local/share/mux   -> clone/share
  _man_pages | while IFS= read -r _m; do
    _ln "$_m" "$_man/$(basename "$(dirname "$_m")")/$(basename "$_m")"; done
  echo "$PKG: linked into $PREFIX (bin, libexec/$PKG, share/$PKG, man)"
}

do_uninstall() {
  for _t in "$_root"/bin/*; do _rmln "$_t" "$_bin/$(basename "$_t")"; done
  _rmln "$_root/libexec" "$_lib/$PKG"
  _rmln "$_root/share" "$_shr/$PKG"
  _man_pages | while IFS= read -r _m; do
    _rmln "$_m" "$_man/$(basename "$(dirname "$_m")")/$(basename "$_m")"; done
  echo "$PKG: removed its links from $PREFIX"
}

do_check() {
  echo "== $PKG (package install) =="
  for _t in "$_root"/bin/*; do _n=$(basename "$_t")
    [ "$(readlink "$_bin/$_n" 2>/dev/null)" = "$_t" ] \
      && ok "bin/$_n linked" || bad "bin/$_n not linked"; done
  [ "$(readlink "$_lib/$PKG" 2>/dev/null)" = "$_root/libexec" ] \
    && ok "libexec/$PKG linked" || bad "libexec/$PKG not linked"
  [ "$(readlink "$_shr/$PKG" 2>/dev/null)" = "$_root/share" ] \
    && ok "share/$PKG linked" || bad "share/$PKG not linked"
  "$_root/bin/mux" check || RC=1      # deps + package data (its own markers)
}

_U="usage: setup.sh [install|uninstall|check|test|version|all|indicator]"
case "${1:-help}" in
  install)   do_install ;;
  uninstall) do_uninstall ;;
  check)     do_check; exit "$RC" ;;
  test)      exec sh "$_root/test/run" ;;
  version)   _v=$(git -C "$_root" describe --tags --always 2>/dev/null || true)
             echo "${_v:-$PKG (unversioned)}" ;;
  all)       do_install; sh "$_root/indicator/setup.sh" install ;;
  indicator) shift; exec sh "$_root/indicator/setup.sh" "$@" ;;  # passthrough
  -h|--help|help) echo "$_U" ;;
  *) echo "setup.sh: unknown command '${1:-}'" >&2; echo "$_U" >&2; exit 2 ;;
esac
