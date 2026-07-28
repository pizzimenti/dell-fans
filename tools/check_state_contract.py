#!/usr/bin/env python3
"""Verify the plasmoid QML parses every key its data source emits.

The helper (`fanmon-plasmoid-source.py`) and the widget (`main.qml`) form a
producer/consumer pair joined only by a `key=value` text stream. Nothing in the
build, the linters, or the Python/QML type systems spans that boundary, so a key
added on one side and forgotten on the other fails *silently*: `parseState()`
drops the unknown key, the QML property reads back `undefined`, and whatever
depends on it quietly takes its falsy branch forever.

That has bitten this project three times:

  * `policy_rule` emitted only in full mode, so the collapsed widget never saw
    a sensor fault.
  * `policy_timestamp` emitted by both helper modes but missing from
    `_intKeys`, leaving `policyStale` permanently true and replacing every
    popup rule with "No recent fan data".
  * (fanmon's sibling of the same bug: `collect()` never populated
    `policy_rule`, making its `sensor_fault` short-circuit dead code.)

Every one of those passed unit tests, because the tests exercised each side in
isolation with hand-built inputs. This checks the contract itself.

Usage:  python3 tools/check_state_contract.py
Exit:   0 = contract holds, 1 = a violation, 2 = could not run the check
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HELPER = ROOT / "fanmon-plasmoid-source.py"
QML = ROOT / "plasmoid" / "org.kde.plasma.dell-fans" / "contents" / "ui" / "main.qml"

# Keys the QML deliberately never stores as data properties.
IGNORED_EMITTED = {"mode"}


def emitted_keys() -> dict[str, set[str]]:
    """Run the helper in both modes and collect the keys each emits."""
    modes = {"compact": ["--compact"], "full": []}
    out: dict[str, set[str]] = {}
    for name, args in modes.items():
        proc = subprocess.run(
            [sys.executable, str(HELPER), *args],
            capture_output=True, text=True, timeout=30,
        )
        if proc.returncode != 0:
            raise RuntimeError(f"helper failed in {name} mode: {proc.stderr.strip()}")
        keys = set()
        for line in proc.stdout.splitlines():
            if "=" in line:
                keys.add(line.split("=", 1)[0])
        if not keys:
            raise RuntimeError(f"helper emitted nothing in {name} mode")
        out[name] = keys
    return out


def _js_regex_to_python(literal: str) -> str:
    """These patterns are simple enough that JS and Python syntax coincide."""
    return literal.strip("/")


def handled_keys(qml_text: str) -> tuple[set[str], list[re.Pattern]]:
    """Extract the keys parseState() understands: literal sets, explicit
    `key === "x"` branches, and regex-matched families."""
    literals: set[str] = set()

    # readonly property var _intKeys: new Set([...])  (and _floatKeys)
    for match in re.finditer(r"new Set\(\[(.*?)\]\)", qml_text, re.S):
        literals.update(re.findall(r'"([^"]+)"', match.group(1)))

    # } else if (key === "pwm_mode") {
    literals.update(re.findall(r'key\s*===\s*"([^"]+)"', qml_text))

    # readonly property var _tempLabelRe: /^temp_(\d+)_label$/
    patterns = [
        re.compile(_js_regex_to_python(lit))
        for lit in re.findall(r"property var _\w*Re:\s*(/[^/]+/)", qml_text)
    ]
    return literals, patterns


def main() -> int:
    for path in (HELPER, QML):
        if not path.exists():
            print(f"ERROR: missing {path}", file=sys.stderr)
            return 2

    try:
        emitted = emitted_keys()
    except subprocess.TimeoutExpired:
        # The helper reads sysfs, so on a wedged EC it can sit in
        # uninterruptible I/O that neither the timeout nor the follow-up
        # SIGKILL can clear — the same D-state case documented in the README.
        # Nothing here can fix that; the contract simply cannot be checked
        # against hardware that isn't answering, and saying so beats hanging
        # or, worse, reporting a pass.
        print("ERROR: helper timed out reading sysfs; contract not verified",
              file=sys.stderr)
        return 2
    except Exception as exc:  # noqa: BLE001 - surface any failure to the caller
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    literals, patterns = handled_keys(QML.read_text(encoding="utf-8"))

    def is_handled(key: str) -> bool:
        return key in literals or any(p.match(key) for p in patterns)

    failed = False
    for mode, keys in sorted(emitted.items()):
        unhandled = sorted(k for k in keys
                           if k not in IGNORED_EMITTED and not is_handled(k))
        if unhandled:
            failed = True
            print(f"FAIL  {mode} mode emits keys main.qml never stores:")
            for key in unhandled:
                print(f"        {key}  -> parseState() drops it; "
                      f"reads back as undefined")
        else:
            print(f"PASS  {mode} mode: all {len(keys)} emitted keys are parsed")

    # Reverse direction is advisory: a parsed key the helper never emits is
    # usually dead weight, but can be legitimate (a field emitted only on
    # hardware this machine lacks), so it warns rather than fails.
    all_emitted = set().union(*emitted.values())
    orphans = sorted(k for k in literals
                     if k not in all_emitted and not k.startswith("temp_"))
    if orphans:
        print(f"\nNOTE  parsed but not emitted on this hardware: {', '.join(orphans)}")
        print("      (advisory — may be conditional on hardware, or may be dead)")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
