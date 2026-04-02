"""
AgentHarness — orchestrates specialist agents and evaluation pipeline
for the Golf Putting LiDAR Analyzer project.

Pipeline:
  1. Parse task → determine which agents are needed
  2. Run specialist agents (can run independently per file domain)
  3. EvaluatorAgent reviews all changes
  4. If FAIL → feed per-agent feedback back into specialist agents
  5. Repeat up to MAX_ITERATIONS

Usage:
    harness = AgentHarness()
    report = harness.run("Fix the force-unwrap crash in LiDARScanner when depth frame is nil")
    print(report.summary())
"""
from __future__ import annotations

import json
import logging
import time
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any

import anthropic

from config import (
    ANTHROPIC_API_KEY,
    MODEL,
    MAX_TOKENS,
    MAX_ITERATIONS,
    AGENT_FILE_REGISTRY,
    RESULTS_DIR,
    LOGS_DIR,
)
from agents import LiDARAgent, UIAgent, PhysicsAgent, VisionAgent, EvaluatorAgent
from agents.evaluator import EvaluationResult

# ── Logging ───────────────────────────────────────────────────────────────────
LOGS_DIR.mkdir(parents=True, exist_ok=True)
RESULTS_DIR.mkdir(parents=True, exist_ok=True)

log = logging.getLogger("harness")
log.setLevel(logging.DEBUG)
_fh = logging.FileHandler(LOGS_DIR / "harness.log", encoding="utf-8")
_fh.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(message)s"))
log.addHandler(_fh)
_ch = logging.StreamHandler()
_ch.setFormatter(logging.Formatter("[%(levelname)s] %(message)s"))
log.addHandler(_ch)


# ── Task Router ───────────────────────────────────────────────────────────────

AGENT_KEYWORDS: dict[str, list[str]] = {
    "lidar": [
        "lidar", "depth", "arkit", "scanner", "heightmap", "height map",
        "pointcloud", "point cloud", "depth frame", "scene depth",
        "world map", "arcamera", "barometer", "ground plane",
    ],
    "ui": [
        "ui", "view", "viewcontroller", "overlay", "button", "label",
        "animation", "gesture", "scenekit", "3d view", "mesh grid",
        "trajectory overlay", "scan overlay", "position adjust",
        "state machine", "main view", "hud",
    ],
    "physics": [
        "physics", "terrain", "slope", "contour", "break", "putt",
        "trajectory", "bezier", "friction", "gravity", "speed",
        "mathutils", "math utils", "vector2", "heightmapdata",
        "icp", "alignment", "flow arrow",
    ],
    "vision": [
        "vision", "detect", "circle", "ball", "hole", "contour detection",
        "depth image", "false color", "jet colormap", "renderer",
        "cvpixelbuffer", "depth render",
    ],
}


def route_task(task: str) -> list[str]:
    """
    Return ordered list of agent names that should handle this task.
    Falls back to all agents if no keywords match.
    """
    task_lower = task.lower()
    matched: list[str] = []
    for agent_name, keywords in AGENT_KEYWORDS.items():
        if any(kw in task_lower for kw in keywords):
            matched.append(agent_name)
    return matched if matched else list(AGENT_KEYWORDS.keys())


# ── Run Report ────────────────────────────────────────────────────────────────

@dataclass
class IterationRecord:
    iteration: int
    agents_run: list[str]
    agent_results: list[dict[str, Any]]
    evaluation: EvaluationResult
    duration_sec: float


@dataclass
class HarnessReport:
    task: str
    start_time: str
    total_duration_sec: float
    iterations: list[IterationRecord]
    final_evaluation: EvaluationResult
    success: bool

    def summary(self) -> str:
        lines = [
            "=" * 60,
            f"Task: {self.task}",
            f"Started: {self.start_time}",
            f"Duration: {self.total_duration_sec:.1f}s  |  Iterations: {len(self.iterations)}",
            f"Result: {'SUCCESS' if self.success else 'FAILED'}",
            "-" * 60,
            self.final_evaluation.summary(),
            "=" * 60,
        ]
        return "\n".join(lines)

    def save(self) -> Path:
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        out_path = RESULTS_DIR / f"run_{ts}.json"
        data = {
            "task": self.task,
            "start_time": self.start_time,
            "total_duration_sec": self.total_duration_sec,
            "success": self.success,
            "iterations": [
                {
                    "iteration": r.iteration,
                    "agents_run": r.agents_run,
                    "evaluation_score": r.evaluation.overall_score,
                    "evaluation_pass": r.evaluation.pass_,
                    "issues": [
                        {
                            "severity": i.severity,
                            "file": i.file,
                            "line": i.line,
                            "description": i.description,
                        }
                        for i in r.evaluation.issues
                    ],
                    "duration_sec": r.duration_sec,
                }
                for r in self.iterations
            ],
            "final_evaluation": {
                "overall_score": self.final_evaluation.overall_score,
                "pass": self.final_evaluation.pass_,
                "dimensions": self.final_evaluation.dimensions,
                "approved_changes": self.final_evaluation.approved_changes,
                "rejected_changes": self.final_evaluation.rejected_changes,
            },
        }
        out_path.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
        return out_path


