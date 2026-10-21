"""Verify the reorganized release without requiring disposable build caches."""
import runpy
from pathlib import Path

if __name__ == '__main__':
    runpy.run_path(str(Path(__file__).resolve().parents[2] / 'tools/check_project_layout.py'), run_name='__main__')
