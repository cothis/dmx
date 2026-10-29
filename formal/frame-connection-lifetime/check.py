#!/usr/bin/env python3
"""Compatibility entry point: run both current scoped models; old evidence is retained."""
import runpy
from pathlib import Path
runpy.run_path(str(Path(__file__).resolve().parents[1]/'check.py'),run_name='__main__')
