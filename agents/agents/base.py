"""
BaseAgent — shared tools and agentic loop for all specialist agents.

Tools available to every agent:
  read_file       – read a source file
  write_file      – write/overwrite a source file
  list_directory  – list files in a directory
  search_code     – regex search across project files
  run_syntax_check– lightweight Swift syntax validation (swiftc -parse)
"""
from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path
from typing import Any

import anthropic

from config import MODEL, MAX_TOKENS, AGENT_MAX_TOOL_ROUNDS, PROJECT_ROOT


# ── Tool Schemas ──────────────────────────────────────────────────────────────

TOOLS: list[dict] = [
    {
        "name": "read_file",
        "description": (
            "Read the full content of a Swift source file. "
            "Returns the content as a string with line numbers prepended."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "Absolute or project-relative path to the file.",
                }
            },
            "required": ["path"],
        },
    },
    {
        "name": "write_file",
        "description": (
            "Write (create or overwrite) a Swift source file. "
            "Only call this when you have the complete, final content ready. "
            "Preserves original encoding (UTF-8)."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "Absolute or project-relative path to the file.",
                },
                "content": {
                    "type": "string",
                    "description": "Complete new content for the file.",
                },
            },
            "required": ["path", "content"],
        },
    },
    {
        "name": "list_directory",
        "description": "List files and subdirectories in a project directory.",
        "input_schema": {
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "Absolute or project-relative directory path.",
                }
            },
            "required": ["path"],
        },
    },
    {
        "name": "search_code",
        "description": (
            "Search Swift source files for a regex pattern. "
            "Returns file paths and matching lines."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "pattern": {
                    "type": "string",
                    "description": "Regular expression pattern to search for.",
                },
                "directory": {
                    "type": "string",
                    "description": "Directory to search in (default: ios/Runner).",
                },
                "file_extension": {
                    "type": "string",
                    "description": "File extension filter (default: .swift).",
                },
            },
            "required": ["pattern"],
        },
    },
    {
        "name": "run_syntax_check",
        "description": (
            "Run a Swift syntax check on a file using 'swiftc -parse'. "
            "Returns compiler errors/warnings or 'OK' if no issues found."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "Absolute or project-relative path to the Swift file.",
                }
            },
            "required": ["path"],
        },
    },
]


# ── Tool Implementations ──────────────────────────────────────────────────────

def _resolve_path(path: str) -> Path:
    p = Path(path)
    if not p.is_absolute():
        p = PROJECT_ROOT / p
    return p


def tool_read_file(path: str) -> str:
    p = _resolve_path(path)
    if not p.exists():
        return f"ERROR: File not found: {p}"
    try:
        lines = p.read_text(encoding="utf-8").splitlines()
        numbered = "\n".join(f"{i+1:4d}  {line}" for i, line in enumerate(lines))
        return f"// File: {p}\n// Lines: {len(lines)}\n\n{numbered}"
    except Exception as e:
        return f"ERROR reading {p}: {e}"


def tool_write_file(path: str, content: str) -> str:
    p = _resolve_path(path)
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content, encoding="utf-8")
        lines = content.count("\n") + 1
        return f"OK: Wrote {lines} lines to {p}"
    except Exception as e:
        return f"ERROR writing {p}: {e}"


def tool_list_directory(path: str) -> str:
    p = _resolve_path(path)
    if not p.exists():
        return f"ERROR: Directory not found: {p}"
    try:
        entries = sorted(p.iterdir(), key=lambda x: (x.is_file(), x.name))
        lines = []
        for e in entries:
            kind = "FILE" if e.is_file() else "DIR "
            lines.append(f"  {kind}  {e.name}")
        return f"Directory: {p}\n" + "\n".join(lines)
    except Exception as e:
        return f"ERROR listing {p}: {e}"


def tool_search_code(
    pattern: str,
    directory: str | None = None,
    file_extension: str = ".swift",
) -> str:
    search_dir = _resolve_path(directory) if directory else PROJECT_ROOT / "ios" / "Runner"
    try:
        results = []
        regex = re.compile(pattern)
        for fp in sorted(search_dir.rglob(f"*{file_extension}")):
            matches = []
            try:
                for i, line in enumerate(fp.read_text(encoding="utf-8").splitlines(), 1):
                    if regex.search(line):
                        matches.append(f"  L{i:4d}: {line.rstrip()}")
            except Exception:
                continue
            if matches:
                rel = fp.relative_to(PROJECT_ROOT)
                results.append(f"\n{rel}:\n" + "\n".join(matches))
        if not results:
            return f"No matches for pattern: {pattern}"
        return "\n".join(results)
    except re.error as e:
        return f"ERROR: Invalid regex: {e}"


