from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from app.services.resume_parser import extract_text_from_file, parse_resume  # noqa: E402


def audit_file(path: Path) -> dict:
    text = extract_text_from_file(path.read_bytes(), path.name)
    profile = parse_resume(text)
    return {
        "file": str(path),
        "textLength": len(text or ""),
        "field": profile.get("field"),
        "seniority": profile.get("seniority"),
        "yearsOfExperience": profile.get("years_of_experience"),
        "warnings": profile.get("warnings", []),
        "skills": [item.get("name") for item in profile.get("skills", [])],
        "certifications": profile.get("certifications", []),
    }


def iter_files(paths: list[str]) -> list[Path]:
    found: list[Path] = []
    for raw in paths:
        path = Path(raw)
        if path.is_file():
            found.append(path)
        elif path.is_dir():
            found.extend(sorted(path.rglob("*.pdf")))
            found.extend(sorted(path.rglob("*.docx")))
            found.extend(sorted(path.rglob("*.txt")))
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description="Audit InterviewMate resume parser output.")
    parser.add_argument("paths", nargs="+", help="Resume files or folders")
    parser.add_argument("--json", action="store_true", help="Output JSON instead of Markdown")
    args = parser.parse_args()

    results = [audit_file(path) for path in iter_files(args.paths)]

    if args.json:
        print(json.dumps(results, indent=2, ensure_ascii=False))
        return 0

    print("# Resume Parser Audit")
    print()
    for item in results:
        print(f"## {Path(item['file']).name}")
        print()
        print(f"- Text length: `{item['textLength']}`")
        print(f"- Field: `{item['field']}`")
        print(f"- Seniority: `{item['seniority']}`")
        print(f"- Years: `{item['yearsOfExperience']}`")
        print(f"- Warnings: `{', '.join(item['warnings']) if item['warnings'] else 'none'}`")
        skills = ", ".join(item["skills"]) if item["skills"] else "none"
        print(f"- Skills: {skills}")
        certs = ", ".join(item["certifications"]) if item["certifications"] else "none"
        print(f"- Certifications: {certs}")
        print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
