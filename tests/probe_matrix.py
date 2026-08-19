"""以 fresh process 执行 xray-2go 回归探针，并隔离 subprocess 探针。"""

from __future__ import annotations

import ast
import subprocess
import sys
from pathlib import Path
from typing import Any, Iterable

from sandbox_runner import XraySandbox


CATEGORIES = ("static", "safe", "sandbox")
_ORCHESTRATOR_TESTS = {"test_runtime_probe_matrix_runs_in_fresh_process"}


def _test_functions(source_path: Path) -> Iterable[ast.FunctionDef]:
    tree = ast.parse(source_path.read_text(encoding="utf-8"), filename=str(source_path))
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and node.name.startswith("test_"):
            if node.name not in _ORCHESTRATOR_TESTS:
                yield node


def _call_names(function: ast.FunctionDef) -> set[str]:
    names: set[str] = set()
    for node in ast.walk(function):
        if not isinstance(node, ast.Call):
            continue
        if isinstance(node.func, ast.Name):
            names.add(node.func.id)
        elif isinstance(node.func, ast.Attribute) and isinstance(node.func.value, ast.Name):
            names.add(f"{node.func.value.id}.{node.func.attr}")
    return names


def discover_probe_matrix(source_path: Path) -> dict[str, list[str]]:
    """按副作用边界发现探针类别，保持源文件中的定义顺序。"""
    matrix = {category: [] for category in CATEGORIES}
    for function in _test_functions(source_path):
        calls = _call_names(function)
        if "XraySandbox" in calls:
            category = "sandbox"
        elif calls.intersection({"run_bash", "run_bash_result", "subprocess.run"}):
            # safe 表示由 runner 提供 sandbox 的 subprocess 探针，不能直接触碰生产 root。
            category = "safe"
        else:
            category = "static"
        matrix[category].append(function.name)
    return matrix


def _child_code() -> str:
    return """
import importlib.util
import sys
from pathlib import Path

source_path = Path(sys.argv[1])
test_name = sys.argv[2]
spec = importlib.util.spec_from_file_location("xray2go_probe_child", source_path)
if spec is None or spec.loader is None:
    raise RuntimeError(f"cannot load probe module: {source_path}")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
getattr(module, test_name)()
"""


def _run_one(source_path: Path, test_name: str, env: dict[str, str] | None) -> dict[str, Any]:
    child = subprocess.Popen(
        [sys.executable, "-c", _child_code(), str(source_path), test_name],
        cwd=source_path.parent.parent,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    output, _ = child.communicate(timeout=60)
    return {
        "name": test_name,
        "pid": child.pid,
        "returncode": child.returncode,
        "output": output,
    }


def run_probe_matrix(source_path: Path, categories: tuple[str, ...] = CATEGORIES) -> dict[str, Any]:
    """逐个 fresh process 执行所选探针；safe 类别使用一次性 sandbox。"""
    matrix = discover_probe_matrix(source_path)
    selected = [name for category in categories for name in matrix[category]]
    results: list[dict[str, Any]] = []

    for category in categories:
        for test_name in matrix[category]:
            if category == "safe":
                with XraySandbox() as sandbox:
                    result = _run_one(source_path, test_name, sandbox.environment())
            else:
                result = _run_one(source_path, test_name, None)
            result["category"] = category
            results.append(result)

    failed = [
        {
            "name": result["name"],
            "category": result["category"],
            "returncode": result["returncode"],
            "output": result["output"],
        }
        for result in results
        if result["returncode"] != 0
    ]
    return {
        "executed": selected,
        "failed": failed,
        "results": results,
    }
