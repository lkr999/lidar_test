"""
EvaluatorAgent — reviews changes made by specialist agents.

Produces a structured EvaluationResult with:
  - overall score (0–10)
  - pass/fail decision
  - per-dimension scores
  - list of issues (CRITICAL / HIGH / MEDIUM / LOW)
  - per-agent feedback for the next iteration
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from typing import Any

from .base import BaseAgent, dispatch_tool, TOOLS
from config import MODEL, MAX_TOKENS, AGENT_MAX_TOOL_ROUNDS, EVAL_PASS_SCORE, EVAL_CRITICAL_BLOCK


@dataclass
class Issue:
    severity: str  # CRITICAL | HIGH | MEDIUM | LOW
    file: str
    line: int | None
    description: str
    suggestion: str


@dataclass
class EvaluationResult:
    overall_score: float
    pass_: bool
    dimensions: dict[str, int]
    issues: list[Issue]
    approved_changes: list[str]
    rejected_changes: list[str]
    feedback_for_agents: dict[str, str | None]
    raw_response: str

    @property
    def has_critical(self) -> bool:
        return any(i.severity == "CRITICAL" for i in self.issues)

    @property
    def has_high(self) -> bool:
        return any(i.severity == "HIGH" for i in self.issues)

    def summary(self) -> str:
        lines = [
            f"Score: {self.overall_score:.1f}/10  ({'PASS' if self.pass_ else 'FAIL'})",
            f"Issues: {len(self.issues)} "
            f"({sum(1 for i in self.issues if i.severity=='CRITICAL')} critical, "
            f"{sum(1 for i in self.issues if i.severity=='HIGH')} high, "
            f"{sum(1 for i in self.issues if i.severity=='MEDIUM')} medium, "
            f"{sum(1 for i in self.issues if i.severity=='LOW')} low)",
        ]
        if self.issues:
            lines.append("Issues:")
            for iss in self.issues:
                loc = f" L{iss.line}" if iss.line else ""
                lines.append(f"  [{iss.severity}] {iss.file}{loc}: {iss.description}")
        return "\n".join(lines)


def _parse_evaluation(text: str) -> EvaluationResult | None:
    """Extract and parse the JSON evaluation block from the model response."""
    match = re.search(r"```json\s*(\{.*?\})\s*```", text, re.DOTALL)
    if not match:
        match = re.search(r"(\{[^{}]*\"overall_score\"[^{}]*\})", text, re.DOTALL)
    if not match:
        return None

    try:
        data = json.loads(match.group(1))
    except json.JSONDecodeError:
        return None

    issues = []
    for raw in data.get("issues", []):
        issues.append(Issue(
            severity=raw.get("severity", "MEDIUM").upper(),
            file=raw.get("file", ""),
            line=raw.get("line"),
            description=raw.get("description", ""),
            suggestion=raw.get("suggestion", ""),
        ))

    overall = float(data.get("overall_score", 0))
    has_critical = any(i.severity == "CRITICAL" for i in issues)

    if EVAL_CRITICAL_BLOCK and has_critical:
        pass_ = False
    else:
        pass_ = overall >= EVAL_PASS_SCORE

    return EvaluationResult(
        overall_score=overall,
        pass_=pass_,
        dimensions=data.get("dimensions", {}),
        issues=issues,
        approved_changes=data.get("approved_changes", []),
        rejected_changes=data.get("rejected_changes", []),
        feedback_for_agents=data.get("feedback_for_agents", {}),
        raw_response=text,
    )


class EvaluatorAgent(BaseAgent):
    """
    Evaluates changes produced by specialist agents.

    Usage:
        result: EvaluationResult = evaluator.evaluate(agent_results)
    """

    name = "evaluator"

    def evaluate(self, agent_results: list[dict[str, Any]]) -> EvaluationResult:
        """
        Evaluate a list of agent run results.

        Args:
            agent_results: List of dicts returned by BaseAgent.run()

        Returns:
            EvaluationResult with structured evaluation data.
        """
        # Build evaluation request
        summary_lines = ["Please evaluate the following changes made by specialist agents.\n"]
        for res in agent_results:
            agent = res.get("agent", "unknown")
            task = res.get("task", "")
            changes = [c for c in res.get("changes", []) if c["action"] == "write"]
            summary_lines.append(
                f"## Agent: {agent}\n"
                f"Task: {task}\n"
                f"Files modified: {', '.join(c['path'] for c in changes) or 'none'}\n"
                f"Agent summary: {res.get('result', '')[:500]}\n"
            )

        if not any(
            c["action"] == "write"
            for res in agent_results
            for c in res.get("changes", [])
        ):
            summary_lines.append(
                "\nNOTE: No files were modified in this run. "
                "Evaluate whether the task was completed through analysis alone, "
                "or whether code changes were required but not made."
            )

        task_text = "\n".join(summary_lines)

        # Run the agentic loop (same as BaseAgent.run but returns EvaluationResult)
        messages: list[dict] = [{"role": "user", "content": task_text}]
        rounds = 0
        final_response = None

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
            messages.append({"role": "assistant", "content": response.content})
            final_response = response

            if response.stop_reason == "end_turn":
                break
            if response.stop_reason != "tool_use":
                break

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
            messages.append({"role": "user", "content": tool_results})

        # Extract final text
        final_text = ""
        if final_response:
            for block in final_response.content:
                if hasattr(block, "text"):
                    final_text += block.text

        # Parse structured result
        result = _parse_evaluation(final_text)
        if result is None:
            # Fallback: create a neutral result with the raw response
            result = EvaluationResult(
                overall_score=5.0,
                pass_=False,
                dimensions={},
                issues=[Issue(
                    severity="HIGH",
                    file="evaluation",
                    line=None,
                    description="Evaluator did not produce a structured JSON response",
                    suggestion="Re-run evaluation",
                )],
                approved_changes=[],
                rejected_changes=[],
                feedback_for_agents={},
                raw_response=final_text,
            )

        return result
