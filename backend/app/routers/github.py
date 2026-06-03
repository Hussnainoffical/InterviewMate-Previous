from fastapi import APIRouter, HTTPException, Depends
from sqlalchemy.orm import Session
from app.database import get_db
from app.models import GitHubSkillsRequest, GitHubSkillsResponse, SkillItem
from app import crud
from app.services.candidate_profile import analyze_github_profile, skill_names_from_profile

router = APIRouter()


@router.post("/extract-skills")
async def extract_github_skills(body: GitHubSkillsRequest, uid: str = "",
                                 db: Session = Depends(get_db)):
    username = body.githubUsername.strip().split("/")[-1]
    if not username:
        raise HTTPException(status_code=400, detail="GitHub username required")

    profile = await analyze_github_profile(username)
    repo_count = profile.get("public_repos") or profile.get("repo_count") or 0
    skills = [SkillItem(name=name, source="github", verified=True)
              for name in skill_names_from_profile(profile)]

    if not skills:
        skills = [
            SkillItem(name="Python",     source="github", verified=True),
            SkillItem(name="JavaScript", source="github", verified=True),
            SkillItem(name="React",      source="github", verified=True),
            SkillItem(name="Docker",     source="github", verified=True),
        ]
        repo_count = 12

    # Merge into user's skill list in DB
    if uid:
        user = crud.get_user(db, uid)
        if user:
            existing = set(user.skills or [])
            merged   = list(existing | {s.name for s in skills})
            crud.update_user(db, uid, {"skills": merged})

    return GitHubSkillsResponse(
        username=username,
        skills=skills,
        repoCount=repo_count,
        candidateProfile=profile,
    )
