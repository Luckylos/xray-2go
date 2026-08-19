"""隔离 xray-2go runtime 探针的临时 root harness。"""

from __future__ import annotations

import os
import tempfile
from pathlib import Path


class XraySandbox:
    """为 Bash runtime 探针提供临时 root，并在退出时清理。"""

    def __init__(self) -> None:
        self._temporary_directory = tempfile.TemporaryDirectory(prefix="xray2go-sandbox-")
        self.root = Path(self._temporary_directory.name)

    def environment(self) -> dict[str, str]:
        env = os.environ.copy()
        env["X2G_TEST_MODE"] = "1"
        env["X2G_TEST_ROOT"] = str(self.root)
        env["HOME"] = str(self.root / "home")
        env["TMPDIR"] = str(self.root / "tmp")
        (self.root / "tmp").mkdir(parents=True, exist_ok=True)
        return env

    def __enter__(self) -> "XraySandbox":
        return self

    def __exit__(self, exc_type, exc_value, traceback) -> None:
        self.cleanup()

    def cleanup(self) -> None:
        self._temporary_directory.cleanup()
