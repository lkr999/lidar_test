"""
Configuration for the LiDAR Golf Putting Analyzer Agent System.
"""
import os
from pathlib import Path

# ── Project Paths ─────────────────────────────────────────────────────────────
PROJECT_ROOT = Path(__file__).parent.parent
IOS_ROOT = PROJECT_ROOT / "ios" / "Runner"
AGENTS_ROOT = PROJECT_ROOT / "agents"
RESULTS_DIR = AGENTS_ROOT / "results"
LOGS_DIR = AGENTS_ROOT / "logs"
PROMPTS_DIR = AGENTS_ROOT / "prompts"

# ── Claude API ────────────────────────────────────────────────────────────────
ANTHROPIC_API_KEY = os.environ.get("ANTHROPIC_API_KEY", "")
MODEL = "claude-opus-4-6"

# ── Agent Settings ────────────────────────────────────────────────────────────
MAX_TOKENS = 8096
MAX_ITERATIONS = 3          # max feedback loop iterations per task
AGENT_MAX_TOOL_ROUNDS = 20  # max tool call rounds per agent turn

# ── Source File Registry ──────────────────────────────────────────────────────
# Maps each specialized agent to its owned source files.
AGENT_FILE_REGISTRY = {
    "lidar": [
        str(IOS_ROOT / "LiDAR" / "LiDARScanner.swift"),
    ],
    "ui": [
        str(IOS_ROOT / "Views" / "MainViewController.swift"),
        str(IOS_ROOT / "Views" / "ScanOverlayView.swift"),
        str(IOS_ROOT / "Views" / "PositionAdjustOverlay.swift"),
        str(IOS_ROOT / "Views" / "MeshGrid3DView.swift"),
        str(IOS_ROOT / "Views" / "TrajectoryOverlayView.swift"),
    ],
    "physics": [
        str(IOS_ROOT / "Utils" / "TerrainAnalyzer.swift"),
        str(IOS_ROOT / "Utils" / "PuttingPhysics.swift"),
        str(IOS_ROOT / "Utils" / "MathUtils.swift"),
    ],
    "vision": [
        str(IOS_ROOT / "Views" / "VisionDetector.swift"),
        str(IOS_ROOT / "Utils" / "DepthImageRenderer.swift"),
    ],
}

# All source files (union of registry)
ALL_SOURCE_FILES = [f for files in AGENT_FILE_REGISTRY.values() for f in files]

# ── Evaluation Thresholds ─────────────────────────────────────────────────────
EVAL_PASS_SCORE = 7          # minimum score (out of 10) to pass evaluation
EVAL_CRITICAL_BLOCK = True   # block on any critical issues regardless of score
