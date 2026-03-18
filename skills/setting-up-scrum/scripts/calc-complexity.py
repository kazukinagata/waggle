#!/usr/bin/env python3
"""Calculate Complexity Score for a task.

Usage:
    calc-complexity.py --acceptance-criteria <text> --description <text> [--blocked-by-depth <n>]

Output: integer score (typical range: 1-13)
"""
import argparse
import math


def count_tokens_approx(text: str) -> int:
    """Rough token count: ~4 chars per token."""
    return max(1, len(text) // 4)


def calculate(acceptance_criteria: str, description: str, blocked_by_depth: int = 0) -> int:
    ac_lines = [l for l in acceptance_criteria.strip().splitlines() if l.strip()]
    ac_points = len(ac_lines) * 2

    desc_tokens = count_tokens_approx(description)
    desc_points = desc_tokens // 200

    depth_points = blocked_by_depth * 2

    raw = ac_points + desc_points + depth_points
    raw = max(1, raw)

    # Snap to Fibonacci-like scale: 1, 2, 3, 5, 8, 13
    fib = [1, 2, 3, 5, 8, 13]
    score = min(fib, key=lambda x: abs(x - raw))
    return score


def main():
    parser = argparse.ArgumentParser(description="Calculate Complexity Score")
    parser.add_argument("--acceptance-criteria", required=True)
    parser.add_argument("--description", required=True)
    parser.add_argument("--blocked-by-depth", type=int, default=0)
    args = parser.parse_args()

    score = calculate(args.acceptance_criteria, args.description, args.blocked_by_depth)
    print(score)


if __name__ == "__main__":
    main()