# ── Agent Harness ─────────────────────────────────────────────────────────────

class AgentHarness:
    """
    Orchestrates the multi-agent pipeline:
      specialist agents → evaluator → feedback loop → report
    """

    def __init__(self) -> None:
        if not ANTHROPIC_API_KEY:
            raise ValueError(
                "ANTHROPIC_API_KEY environment variable is not set. "
                "Export it before running: export ANTHROPIC_API_KEY=sk-..."
            )
        self.client = anthropic.Anthropic(api_key=ANTHROPIC_API_KEY)
        self._init_agents()

    def _init_agents(self) -> None:
        self.agents = {
            "lidar":   LiDARAgent(self.client),
            "ui":      UIAgent(self.client),
            "physics": PhysicsAgent(self.client),
            "vision":  VisionAgent(self.client),
        }
        self.evaluator = EvaluatorAgent(self.client)

    # ── Public API ────────────────────────────────────────────────────────────

    def run(self, task: str) -> HarnessReport:
        """
        Run the full agent pipeline for a task.

        Args:
            task: Natural-language description of what to implement/fix.

        Returns:
            HarnessReport with full audit trail and final evaluation.
        """
        start = time.monotonic()
        start_time = datetime.now().isoformat()
        log.info("=" * 60)
        log.info(f"TASK: {task}")
        log.info("=" * 60)

        # Determine which agents are needed
        agent_names = route_task(task)
        log.info(f"Routing to agents: {agent_names}")

        iterations: list[IterationRecord] = []
        feedback: dict[str, str] = {}

        for iteration in range(1, MAX_ITERATIONS + 1):
            log.info(f"\n--- Iteration {iteration}/{MAX_ITERATIONS} ---")
            iter_start = time.monotonic()

            # Run specialist agents (with feedback from previous iteration)
            agent_results: list[dict[str, Any]] = []
            for name in agent_names:
                agent = self.agents[name]
                agent_feedback = feedback.get(name, "")
                context = ""
                if agent_feedback:
                    context = f"Previous evaluation feedback:\n{agent_feedback}"
                    log.info(f"[{name}] Running with feedback: {agent_feedback[:120]}…")
                else:
                    log.info(f"[{name}] Running task…")

                result = agent.run(task=task, context=context)
                agent_results.append(result)
                files_written = [c["path"] for c in result["changes"] if c["action"] == "write"]
                log.info(
                    f"[{name}] Done. Files written: {files_written or 'none'}"
                )

            # Evaluate
            log.info("[evaluator] Reviewing changes…")
            evaluation = self.evaluator.evaluate(agent_results)
            log.info(f"[evaluator] Score: {evaluation.overall_score:.1f}  Pass: {evaluation.pass_}")
            if evaluation.issues:
                for iss in evaluation.issues:
                    log.warning(
                        f"  [{iss.severity}] {iss.file}"
                        + (f" L{iss.line}" if iss.line else "")
                        + f": {iss.description}"
                    )

            iter_duration = time.monotonic() - iter_start
            record = IterationRecord(
                iteration=iteration,
                agents_run=agent_names,
                agent_results=agent_results,
                evaluation=evaluation,
                duration_sec=round(iter_duration, 2),
            )
            iterations.append(record)

            if evaluation.pass_:
                log.info(f"Evaluation PASSED on iteration {iteration}.")
                break

            # Prepare feedback for next iteration
            feedback = {}
            for agent_name, fb in evaluation.feedback_for_agents.items():
                if fb:
                    feedback[agent_name] = fb

            if iteration == MAX_ITERATIONS:
                log.warning(f"Max iterations ({MAX_ITERATIONS}) reached without passing evaluation.")

        final_eval = iterations[-1].evaluation
        total_duration = round(time.monotonic() - start, 2)

        report = HarnessReport(
            task=task,
            start_time=start_time,
            total_duration_sec=total_duration,
            iterations=iterations,
            final_evaluation=final_eval,
            success=final_eval.pass_,
        )

        saved_path = report.save()
        log.info(f"Report saved: {saved_path}")
        return report

    def run_agent(self, agent_name: str, task: str, context: str = "") -> dict[str, Any]:
        """
        Run a single specialist agent directly (no evaluation loop).
        Useful for quick, targeted updates.
        """
        if agent_name not in self.agents:
            raise ValueError(f"Unknown agent: {agent_name!r}. Choose from {list(self.agents)}")
        log.info(f"Running single agent: {agent_name}")
        return self.agents[agent_name].run(task=task, context=context)

    def evaluate_only(self, agent_results: list[dict[str, Any]]) -> EvaluationResult:
        """Run only the evaluator on pre-computed agent results."""
        return self.evaluator.evaluate(agent_results)
