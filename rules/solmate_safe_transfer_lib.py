#!/usr/bin/env python3
"""
Rule: Solmate's SafeTransferLib does not check for token contract's existence

Same logic as 4naly3er src/issues/M/solmateSafeTransferLib.ts:
- regexPreCondition: solmate/utils/SafeTransferLib.sol
- regex: .safeTransfer( | .safeTransferFrom( | .safeApprove(

There is a subtle difference between Solmate's SafeTransferLib and OZ's SafeERC20:
OZ's SafeERC20 checks if the token is a contract or not; Solmate's SafeTransferLib does not.
See: https://github.com/transmissions11/solmate/blob/main/src/utils/SafeTransferLib.sol#L9
@dev Note that none of the functions in this library check that a token has code at all!
That responsibility is delegated to the caller.
"""

import re
import sys
from pathlib import Path
from typing import Iterator

_ROOT = Path(__file__).resolve().parents[1]
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))
from cli.models.audit_report import AuditReportV2


REGEX_PRE_CONDITION = re.compile(r"solmate/utils/SafeTransferLib\.sol")
REGEX_MAIN = re.compile(r"\.safeTransfer\(|\.safeTransferFrom\(|\.safeApprove\(")

TITLE = "Solmate's SafeTransferLib does not check for token contract's existence"
SEVERITY = "medium"


def _line_from_index(content: str, index: int) -> int:
    return content[:index].count("\n") + 1


def _findings_in_content(filepath: str, content: str) -> Iterator[AuditReportV2]:
    if not REGEX_PRE_CONDITION.search(content):
        return
    lines = content.split("\n")
    description_base = (
        "Solmate's SafeTransferLib does not check that the token has code. "
        "Ensure the token address is a contract (e.g. extcodesize(token) > 0) before calling."
    )
    for m in REGEX_MAIN.finditer(content):
        line_no = _line_from_index(content, m.start())
        line_content = lines[line_no - 1] if 1 <= line_no <= len(lines) else ""
        snippet = line_content.strip()[:120]
        description = f"{description_base} ({filepath}:{line_no})"
        yield AuditReportV2(
            tag=["Solmate"],
            subtag=["Missing Return Check"],
            severity=SEVERITY,
            description=description,
            code_snippet=snippet,
        )


def run_on_files(files: list[Path]) -> list[AuditReportV2]:
    """
    Run the rule on the given .sol files (by path). Reads each file and
    returns a list of findings as AuditReportV2.
    """
    findings: list[AuditReportV2] = []
    for path in files:
        if not path.exists():
            print(f"Warning: file not found, skipping: {path}", file=sys.stderr)
            continue
        content = path.read_text()
        for report in _findings_in_content(str(path), content):
            findings.append(report)
    return findings


def main() -> int:
    if len(sys.argv) < 2:
        print("Usage: python solady_safe_transfer_lib.py <file.sol> [file2.sol ...]")
        return 2
    sol_files = [Path(p) for p in sys.argv[1:] if p.endswith(".sol")]
    if not sol_files:
        print("No .sol files given.")
        return 2
    findings = run_on_files(sol_files)
    for report in findings:
        print(f"{report.severity}: {report.description}")
        if report.code_snippet:
            snip = report.code_snippet
            print(f"  {snip if len(snip) <= 80 else snip[:77] + '...'}")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
