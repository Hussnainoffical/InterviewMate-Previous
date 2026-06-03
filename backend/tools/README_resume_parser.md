# InterviewMate Resume Parser

This parser is built for conservative resume understanding in InterviewMate.
It extracts structured candidate profile data from readable PDF, DOCX, and TXT
resumes without inventing skills from weak fuzzy matches.

## What It Extracts

- Field/domain, such as Cybersecurity, Software Engineering, Finance, Education,
  Healthcare, Engineering, Marketing, Agriculture, Aviation, and more.
- Seniority and estimated years of experience.
- Skills from explicit skills sections.
- Additional skills from projects, experience, certifications, education, and
  summary text when the evidence is strong.
- Education, experience blocks, projects, certifications, summary, and warnings.

## Accuracy Rules

- Short aliases like `R`, `Go`, `JS`, `TS`, `AI`, and `ML` are restricted so
  they do not match random English words.
- Matching uses exact token/phrase boundaries instead of broad fuzzy matching.
- Every extracted skill includes evidence fields:
  `sourceSection`, `matchedAlias`, `confidence`, and `evidence`.
- Scanned/image-only PDFs return a warning and no fake skills.
- Domain labels such as `Physiotherapy` are not extracted from project titles
  unless they appear in trustworthy candidate-skill contexts.

## Files

- `resume_parser.py` - backend parser implementation.
- `audit_resume_parser.py` - command-line audit tool for PDFs, DOCX, and TXT.
- `test_resume_parser.py` - regression tests for dangerous false positives.

## Run Tests

From the backend folder:

```powershell
C:\Users\hussn\PycharmProjects\Interview\.venv\Scripts\python.exe -m unittest tests.test_resume_parser -v
```

## Audit Resumes

```powershell
C:\Users\hussn\PycharmProjects\Interview\.venv\Scripts\python.exe tools\audit_resume_parser.py "C:\Users\hussn\Downloads\Muhammad Shahzaib Farooq — Cybersecurity CV.pdf"
```

## Important Limitation

Readable text PDFs work. Image-only/scanned resumes need OCR. The current local
environment does not include Tesseract, Poppler, EasyOCR, or another OCR engine,
so the parser intentionally refuses to guess when no text is extractable.