def tool_run_syntax_check(path: str) -> str:
    p = _resolve_path(path)
    if not p.exists():
        return f"ERROR: File not found: {p}"
    try:
        result = subprocess.run(
            ["swiftc", "-parse", str(p)],
            capture_output=True,
            text=True,
            timeout=30,
        )
        combined = (result.stdout + result.stderr).strip()
        if result.returncode == 0 and not combined:
            return "OK: No syntax errors found."
        return combined if combined else "OK: No syntax errors found."
    except FileNotFoundError:
        return "SKIP: swiftc not found on PATH (install Xcode command line tools)."
    except subprocess.TimeoutExpired:
        return "TIMEOUT: Syntax check exceeded 30 seconds."
    except Exception as e:
        return f"ERROR running swiftc: {e}"


# ── Tool Dispatcher ───────────────────────────────────────────────────────────

def dispatch_tool(tool_name: str, tool_input: dict[str, Any]) -> str:
    if tool_name == "read_file":
        return tool_read_file(**tool_input)
    if tool_name == "write_file":
        return tool_write_file(**tool_input)
    if tool_name == "list_directory":
        return tool_list_directory(**tool_input)
    if tool_name == "search_code":
        return tool_search_code(**tool_input)
    if tool_name == "run_syntax_check":
        return tool_run_syntax_check(**tool_input)
    return f"ERROR: Unknown tool '{tool_name}'"


# ── Base Agent Class ──────────────────────────────────────────────────────────

class BaseAgent:
    """
    Base class for all specialist agents.

    Subclasses set:
        name        – display name
        system_prompt – loaded from prompts/<name>.md
    """

    name: str = "base"
    system_prompt: str = ""

    def __init__(self, client: anthropic.Anthropic) -> None:
        self.client = client
        self._load_prompt()

    def _load_prompt(self) -> None:
        prompt_path = Path(__file__).parent.parent / "prompts" / f"{self.name}.md"
        if prompt_path.exists():
            self.system_prompt = prompt_path.read_text(encoding="utf-8")

    # ── Public API ────────────────────────────────────────────────────────────

    def run(self, task: str, context: str = "") -> dict[str, Any]:
        """
        Run the agent on a task.

        Args:
            task:    Natural-language description of what to do.
            context: Optional additional context (e.g., feedback from evaluator).

        Returns:
            {
                "agent":    agent name,
                "task":     original task,
                "result":   final text response,
                "changes":  list of {"path": ..., "action": "write"|"read"} dicts,
                "tool_log": list of tool call summaries,
            }
        """
        full_task = task
        if context:
            full_task = f"{task}\n\n--- CONTEXT / FEEDBACK ---\n{context}"

        messages: list[dict] = [{"role": "user", "content": full_task}]
        changes: list[dict] = []
        tool_log: list[dict] = []
        rounds = 0

        while rounds < AGENT_MAX_TOOL_ROUNDS:
            response = self.client.messages.create(
                model=MODEL,
                max_tokens=MAX_TOKENS,
                system=self.system_prompt,
                tools=TOOLS,
                messages=messages,
                thinking={"type": "adaptive"},
            )
            rounds += 1

            # Append assistant turn
            messages.append({"role": "assistant", "content": response.content})

            if response.stop_reason == "end_turn":
                break

            if response.stop_reason != "tool_use":
                break

            # Execute all tool calls
            tool_results = []
            for block in response.content:
                if block.type != "tool_use":
                    continue
                result_str = dispatch_tool(block.name, block.input)
                tool_results.append({
                    "type": "tool_result",
                    "tool_use_id": block.id,
                    "content": result_str,
                })
                entry = {"tool": block.name, "input": block.input, "result_preview": result_str[:200]}
                tool_log.append(entry)
                if block.name == "write_file":
                    changes.append({"path": block.input.get("path", ""), "action": "write"})
                elif block.name == "read_file":
                    changes.append({"path": block.input.get("path", ""), "action": "read"})

            messages.append({"role": "user", "content": tool_results})

        # Extract final text
        final_text = ""
        for block in response.content:
            if hasattr(block, "text"):
                final_text += block.text

        return {
            "agent": self.name,
            "task": task,
            "result": final_text,
            "changes": changes,
            "tool_log": tool_log,
        }
