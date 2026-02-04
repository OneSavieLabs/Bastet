"""
Rule: Deprecated .transfer() on address payable — use .call{value: x}("") instead.

The use of the deprecated transfer() for an address payable may make the transaction fail due to the 2300 gas stipend. Prefer call{value: amount}("").
"""

from __future__ import annotations

import sys
import warnings
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional, Tuple

import tree_sitter
import tree_sitter_solidity
from tree_sitter import Language, Node

def _get_solidity_language() -> Language:
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", DeprecationWarning)
        return Language(tree_sitter_solidity.language())


def _member_object(member_expression: Node) -> Optional[Node]:
    """First child of member_expression is the object (before the dot)."""
    if member_expression.child_count >= 1:
        return member_expression.child(0)
    return None


def _member_property(member_expression: Node) -> Optional[Node]:
    """Property is the identifier after the dot."""
    if member_expression.child_count >= 3:
        return member_expression.child(2)
    return None


def _count_call_arguments(call_node: Node) -> int:
    """
    Return the number of arguments in a call_expression.
    tree-sitter-solidity: arguments are direct children of type "call_argument".
    """
    n = 0
    for i in range(call_node.child_count):
        if call_node.child(i).type == "call_argument":
            n += 1
    return n


def _find_deprecated_transfer_calls(root: Node, source_bytes: bytes) -> List[Node]:
    """
    Walk the tree and collect every call_expression that is .transfer(<one argument>).
    """
    result: List[Node] = []

    def walk(node: Node) -> None:
        if node.type == "call_expression":
            func_node = node.child_by_field_name("function") or (
                node.child(0) if node.child_count > 0 else None
            )
            if func_node and func_node.type == "expression" and func_node.child_count > 0:
                func_node = func_node.child(0)
            if func_node and func_node.type == "member_expression":
                prop_node = func_node.child_by_field_name("property") or _member_property(func_node)
                if prop_node:
                    prop_text = source_bytes[prop_node.start_byte : prop_node.end_byte].decode(
                        "utf-8", errors="replace"
                    ).strip()
                    if prop_text == "transfer" and _count_call_arguments(node) == 1:
                        result.append(node)
        for child in node.children:
            walk(child)

    walk(root)
    return result


def _get_text(node: Node, source: bytes) -> str:
    return source[node.start_byte : node.end_byte].decode("utf-8", errors="replace")


def _get_line_and_column(source: str, byte_offset: int) -> Tuple[int, int]:
    """Return (1-based line, 0-based column) for byte_offset in UTF-8 source."""
    before = source.encode("utf-8")[:byte_offset].decode("utf-8", errors="replace")
    line = before.count("\n") + 1
    last_nl = before.rfind("\n")
    col = (byte_offset - (last_nl + 1)) if last_nl >= 0 else byte_offset
    return line, col


@dataclass
class Finding:
    file_path: str
    line: int
    column: int
    message: str
    severity: str
    code_snippet: str
    rule: str


def run_deprecated_transfer_rule(
    file_path: str,
    source: str,
    language: Optional[Language] = None,
) -> List[Finding]:
    """
    Run the deprecated transfer rule on a single Solidity file.
    Reports every .transfer(<one arg>) call (deprecated; use call{value: x}("") instead).
    """
    if language is None:
        language = _get_solidity_language()
    parser = tree_sitter.Parser(language)
    source_bytes = source.encode("utf-8")
    tree = parser.parse(source_bytes)
    root = tree.root_node

    findings: List[Finding] = []
    for call_node in _find_deprecated_transfer_calls(root, source_bytes):
        line, col = _get_line_and_column(source, call_node.start_byte)
        snippet = _get_text(call_node, source_bytes).strip()[:120]
        findings.append(
            Finding(
                file_path=file_path,
                line=line,
                column=col,
                message=(
                    "call() should be used instead of transfer() on an address payable. "
                    "The use of the deprecated transfer() may make the transaction fail due to the 2300 gas stipend."
                ),
                severity="Medium",
                code_snippet=snippet,
                rule="deprecated-transfer",
            )
        )
    return findings


def run_on_files(files: List[Path], language: Optional[Language] = None) -> List[Finding]:
    """
    Run the rule on the given .sol files (by path). Reads each file and
    returns a list of findings.
    """
    if language is None:
        language = _get_solidity_language()
    findings: List[Finding] = []
    for path in files:
        if not path.exists():
            print(f"Warning: file not found, skipping: {path}", file=sys.stderr)
            continue
        content = path.read_text(encoding="utf-8", errors="replace")
        for report in run_deprecated_transfer_rule(str(path), content, language):
            findings.append(report)
    return findings


def main() -> int:
    if len(sys.argv) < 2:
        print("Usage: python deprecated_transfer_single_file.py <file.sol> [file2.sol ...]")
        return 2
    sol_files = [Path(p) for p in sys.argv[1:] if p.endswith(".sol")]
    if not sol_files:
        print("No .sol files given.")
        return 2
    findings = run_on_files(sol_files)
    for report in findings:
        print(f"{report.severity}: {report.message}")
        if report.code_snippet:
            snip = report.code_snippet
            print(f"  {snip if len(snip) <= 80 else snip[:77] + '...'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
