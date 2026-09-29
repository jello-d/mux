# mux - a tmux session manager for agent-heavy, many-session work.
#
# THIS REPO IS ITS OWN TAP, and that is a deliberate choice rather than a
# shortcut. Only the ONE-ARGUMENT form of `brew tap` requires a repository
# called `homebrew-<name>`; the two-argument form takes an explicit URL and
# imposes no naming convention, and a tap is just a git repo carrying a formula
# in `Formula/`, `HomebrewFormula/` or the root. So the whole cost of keeping
# this here is one extra argument, once:
#
#   brew tap jello-d/mux https://github.com/jello-d/mux
#   brew install mux
#
# WHAT IT BUYS IS A TEST. The version below is a second copy of `MUX_VERSION`,
# and this project's standing rule is that a second copy of a fact needs a
# check rather than vigilance. Because the formula sits beside the source,
# `test/mux-homebrew.t` can hold the two together and fail the suite the moment
# they part. A separate tap repo could not be tested against the code it
# installs, and would need a release workflow with a cross-repo token to bump
# what one commit bumps here.
class Mux < Formula
  desc "tmux session manager for agent-heavy, many-session work"
  homepage "https://github.com/jello-d/mux"

  # A GIT TAG, NOT A TARBALL. The revision is the integrity pin, so there is no
  # archive checksum to recompute on every release, and both values are ones
  # git already knows. `test/mux-homebrew.t` asserts they name the NEWEST tag,
  # that the revision really is that tag's commit, and that the tag carries
  # this version of `MUX_VERSION` -- so a release that forgets this file turns
  # the suite red instead of leaving Homebrew users on an old mux forever.
  url "https://github.com/jello-d/mux.git",
      tag:      "v0.81",
      revision: "1f18d2f9bbc448363aced28ad9ff6ca30a46d42a"
  license "Apache-2.0"
  head "https://github.com/jello-d/mux.git", branch: "main"

  # The only runtime dependency mux has. No daemon, no language runtime: it is
  # POSIX shell over tmux.
  depends_on "tmux"

  def install
    # INTO `libexec`, NOT INTO THE KEG ROOT, and the reason is Homebrew's link
    # step rather than mux's layout. `share/` here holds `themes/`, `shapes/`,
    # `agents/` and the tmux fragments; installed at the keg root, `brew link`
    # would symlink those into the Homebrew prefix's own `share`, where
    # `share/themes` is a name another formula may also want. Under `libexec`
    # nothing is linked and nothing can collide.
    #
    # The three directories stay SIBLINGS, which is the one property mux
    # requires: `bin/mux` resolves `$0` and then reads `../libexec` and
    # `../share`. No `mux` namespace inside them, because a keg is already a
    # private prefix -- that namespace exists only so several packages can
    # share `~/.local`, which is `setup.sh`'s job and not this one's.
    libexec.install "bin", "libexec", "share"

    # `brew link` puts this one symlink on PATH. Resolving `$0` through it
    # lands back in the keg, which is exactly the chain-of-symlinks case
    # `test/mux-portability.t` pins (and the case that turned out to be broken
    # on macOS before 12.3, where `readlink -f` does not exist).
    bin.install_symlink libexec/"bin/mux"
    man1.install "man/man1/mux.1"
  end

  # brew INSTALLS BY COPYING, so mux's own `setup.sh` never runs and neither do
  # the two notices it prints. Both manual steps are still the user's, and an
  # installed-but-inert mux is exactly the state mux's own check exists to
  # catch, so they are said here instead.
  def caveats
    <<~EOS
      mux is installed, and until you source its tmux fragment it does nothing
      visible: no status bar, no agent strip, no key bindings.

      1. Add to your tmux.conf (~/.config/tmux/tmux.conf or ~/.tmux.conf):

           source-file #{opt_libexec}/share/mux.tmux
           source-file #{opt_libexec}/share/mux-opinions.tmux   # optional

      2. Wire your agent's lifecycle hooks, so the strip knows what your
         agents are doing:

           mux setup claude

      Then `mux demo` builds a throwaway mux on its own server if you want to
      see the bar before wiring anything real.

      AFTER AN UPGRADE, a tmux server that is already running still has the
      bindings and hooks it read at START. Refresh it with:

           mux reload
    EOS
  end

  test do
    # The version the formula claims is the version the program reports. That
    # is the same drift this formula's own test in `test/mux-homebrew.t`
    # guards, asserted here from the other side: after an install, against the
    # installed binary.
    assert_match "mux #{version}", shell_output("#{bin}/mux -V")

    # A verb that SOURCES a library, because `-V` can answer before any lookup
    # happens -- which is precisely how a broken self-location passed a first
    # check once. This fails if `libexec` or `share` did not land as siblings.
    assert_match "tmux session managed by",
                 shell_output("#{bin}/mux skill --agents-md")
  end
end
