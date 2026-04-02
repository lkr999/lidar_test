#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
CLI entry point for the LiDAR Golf Putting Analyzer Agent System.

Usage:
    # Run full agent pipeline on a task
    python run.py "Fix the depth frame nil crash in LiDARScanner"

    # Run a specific agent only (no evaluation)
    python run.py --agent lidar "Optimize the heightmap grid cell lookup"

    # Analyze/audit existing code without modifying it
    python run.py --analyze "Review thread safety in LiDARScanner callbacks"

    # List available agents
    python run.py --list-agents

Examples:
    python run.py "Add missing weak self capture in scan completion callback"
    python run.py --agent physics "Improve break calculation accuracy for uphill putts"
    python run.py --agent ui "Fix the level indicator animation stutter during scanning"
"""
import argparse
import sys
import os

# Ensure agents/ directory is on the path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# Early dependency check with a helpful error message
try:
    import anthropic  # noqa: F401
except ModuleNotFoundError:
    print(
        "\nError: 'anthropic' package not found.\n"
        "Install dependencies with:\n\n"
        f"    {sys.executable} -m pip install -r "
        f"{os.path.join(os.path.dirname(os.path.abspath(__file__)), 'requirements.txt')}\n",
        file=sys.stderr,
    )
    sys.exit(1)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="LiDAR Golf Putting Analyzer — Multi-Agent Development System",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("task", nargs="?", help="Task description (natural language)")
    parser.add_argument(
        "--agent", "-a",
        choices=["lidar", "ui", "physics", "vision"],
        help="Run only this specialist agent (skips evaluation loop)",
    )
    parser.add_argument(
        "--analyze",
        action="store_true",
        help="Analysis mode: agents read and report but do NOT write files",
    )
    parser.add_argument(
        "--list-agents",
        action="store_true",
        help="Show available agents and their file domains",
    )
    parser.add_argument(
        "--no-save",
        action="store_true",
        help="Do not save the run report to results/",
    )

    args = parser.parse_args()

    # ── List agents ───────────────────────────────────────────────────────────
    if args.list_agents:
        from config import AGENT_FILE_REGISTRY
        print("\nAvailable agents and their owned files:\n")
        agent_info = {
            "lidar":   "LiDAR Scanning Specialist — ARKit, depth processing, heightmap",
            "ui":      "UI/Views Specialist — MainViewController, overlays, SceneKit",
            "physics": "Physics & Analysis Specialist — TerrainAnalyzer, PuttingPhysics, MathUtils",
            "vision":  "Vision & Detection Specialist — VisionDetector, DepthImageRenderer",
        }
        for name, desc in agent_info.items():
            print(f"  [{name}] {desc}")
            for f in AGENT_FILE_REGISTRY.get(name, []):
                print(f"          {f}")
            print()
        print("  [evaluator] Evaluation Agent — reviews all changes, provides feedback")
        return

    # ── Require task ──────────────────────────────────────────────────────────
    if not args.task:
        parser.print_help()
        sys.exit(1)

    task = args.task
    if args.analyze:
        task = (
            f"[ANALYSIS MODE — do NOT write any files] {task}\n\n"
            "Read the relevant files, analyze the code, and produce a detailed report. "
            "Do not call write_file under any circumstances."
        )

    # ── Run ───────────────────────────────────────────────────────────────────
    try:
        from harness import AgentHarness
    except ImportError as e:
        print(f"Import error: {e}")
        print("Make sure you have installed requirements: pip install -r requirements.txt")
        sys.exit(1)

    harness = AgentHarness()

    if args.agent:
        # Single agent, no evaluation loop
        print(f"\nRunning agent '{args.agent}' on task:\n  {task}\n")
        result = harness.run_agent(args.agent, task)
        print("\n" + "=" * 60)
        print(f"Agent: {result['agent']}")
        print(f"Files written: {[c['path'] for c in result['changes'] if c['action']=='write'] or 'none'}")
        print("\nResult:")
        print(result["result"])
    else:
        # Full pipeline with evaluation
        print(f"\nRunning full agent pipeline on task:\n  {task}\n")
        report = harness.run(task)
        print("\n" + report.summary())


if __name__ == "__main__":
    main()
