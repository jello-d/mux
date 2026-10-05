import asyncio
import sys

from . import sni
from .sni import flags, run


def main(argv=None):
    """ARGV IS A PARAMETER, defaulting to the real one. Reading `sys.argv`
    unconditionally made this untestable in the most embarrassing way: the
    existing entry-point tests call `main()`, so the parser was handed the
    TEST RUNNER's own arguments and refused them. A parameter costs nothing
    and the default keeps the console script identical.
    """
    argv = sys.argv[1:] if argv is None else argv
    # Applied to the module BEFORE the daemon starts, because they decide
    # which surfaces exist and both are read in several places. Parsed here
    # so an unknown argument is refused before anything is published or
    # connected to.
    sni.TRAY, sni.TOASTS, sni.IGNORE = flags(argv)
    try:
        asyncio.run(run())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
