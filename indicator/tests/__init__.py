# Makes `python -m unittest discover -s tests -t .` work: discover requires an
# importable start directory. It cannot reach an installed wheel -- pyproject
# pins packages to ["mux_indicator"] explicitly, so this stays a dev-only tree.
