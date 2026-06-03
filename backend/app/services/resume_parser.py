"""
Evidence-based resume parser for InterviewMate.

The old parser used broad fuzzy matching over the entire resume. That created
false skills such as Rust, Ruby, Go, and R because short aliases were matched
inside ordinary words. This parser is deliberately conservative:

- exact token/phrase matching instead of whole-document fuzzy matching
- short/ambiguous aliases only count in safe contexts
- skills sections are trusted more than random body text
- scanned/image PDFs return a warning instead of fake skills
"""

from __future__ import annotations

import io
import re
import zipfile
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from typing import Iterable


SECTION_HEADERS = {
    "summary": {
        "summary",
        "profile",
        "objective",
        "career objective",
        "professional summary",
        "about me",
        "personal statement",
    },
    "skills": {
        "skills",
        "technical skills",
        "core skills",
        "key skills",
        "areas of expertise",
        "core competencies",
        "competencies",
        "technical expertise",
        "tools and technologies",
        "tools & technologies",
        "technologies",
        "expertise",
        "hard skills",
        "programming languages",
        "software skills",
        "computer skills",
    },
    "experience": {
        "experience",
        "work experience",
        "professional experience",
        "employment history",
        "career history",
        "work history",
        "employment",
        "career",
        "internship",
        "internships",
    },
    "education": {
        "education",
        "academic background",
        "academic qualification",
        "academic qualifications",
        "qualifications",
        "educational background",
        "degrees",
    },
    "projects": {
        "projects",
        "academic projects",
        "personal projects",
        "key projects",
        "selected projects",
        "project experience",
        "portfolio",
    },
    "certifications": {
        "certifications",
        "certificates",
        "certification",
        "courses",
        "training",
        "licenses",
        "achievements",
    },
}


@dataclass(frozen=True)
class SkillRule:
    name: str
    category: str
    aliases: tuple[str, ...]
    field: str | None = None
    section_only_aliases: tuple[str, ...] = ()


SKILL_RULES: tuple[SkillRule, ...] = (
    # Programming languages
    SkillRule("Python", "Programming Language", ("python", "python3", "python programming"), "Software Engineering"),
    SkillRule("JavaScript", "Programming Language", ("javascript", "java script", "js"), "Software Engineering", ("js",)),
    SkillRule("TypeScript", "Programming Language", ("typescript", "type script", "ts"), "Software Engineering", ("ts",)),
    SkillRule("Java", "Programming Language", ("java",), "Software Engineering"),
    SkillRule("C++", "Programming Language", ("c++", "cpp", "c plus plus"), "Software Engineering"),
    SkillRule("C#", "Programming Language", ("c#", "c sharp", "csharp"), "Software Engineering"),
    SkillRule("PHP", "Programming Language", ("php",), "Software Engineering"),
    SkillRule("Dart", "Programming Language", ("dart",), "Software Engineering"),
    SkillRule("Kotlin", "Programming Language", ("kotlin",), "Software Engineering"),
    SkillRule("Swift", "Programming Language", ("swift",), "Software Engineering"),
    SkillRule("Ruby", "Programming Language", ("ruby", "ruby on rails"), "Software Engineering"),
    SkillRule("Rust", "Programming Language", ("rust", "rustlang"), "Software Engineering"),
    SkillRule("Go", "Programming Language", ("golang", "go language", "go programming", "go"), "Software Engineering", ("go",)),
    SkillRule("R", "Programming Language", ("r programming", "r language", "rstudio", "r"), "Data Science / AI", ("r",)),
    SkillRule("MATLAB", "Programming Language", ("matlab",), "Engineering"),
    SkillRule("Scala", "Programming Language", ("scala",), "Software Engineering"),

    # Web, mobile, backend
    SkillRule("HTML", "Frontend", ("html", "html5"), "Software Engineering"),
    SkillRule("CSS", "Frontend", ("css", "css3"), "Software Engineering"),
    SkillRule("React", "Framework / Library", ("react", "reactjs", "react.js"), "Software Engineering"),
    SkillRule("Angular", "Framework / Library", ("angular", "angularjs"), "Software Engineering"),
    SkillRule("Vue.js", "Framework / Library", ("vue.js", "vuejs", "vue"), "Software Engineering"),
    SkillRule("Node.js", "Framework / Library", ("node.js", "nodejs"), "Software Engineering"),
    SkillRule("Express.js", "Framework / Library", ("express.js", "expressjs"), "Software Engineering"),
    SkillRule("Next.js", "Framework / Library", ("next.js", "nextjs"), "Software Engineering"),
    SkillRule("Django", "Framework / Library", ("django",), "Software Engineering"),
    SkillRule("Flask", "Framework / Library", ("flask",), "Software Engineering"),
    SkillRule("FastAPI", "Framework / Library", ("fastapi", "fast api"), "Software Engineering"),
    SkillRule("Spring Boot", "Framework / Library", ("spring boot", "springboot"), "Software Engineering"),
    SkillRule("Laravel", "Framework / Library", ("laravel",), "Software Engineering"),
    SkillRule("Flutter", "Mobile", ("flutter",), "Software Engineering"),
    SkillRule("Android", "Mobile", ("android",), "Software Engineering"),
    SkillRule("iOS", "Mobile", ("ios", "i os"), "Software Engineering"),
    SkillRule("React Native", "Mobile", ("react native",), "Software Engineering"),

    # Databases and APIs
    SkillRule("SQL", "Database", ("sql",), "Software Engineering"),
    SkillRule("MySQL", "Database", ("mysql", "my sql"), "Software Engineering"),
    SkillRule("PostgreSQL", "Database", ("postgresql", "postgres"), "Software Engineering"),
    SkillRule("SQLite", "Database", ("sqlite",), "Software Engineering"),
    SkillRule("MongoDB", "Database", ("mongodb", "mongo db"), "Software Engineering"),
    SkillRule("Redis", "Database", ("redis",), "Software Engineering"),
    SkillRule("Firebase", "Database / Cloud", ("firebase",), "Software Engineering"),
    SkillRule("REST API", "API", ("rest api", "restful api", "rest apis"), "Software Engineering"),
    SkillRule("GraphQL", "API", ("graphql", "graph ql"), "Software Engineering"),

    # Cloud and DevOps
    SkillRule("Git", "Tool", ("git",), "Software Engineering"),
    SkillRule("GitHub", "Tool", ("github", "git hub"), "Software Engineering"),
    SkillRule("Docker", "Cloud / DevOps", ("docker",), "Software Engineering"),
    SkillRule("Kubernetes", "Cloud / DevOps", ("kubernetes", "k8s"), "Software Engineering"),
    SkillRule("AWS", "Cloud / DevOps", ("aws", "amazon web services"), "Software Engineering"),
    SkillRule("Azure", "Cloud / DevOps", ("azure", "microsoft azure"), "Software Engineering"),
    SkillRule("Google Cloud", "Cloud / DevOps", ("google cloud", "gcp"), "Software Engineering"),
    SkillRule("Linux", "Operating System", ("linux", "ubuntu", "kali linux"), "Cybersecurity"),
    SkillRule("CI/CD", "Cloud / DevOps", ("ci/cd", "cicd", "continuous integration"), "Software Engineering"),
    SkillRule("Jenkins", "Cloud / DevOps", ("jenkins",), "Software Engineering"),
    SkillRule("Terraform", "Cloud / DevOps", ("terraform",), "Software Engineering"),

    # Data science and AI
    SkillRule("Machine Learning", "Machine Learning", ("machine learning", "neural networks", "neural network", "ml"), "Data Science / AI", ("ml",)),
    SkillRule("Deep Learning", "Machine Learning", ("deep learning", "dl"), "Data Science / AI", ("dl",)),
    SkillRule("NLP", "Machine Learning", ("nlp", "natural language processing"), "Data Science / AI"),
    SkillRule("Computer Vision", "Machine Learning", ("computer vision",), "Data Science / AI"),
    SkillRule("Neural Networks", "Machine Learning", ("neural networks", "neural network"), "Data Science / AI"),
    SkillRule("Artificial Intelligence", "Machine Learning", ("artificial intelligence", "ai"), "Data Science / AI", ("ai",)),
    SkillRule("TensorFlow", "Machine Learning", ("tensorflow",), "Data Science / AI"),
    SkillRule("PyTorch", "Machine Learning", ("pytorch", "torch"), "Data Science / AI"),
    SkillRule("Scikit-learn", "Machine Learning", ("scikit-learn", "scikit learn", "sklearn"), "Data Science / AI"),
    SkillRule("Pandas", "Data", ("pandas",), "Data Science / AI"),
    SkillRule("NumPy", "Data", ("numpy",), "Data Science / AI"),
    SkillRule("Power BI", "Analytics", ("power bi", "powerbi"), "Data Science / AI"),
    SkillRule("Tableau", "Analytics", ("tableau",), "Data Science / AI"),
    SkillRule("Excel", "Business / Finance Tool", ("microsoft excel", "ms excel", "excel"), "Business / Management"),

    # Cybersecurity
    SkillRule("Cybersecurity", "Cybersecurity", ("cybersecurity", "cyber security", "information security"), "Cybersecurity"),
    SkillRule("Network Security", "Cybersecurity", ("network security",), "Cybersecurity"),
    SkillRule("Penetration Testing", "Cybersecurity", ("penetration testing", "pentesting", "pen testing"), "Cybersecurity"),
    SkillRule("Vulnerability Assessment", "Cybersecurity", ("vulnerability assessment", "vulnerability analysis"), "Cybersecurity"),
    SkillRule("Incident Response", "Cybersecurity", ("incident response",), "Cybersecurity"),
    SkillRule("Threat Intelligence", "Cybersecurity", ("threat intelligence",), "Cybersecurity"),
    SkillRule("Malware Analysis", "Cybersecurity", ("malware analysis",), "Cybersecurity"),
    SkillRule("Digital Forensics", "Cybersecurity", ("digital forensics", "computer forensics"), "Cybersecurity"),
    SkillRule("Security Auditing", "Cybersecurity", ("security auditing", "security audit", "suid auditing"), "Cybersecurity"),
    SkillRule("SIEM", "Cybersecurity", ("siem",), "Cybersecurity"),
    SkillRule("Splunk", "Cybersecurity", ("splunk",), "Cybersecurity"),
    SkillRule("Wireshark", "Cybersecurity", ("wireshark",), "Cybersecurity"),
    SkillRule("Nmap", "Cybersecurity", ("nmap",), "Cybersecurity"),
    SkillRule("Burp Suite", "Cybersecurity", ("burp suite", "burpsuite"), "Cybersecurity"),
    SkillRule("Metasploit", "Cybersecurity", ("metasploit",), "Cybersecurity"),
    SkillRule("Firewall", "Cybersecurity", ("firewall", "firewalls"), "Cybersecurity"),
    SkillRule("IDS/IPS", "Cybersecurity", ("ids/ips", "ids", "ips", "intrusion detection", "intrusion prevention"), "Cybersecurity", ("ids", "ips")),
    SkillRule("OWASP", "Cybersecurity", ("owasp", "owasp top 10"), "Cybersecurity"),
    SkillRule("SOC", "Cybersecurity", ("soc", "security operations center"), "Cybersecurity", ("soc",)),
    SkillRule("Ethical Hacking", "Cybersecurity", ("ethical hacking", "ethical hacker"), "Cybersecurity"),
    SkillRule("Offensive Security", "Cybersecurity", ("offensive security",), "Cybersecurity"),
    SkillRule("Reconnaissance", "Cybersecurity", ("reconnaissance", "information gathering"), "Cybersecurity"),
    SkillRule("Web Application Security", "Cybersecurity", ("web application attacks", "web application security", "owasp vulnerability testing"), "Cybersecurity"),
    SkillRule("Password Attacks", "Cybersecurity", ("password attacks", "brute force", "hash cracking"), "Cybersecurity"),
    SkillRule("Wireless Security", "Cybersecurity", ("wireless security", "wpa2 assessment"), "Cybersecurity"),
    SkillRule("Routing & Switching", "Networking", ("routing & switching", "routing and switching"), "Cybersecurity"),
    SkillRule("Linux Administration", "Operating System", ("linux administration",), "Cybersecurity"),
    SkillRule("Network Engineering", "Networking", ("network engineering", "network design"), "Cybersecurity"),

    # Design and business
    SkillRule("Figma", "Design", ("figma",), "Design / UX"),
    SkillRule("Adobe XD", "Design", ("adobe xd",), "Design / UX"),
    SkillRule("Photoshop", "Design", ("photoshop", "adobe photoshop"), "Design / UX"),
    SkillRule("Illustrator", "Design", ("illustrator", "adobe illustrator"), "Design / UX"),
    SkillRule("UI/UX Design", "Design", ("ui/ux", "ui ux", "ux design", "user experience"), "Design / UX"),
    SkillRule("Agile", "Project Management", ("agile",), "Business / Management"),
    SkillRule("Scrum", "Project Management", ("scrum",), "Business / Management"),
    SkillRule("Jira", "Project Management", ("jira",), "Business / Management"),
)

SKILL_RULES = SKILL_RULES + (
    # Accounting, finance, banking
    SkillRule("Accounting", "Finance / Accounting", ("accounting", "accountant"), "Finance / Accounting"),
    SkillRule("Bookkeeping", "Finance / Accounting", ("bookkeeping", "book keeping"), "Finance / Accounting"),
    SkillRule("Financial Reporting", "Finance / Accounting", ("financial reporting", "financial statements"), "Finance / Accounting"),
    SkillRule("Auditing", "Finance / Accounting", ("financial audit", "financial auditing", "internal audit", "external audit"), "Finance / Accounting"),
    SkillRule("Taxation", "Finance / Accounting", ("taxation", "tax filing", "tax returns", "income tax"), "Finance / Accounting"),
    SkillRule("Accounts Payable", "Finance / Accounting", ("accounts payable", "payables"), "Finance / Accounting"),
    SkillRule("Accounts Receivable", "Finance / Accounting", ("accounts receivable", "receivables"), "Finance / Accounting"),
    SkillRule("Payroll", "Finance / Accounting", ("payroll",), "Finance / Accounting"),
    SkillRule("Bank Reconciliation", "Finance / Accounting", ("bank reconciliation",), "Finance / Accounting"),
    SkillRule("QuickBooks", "Finance / Accounting", ("quickbooks", "quick books"), "Finance / Accounting"),
    SkillRule("Tally", "Finance / Accounting", ("tally", "tally erp"), "Finance / Accounting"),
    SkillRule("SAP", "ERP", ("sap", "sap erp"), "Business / Management"),
    SkillRule("ERP", "ERP", ("erp", "enterprise resource planning"), "Business / Management"),
    SkillRule("Financial Analysis", "Finance / Accounting", ("financial analysis", "financial analyst"), "Finance / Accounting"),
    SkillRule("Budgeting", "Finance / Accounting", ("budgeting", "budget management"), "Finance / Accounting"),
    SkillRule("Forecasting", "Finance / Accounting", ("forecasting", "financial forecasting"), "Finance / Accounting"),

    # Business, operations, HR, management
    SkillRule("Project Management", "Project Management", ("project management",), "Business / Management"),
    SkillRule("Operations Management", "Business / Management", ("operations management", "operation management"), "Business / Management"),
    SkillRule("Stakeholder Management", "Business / Management", ("stakeholder management",), "Business / Management"),
    SkillRule("Business Analysis", "Business / Management", ("business analysis", "business analyst"), "Business / Management"),
    SkillRule("Process Improvement", "Business / Management", ("process improvement", "business process improvement"), "Business / Management"),
    SkillRule("Data Entry", "Administration", ("data entry",), "Business / Management"),
    SkillRule("Customer Service", "Customer Support", ("customer service", "customer support", "client service"), "Business / Management"),
    SkillRule("Recruitment", "Human Resources", ("recruitment", "talent acquisition", "hiring"), "Human Resources"),
    SkillRule("Onboarding", "Human Resources", ("onboarding", "employee onboarding"), "Human Resources"),
    SkillRule("Performance Management", "Human Resources", ("performance management",), "Human Resources"),
    SkillRule("Employee Relations", "Human Resources", ("employee relations",), "Human Resources"),
    SkillRule("HRIS", "Human Resources", ("hris", "human resource information system"), "Human Resources"),

    # Marketing, sales, media
    SkillRule("Digital Marketing", "Marketing / Sales", ("digital marketing",), "Marketing / Sales"),
    SkillRule("SEO", "Marketing / Sales", ("seo", "search engine optimization"), "Marketing / Sales"),
    SkillRule("SEM", "Marketing / Sales", ("sem", "search engine marketing"), "Marketing / Sales", ("sem",)),
    SkillRule("Social Media Marketing", "Marketing / Sales", ("social media marketing", "social media management"), "Marketing / Sales"),
    SkillRule("Content Marketing", "Marketing / Sales", ("content marketing",), "Marketing / Sales"),
    SkillRule("Email Marketing", "Marketing / Sales", ("email marketing",), "Marketing / Sales"),
    SkillRule("Lead Generation", "Marketing / Sales", ("lead generation",), "Marketing / Sales"),
    SkillRule("CRM", "Marketing / Sales", ("crm", "customer relationship management"), "Marketing / Sales"),
    SkillRule("Salesforce", "Marketing / Sales", ("salesforce",), "Marketing / Sales"),
    SkillRule("Google Analytics", "Marketing / Sales", ("google analytics", "ga4"), "Marketing / Sales"),
    SkillRule("Copywriting", "Marketing / Sales", ("copywriting", "copy writing"), "Marketing / Sales"),

    # Legal
    SkillRule("Legal Research", "Law / Legal", ("legal research",), "Law / Legal"),
    SkillRule("Litigation", "Law / Legal", ("litigation",), "Law / Legal"),
    SkillRule("Contract Drafting", "Law / Legal", ("contract drafting", "contract review", "contracts"), "Law / Legal"),
    SkillRule("Legal Compliance", "Law / Legal", ("legal compliance", "regulatory compliance", "compliance"), "Law / Legal"),
    SkillRule("Corporate Law", "Law / Legal", ("corporate law",), "Law / Legal"),
    SkillRule("Intellectual Property", "Law / Legal", ("intellectual property", "ip law"), "Law / Legal"),

    # Education
    SkillRule("Teaching", "Education / Teaching", ("teaching", "teacher", "lecturer", "instructor"), "Education / Teaching"),
    SkillRule("Curriculum Development", "Education / Teaching", ("curriculum development", "curriculum design"), "Education / Teaching"),
    SkillRule("Lesson Planning", "Education / Teaching", ("lesson planning",), "Education / Teaching"),
    SkillRule("Classroom Management", "Education / Teaching", ("classroom management",), "Education / Teaching"),
    SkillRule("E-learning", "Education / Teaching", ("e-learning", "elearning", "online teaching"), "Education / Teaching"),

    # Healthcare and fitness
    SkillRule("Patient Care", "Healthcare / Medical", ("patient care",), "Healthcare / Medical"),
    SkillRule("Clinical Assessment", "Healthcare / Medical", ("clinical assessment", "clinical diagnosis"), "Healthcare / Medical"),
    SkillRule("Medical Records", "Healthcare / Medical", ("medical records", "ehr", "emr"), "Healthcare / Medical"),
    SkillRule("Pharmacy", "Healthcare / Medical", ("pharmacy", "pharmacist"), "Healthcare / Medical"),
    SkillRule("Nursing", "Healthcare / Medical", ("nursing", "nurse"), "Healthcare / Medical"),
    SkillRule("Physiotherapy", "Healthcare / Medical", ("physiotherapy", "physical therapy"), "Healthcare / Medical"),
    SkillRule("Nutrition", "Healthcare / Medical", ("nutrition", "diet plan", "dietitian"), "Healthcare / Medical"),
    SkillRule("Fitness Training", "Healthcare / Medical", ("fitness training", "personal training", "gym trainer"), "Healthcare / Medical"),

    # Civil, mechanical, electrical, architecture
    SkillRule("AutoCAD", "Engineering Tool", ("autocad", "auto cad"), "Engineering"),
    SkillRule("Revit", "Engineering Tool", ("revit", "autodesk revit"), "Engineering"),
    SkillRule("SketchUp", "Engineering Tool", ("sketchup", "sketch up"), "Engineering"),
    SkillRule("SolidWorks", "Engineering Tool", ("solidworks", "solid works"), "Engineering"),
    SkillRule("ANSYS", "Engineering Tool", ("ansys",), "Engineering"),
    SkillRule("ETABS", "Engineering Tool", ("etabs",), "Engineering"),
    SkillRule("Primavera", "Engineering Tool", ("primavera", "p6"), "Engineering", ("p6",)),
    SkillRule("Structural Analysis", "Engineering", ("structural analysis",), "Engineering"),
    SkillRule("Quantity Surveying", "Engineering", ("quantity surveying", "quantity survey"), "Engineering"),
    SkillRule("Construction Management", "Engineering", ("construction management",), "Engineering"),
    SkillRule("HVAC", "Engineering", ("hvac",), "Engineering"),
    SkillRule("PLC", "Engineering", ("plc", "programmable logic controller"), "Engineering"),
    SkillRule("Control Systems", "Engineering", ("control systems", "control system"), "Engineering"),
    SkillRule("Signal Processing", "Engineering", ("signal processing",), "Engineering"),
    SkillRule("Circuit Design", "Engineering", ("circuit design", "pcb design"), "Engineering"),
    SkillRule("Embedded Systems", "Engineering", ("embedded systems", "embedded system", "embedded system design", "esp8266", "microcontroller", "arduino"), "Engineering"),
    SkillRule("IoT", "Engineering", ("iot", "internet of things"), "Engineering"),
    SkillRule("Raspberry Pi", "Engineering Tool", ("raspberry pi",), "Engineering"),

    # Agriculture, food, apparel, aviation, automotive
    SkillRule("Crop Management", "Agriculture", ("crop management", "crop production"), "Agriculture"),
    SkillRule("Agronomy", "Agriculture", ("agronomy",), "Agriculture"),
    SkillRule("Irrigation", "Agriculture", ("irrigation",), "Agriculture"),
    SkillRule("Soil Analysis", "Agriculture", ("soil analysis", "soil testing"), "Agriculture"),
    SkillRule("Food Safety", "Food / Beverage", ("food safety", "haccp"), "Food / Beverage"),
    SkillRule("Quality Control", "Quality / Testing", ("quality control", "quality assurance"), "Quality / Testing"),
    SkillRule("Merchandising", "Apparel", ("merchandising",), "Apparel"),
    SkillRule("Textile", "Apparel", ("textile", "garment", "apparel"), "Apparel"),
    SkillRule("Aviation Safety", "Aviation", ("aviation safety", "flight safety"), "Aviation"),
    SkillRule("Aircraft Maintenance", "Aviation", ("aircraft maintenance",), "Aviation"),
    SkillRule("Automotive Diagnostics", "Automobile", ("automotive diagnostics", "vehicle diagnostics"), "Automobile"),

    # QA/testing
    SkillRule("Manual Testing", "Quality / Testing", ("manual testing",), "Quality / Testing"),
    SkillRule("Automation Testing", "Quality / Testing", ("automation testing", "test automation"), "Quality / Testing"),
    SkillRule("Selenium", "Quality / Testing", ("selenium",), "Quality / Testing"),
    SkillRule("Cypress", "Quality / Testing", ("cypress",), "Quality / Testing"),
    SkillRule("Playwright", "Quality / Testing", ("playwright",), "Quality / Testing"),
    SkillRule("JMeter", "Quality / Testing", ("jmeter", "apache jmeter"), "Quality / Testing"),
    SkillRule("Postman", "Quality / Testing", ("postman",), "Quality / Testing"),
)


FIELD_SIGNAL_WORDS = {
    "Cybersecurity": (
        "cybersecurity",
        "cyber security",
        "security analyst",
        "soc analyst",
        "penetration testing",
        "vulnerability",
        "network security",
        "incident response",
        "ethical hacking",
        "ceh",
        "security+",
        "wireshark",
        "nmap",
        "burp suite",
        "siem",
    ),
    "Data Science / AI": (
        "data scientist",
        "machine learning",
        "deep learning",
        "nlp",
        "computer vision",
        "tensorflow",
        "pytorch",
        "data analysis",
        "statistical",
    ),
    "Software Engineering": (
        "software engineer",
        "software developer",
        "web developer",
        "frontend",
        "backend",
        "full stack",
        "mobile developer",
        "api",
        "react",
        "flutter",
        "django",
        "fastapi",
    ),
    "Engineering": (
        "instrumentation engineer",
        "research officer",
        "national institute of electronics",
        "electrical engineer",
        "electronic engineer",
        "electronics engineer",
        "electrical engineering",
        "electronics",
        "r&d",
        "mechanical engineer",
        "civil engineer",
        "control system",
        "signal processing",
        "matlab",
        "autocad",
        "solidworks",
    ),
    "Design / UX": (
        "ui designer",
        "ux designer",
        "graphic designer",
        "product designer",
        "figma",
        "wireframe",
        "prototype",
    ),
    "Business / Management": (
        "business analyst",
        "project manager",
        "product manager",
        "operations",
        "management",
        "sales",
        "marketing",
    ),
    "Finance / Accounting": (
        "accountant",
        "accounting",
        "finance",
        "accounting",
        "audit",
        "tax",
        "financial",
        "cfa",
        "cpa",
    ),
    "Healthcare / Medical": (
        "doctor",
        "physician",
        "nurse",
        "medical",
        "clinical",
        "patient",
        "mbbs",
    ),
    "Human Resources": (
        "human resources",
        "hr officer",
        "hr manager",
        "recruitment",
        "talent acquisition",
        "employee relations",
        "onboarding",
        "payroll",
    ),
    "Marketing / Sales": (
        "digital marketing",
        "sales executive",
        "sales manager",
        "marketing manager",
        "seo",
        "social media marketing",
        "lead generation",
        "crm",
        "brand manager",
    ),
    "Law / Legal": (
        "advocate",
        "lawyer",
        "attorney",
        "legal counsel",
        "legal research",
        "litigation",
        "contract drafting",
        "law",
    ),
    "Education / Teaching": (
        "teacher",
        "lecturer",
        "professor",
        "instructor",
        "teaching",
        "curriculum",
        "education",
    ),
    "Agriculture": (
        "agriculture",
        "agricultural",
        "agronomy",
        "crop",
        "soil",
        "irrigation",
    ),
    "Food / Beverage": (
        "food safety",
        "food and beverage",
        "haccp",
        "restaurant",
        "kitchen",
        "chef",
    ),
    "Apparel": (
        "apparel",
        "garment",
        "textile",
        "merchandising",
        "fashion",
    ),
    "Aviation": (
        "aviation",
        "aircraft",
        "flight",
        "cabin crew",
        "airport",
    ),
    "Automobile": (
        "automobile",
        "automotive",
        "vehicle",
        "mechanic",
        "diagnostics",
    ),
    "Quality / Testing": (
        "qa engineer",
        "quality assurance",
        "quality control",
        "software tester",
        "manual testing",
        "automation testing",
        "selenium",
    ),
}


CERTIFICATION_PATTERNS = (
    r"\bceh\b",
    r"\boscp\b",
    r"\bcissp\b",
    r"\bcisa\b",
    r"\bcism\b",
    r"\bcomptia\s+security\+?\b",
    r"\bsecurity\+\b",
    r"\baws certified [a-zA-Z -]+",
    r"\bpmp\b",
    r"\bcfa(?:\s+level\s+[i1-3]+)?\b",
    r"\bcpa\b",
)


SKILL_NAME_PRIORITY = {
    "Cybersecurity": 0,
    "Network Security": 1,
    "Ethical Hacking": 2,
    "Offensive Security": 3,
    "Web Application Security": 4,
    "Linux Administration": 5,
    "Network Engineering": 6,
    "Routing & Switching": 7,
    "Firewall": 8,
    "Nmap": 9,
    "Burp Suite": 10,
    "Wireshark": 11,
    "Metasploit": 12,
    "Machine Learning": 20,
    "Deep Learning": 21,
    "Artificial Intelligence": 22,
    "Computer Vision": 23,
    "TensorFlow": 24,
    "PyTorch": 25,
    "Neural Networks": 26,
    "Control Systems": 30,
    "Signal Processing": 31,
    "Embedded Systems": 32,
    "IoT": 33,
    "Raspberry Pi": 34,
    "Python": 40,
    "Java": 41,
    "C++": 42,
}


PRACTITIONER_DOMAIN_RULES = {
    "Pharmacy": "Healthcare / Medical",
    "Nursing": "Healthcare / Medical",
    "Physiotherapy": "Healthcare / Medical",
    "Nutrition": "Healthcare / Medical",
    "Fitness Training": "Healthcare / Medical",
    "Teaching": "Education / Teaching",
    "E-learning": "Education / Teaching",
}

PRACTITIONER_ALLOWED_SOURCES = {"skills", "experience", "summary"}


def parse_resume(text: str) -> dict:
    raw_text = text or ""
    cleaned_text = _clean_text(raw_text)
    warnings: list[str] = []

    if len(_words(cleaned_text)) < 12:
        warnings.append("No readable text extracted")
        return _empty_profile(warnings=warnings, raw_text_length=len(raw_text))

    lines = _clean_lines(cleaned_text)
    sections = _detect_sections(lines)
    skills = _extract_skills(sections, cleaned_text)
    field = _detect_field(cleaned_text, skills)
    skills = _filter_field_inconsistent_skills(skills, field)
    years_of_experience = max(
        _estimate_explicit_years(cleaned_text),
        _estimate_years(sections.get("experience", "") or cleaned_text),
    )
    seniority = _detect_seniority(cleaned_text, lines, years_of_experience)
    skills = _limit_skills_for_realistic_profile(skills, seniority)

    return {
        "field": field,
        "seniority": seniority,
        "years_of_experience": years_of_experience,
        "skills": skills,
        "education": _extract_education(sections.get("education", ""), cleaned_text),
        "experience": _extract_experience(sections.get("experience", ""), lines),
        "projects": _extract_projects(sections.get("projects", ""), lines),
        "certifications": _extract_certifications(sections.get("certifications", ""), cleaned_text),
        "summary": _extract_summary(sections, lines),
        "warnings": warnings,
    }


def extract_text_from_file(file_bytes: bytes, filename: str = "") -> str:
    fname = (filename or "").lower()
    if fname.endswith(".pdf") or file_bytes.startswith(b"%PDF"):
        return _extract_pdf(file_bytes)
    if fname.endswith(".docx"):
        return _extract_docx(file_bytes)
    if fname.endswith(".txt"):
        return file_bytes.decode("utf-8", errors="ignore")

    try:
        return _extract_pdf(file_bytes)
    except Exception:
        return file_bytes.decode("utf-8", errors="ignore")


def _extract_pdf(file_bytes: bytes) -> str:
    try:
        import PyPDF2
    except ImportError as exc:
        raise ImportError("PyPDF2 is required for PDF parsing") from exc

    reader = PyPDF2.PdfReader(io.BytesIO(file_bytes))
    pages = []
    for page in reader.pages:
        text = page.extract_text() or ""
        if text.strip():
            pages.append(text)
    return "\n".join(pages)


def _extract_docx(file_bytes: bytes) -> str:
    try:
        import docx

        doc = docx.Document(io.BytesIO(file_bytes))
        return "\n".join(p.text for p in doc.paragraphs if p.text.strip())
    except ImportError:
        with zipfile.ZipFile(io.BytesIO(file_bytes)) as archive:
            xml_bytes = archive.read("word/document.xml")
        namespace = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"
        root = ET.fromstring(xml_bytes)
        return " ".join(node.text for node in root.iter(f"{namespace}t") if node.text)


def _clean_text(text: str) -> str:
    replacements = {
        "\u00a0": " ",
        "\u2022": "\n",
        "\u25aa": "\n",
        "\u25cf": "\n",
        "\u2013": "-",
        "\u2014": "-",
        "\u2212": "-",
        "\uf0b7": "\n",
        "\uf076": "\n",
    }
    for old, new in replacements.items():
        text = text.replace(old, new)
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def _clean_lines(text: str) -> list[str]:
    return [line.strip(" -:\t") for line in text.splitlines() if line.strip(" -:\t")]


def _detect_sections(lines: list[str]) -> dict[str, str]:
    sections: dict[str, list[str]] = {"preamble": []}
    current = "preamble"
    header_lookup = {
        variant: section
        for section, variants in SECTION_HEADERS.items()
        for variant in variants
    }

    for line in lines:
        normalized = _header_normalize(line)
        section = header_lookup.get(normalized)
        if section is None and len(normalized) <= 34:
            section = _header_contains(normalized, header_lookup)

        if section:
            current = section
            sections.setdefault(current, [])
            continue

        sections.setdefault(current, []).append(line)

    return {name: "\n".join(value).strip() for name, value in sections.items()}


def _header_normalize(line: str) -> str:
    line = line.strip().lower().strip(":")
    line = re.sub(r"[^a-z0-9+/& #.-]+", " ", line)
    return re.sub(r"\s+", " ", line).strip()


def _header_contains(line: str, lookup: dict[str, str]) -> str | None:
    for header, section in lookup.items():
        if line == header:
            return section
        if len(header) >= 8 and line.startswith(f"{header} "):
            return section
    return None


def _extract_skills(skills_section: str, full_text: str) -> list[dict]:
    if isinstance(skills_section, dict):
        raw_sections = skills_section
        skills_text = raw_sections.get("skills", "")
    else:
        raw_sections = {"skills": skills_section}
        skills_text = skills_section

    sources = [
        ("skills", skills_text, True),
        ("projects", raw_sections.get("projects", ""), False),
        ("experience", raw_sections.get("experience", ""), False),
        ("certifications", raw_sections.get("certifications", ""), False),
        ("education", raw_sections.get("education", ""), False),
        ("summary", raw_sections.get("summary", "") or raw_sections.get("preamble", ""), False),
        ("full_text", full_text, False),
    ]
    found: dict[str, dict] = {}

    for rule in SKILL_RULES:
        best_match = None
        for source_name, source_text, is_skills_section in sources:
            if not _source_allowed_for_rule(rule, source_name):
                continue
            normalized_source = _normalize_for_matching(source_text)
            matched_alias = _rule_match_alias(
                rule,
                normalized_source,
                in_skills_section=is_skills_section,
            )
            if not matched_alias:
                continue
            confidence = _skill_confidence(source_name, is_skills_section)
            evidence = _evidence_snippet(source_text, matched_alias)
            candidate = {
                "source_name": source_name,
                "matched_alias": matched_alias,
                "confidence": confidence,
                "evidence": evidence,
            }
            if best_match is None or candidate["confidence"] > best_match["confidence"]:
                best_match = candidate

        if not best_match:
            continue

        found[rule.name] = {
            "name": rule.name,
            "category": rule.category,
            "source": "resume",
            "confidence": best_match["confidence"],
            "sourceSection": best_match["source_name"],
            "matchedAlias": best_match["matched_alias"],
            "evidence": best_match["evidence"],
        }

    return sorted(
        found.values(),
        key=_skill_sort_key,
    )[:40]


def _skill_sort_key(item: dict) -> tuple:
    return (
        -item["confidence"],
        item["category"],
        SKILL_NAME_PRIORITY.get(item["name"], 1000),
        item["name"].lower(),
    )


def _limit_skills_for_realistic_profile(skills: list[dict], seniority: str) -> list[dict]:
    limit = {
        "Beginner": 14,
        "Mid-Level": 18,
        "Senior": 24,
    }.get(seniority, 16)
    if len(skills) <= limit:
        return skills

    return sorted(skills, key=_profile_skill_sort_key)[:limit]


def _profile_skill_sort_key(item: dict) -> tuple:
    return (
        SKILL_NAME_PRIORITY.get(item["name"], 1000),
        -item["confidence"],
        item["category"],
        item["name"].lower(),
    )


def _skill_confidence(source_name: str, is_skills_section: bool) -> float:
    if is_skills_section:
        return 0.98
    if source_name in {"projects", "experience", "certifications"}:
        return 0.88
    if source_name in {"summary", "education"}:
        return 0.78
    return 0.68


def _source_allowed_for_rule(rule: SkillRule, source_name: str) -> bool:
    if rule.name not in PRACTITIONER_DOMAIN_RULES:
        return True
    return source_name in PRACTITIONER_ALLOWED_SOURCES


def _filter_field_inconsistent_skills(skills: list[dict], field: str) -> list[dict]:
    filtered = []
    for skill in skills:
        expected_field = PRACTITIONER_DOMAIN_RULES.get(skill["name"])
        if not expected_field:
            if field == "Cybersecurity" and skill["category"] == "Programming Language" and skill["name"] != "Python":
                continue
            if field == "Engineering" and skill["name"] in {"JavaScript", "TypeScript"}:
                continue
            if field in {"Engineering", "Data Science / AI", "Cybersecurity"} and skill["category"] == "Frontend":
                continue
            filtered.append(skill)
            continue
        if skill.get("sourceSection") == "skills" or field == expected_field:
            filtered.append(skill)
    return filtered


def _rule_matches(rule: SkillRule, text: str, *, in_skills_section: bool) -> bool:
    return _rule_match_alias(rule, text, in_skills_section=in_skills_section) is not None


def _rule_match_alias(rule: SkillRule, text: str, *, in_skills_section: bool) -> str | None:
    if not text:
        return None

    for alias in rule.aliases:
        if alias in rule.section_only_aliases and not in_skills_section:
            continue
        if _alias_present(alias, text):
            return alias
    return None


def _evidence_snippet(source_text: str, matched_alias: str) -> str:
    source_text = " ".join((source_text or "").split())
    if not source_text:
        return ""
    match = re.search(re.escape(matched_alias), source_text, re.I)
    if not match:
        return source_text[:160]
    start = max(0, match.start() - 70)
    end = min(len(source_text), match.end() + 90)
    return source_text[start:end].strip()


def _alias_present(alias: str, text: str) -> bool:
    alias = _normalize_for_matching(alias)
    if not alias:
        return False

    special = {"c++", "c#", "ci/cd", "ids/ips", "security+"}
    if alias in special:
        return alias in text

    # Exact word/phrase boundary. Prevents "go" in "ongoing" and "java" in
    # "javascript", while still allowing terminal punctuation such as "Nmap.".
    escaped = re.escape(alias)
    pattern = rf"(?<![a-z0-9+#/-]){escaped}(?![a-z0-9+#/-])"
    return re.search(pattern, text) is not None


def _normalize_for_matching(text: str) -> str:
    text = text.lower()
    text = text.replace("&", " and ")
    text = re.sub(r"[\u2010-\u2015]", "-", text)
    text = re.sub(r"[^a-z0-9+#/.-]+", " ", text)
    return re.sub(r"\s+", " ", text).strip()


def _detect_field(text: str, skills: list[dict]) -> str:
    normalized = _normalize_for_matching(text)
    header = _normalize_for_matching(" ".join(_clean_lines(text)[:18]))
    scores = {field: 0.0 for field in FIELD_SIGNAL_WORDS}

    for field, signals in FIELD_SIGNAL_WORDS.items():
        for signal in signals:
            if _alias_present(signal, header):
                is_title_signal = any(word in signal for word in ("engineer", "analyst", "developer", "officer", "institute"))
                scores[field] += 16.0 if is_title_signal else 3.5
            if _alias_present(signal, normalized):
                scores[field] += 3.0 if " " in signal else 1.2

    for skill in skills:
        rule = next((item for item in SKILL_RULES if item.name == skill["name"]), None)
        if rule and rule.field:
            scores[rule.field] = scores.get(rule.field, 0.0) + float(skill.get("confidence", 0.7)) * 0.6

    best_field, best_score = max(scores.items(), key=lambda item: item[1])
    if best_score <= 0:
        return "General"
    return best_field


def _detect_seniority(text: str, lines: list[str], years: int | None = None) -> str:
    normalized = _normalize_for_matching(text)
    header = _normalize_for_matching(" ".join(lines[:12]))
    years = _estimate_years(text) if years is None else years

    if any(_alias_present(item, header) for item in ("senior", "lead", "principal", "manager", "director", "head")):
        return "Senior"
    if any(_alias_present(item, header) for item in ("intern", "trainee", "fresh graduate", "entry level", "junior")):
        return "Beginner"

    if years >= 6:
        return "Senior"
    if years >= 2:
        return "Mid-Level"
    return "Beginner"


def _estimate_years(text: str) -> int:
    normalized = _normalize_for_matching(text)
    explicit_years = _estimate_explicit_years(normalized, normalized=True)
    if explicit_years:
        return explicit_years

    ranges = re.findall(
        r"\b(19\d{2}|20\d{2})\b\s*(?:-|to)\s*\b(19\d{2}|20\d{2}|present|current|now|contd)\b",
        normalized,
    )
    ranges.extend(
        re.findall(
            r"(?:\d{1,2}\s*[-/]\s*\d{1,2}\s*[-/]\s*)?(19\d{2}|20\d{2})\b.{0,24}?\b(?:to|till)\b.{0,24}?\b(19\d{2}|20\d{2}|present|current|now|contd)\b",
            normalized,
        )
    )
    if not ranges:
        return 0

    total = 0
    for start, end in ranges:
        start_year = int(start)
        end_year = 2026 if end in {"present", "current", "now", "contd"} else int(end)
        total += max(0, min(end_year, 2026) - start_year)
    return min(total, 40)


def _estimate_explicit_years(text: str, *, normalized: bool = False) -> int:
    source = text if normalized else _normalize_for_matching(text)
    patterns = (
        r"(\d{1,2})\+?\s+years?\s+of\s+(?:professional\s+)?experience",
        r"(\d{1,2})\+?\s+years?\s+experience",
        r"experience\s+of\s+(\d{1,2})\+?\s+years?",
        r"experience\s*:?\s*(\d{1,2})\+?\s+years?",
    )
    for pattern in patterns:
        match = re.search(pattern, source)
        if match:
            return min(int(match.group(1)), 40)
    return 0


def _extract_education(section: str, full_text: str) -> list[dict]:
    source = section or full_text
    lines = _clean_lines(source)
    degrees = (
        ("PhD", r"\b(ph\.?d|doctorate|doctoral)\b"),
        ("Masters", r"\b(master|m\.?s\.?|m\.?sc|m\.?e\.?|mba|ms)\b"),
        ("Bachelors", r"\b(bachelor|b\.?s\.?|b\.?sc|b\.?e\.?|bs|be|btech|mbbs)\b"),
        ("Diploma", r"\b(diploma)\b"),
    )
    entries = []
    seen = set()
    for i, line in enumerate(lines):
        context = " ".join(lines[max(0, i - 1): i + 3])
        context_lower = context.lower()
        for degree, pattern in degrees:
            if degree in seen or not re.search(pattern, context_lower):
                continue
            entries.append({
                "degree": degree,
                "institution": _find_institution(context),
                "field_of_study": _find_field_of_study(context),
                "year": _find_year(context),
            })
            seen.add(degree)
    return entries[:6]


def _find_institution(text: str) -> str | None:
    for line in _clean_lines(text):
        if re.search(r"\b(university|college|institute|school|academy|nust|fast|uet|comsats|itu|lums|iba)\b", line, re.I):
            return line[:100]
    return None


def _find_field_of_study(text: str) -> str | None:
    match = re.search(
        r"\b(?:in|of)\s+([A-Z][A-Za-z &/.-]{2,70}(?:Engineering|Science|Technology|Security|Business|Commerce|Medicine|Law|Finance|Management))",
        text,
    )
    if match:
        return match.group(1).strip()
    match = re.search(r"\b(?:BS|BE|MS|ME|BSc|MSc)\s+([A-Z][A-Za-z &/.-]{2,55})", text)
    return match.group(1).strip() if match else None


def _find_year(text: str) -> str | None:
    years = re.findall(r"\b(19\d{2}|20\d{2})\b", text)
    return years[-1] if years else None


def _extract_experience(section: str, all_lines: list[str]) -> list[dict]:
    lines = _clean_lines(section)
    if not lines:
        return []

    entries = []
    current = []
    for line in lines:
        starts_new = bool(re.search(r"\b(19\d{2}|20\d{2})\b\s*(?:-|to)\s*(?:19\d{2}|20\d{2}|present|current|now)", line, re.I))
        starts_new = starts_new or bool(re.search(r"\b(engineer|developer|analyst|manager|officer|consultant|intern|researcher|specialist)\b", line, re.I))
        if starts_new and current:
            parsed = _parse_experience_block(current)
            if parsed:
                entries.append(parsed)
            current = []
        current.append(line)

    if current:
        parsed = _parse_experience_block(current)
        if parsed:
            entries.append(parsed)
    return entries[:8]


def _parse_experience_block(lines: list[str]) -> dict | None:
    text = " ".join(lines)
    if len(text) < 12:
        return None

    duration = None
    match = re.search(r"\b(19\d{2}|20\d{2})\b\s*(?:-|to)\s*\b(19\d{2}|20\d{2}|present|current|now|contd)\b", text, re.I)
    if match:
        duration = match.group(0)

    title, company = _split_title_company(lines[0])
    responsibilities = [line[:180] for line in lines[1:] if len(line) > 18][:5]
    return {
        "title": title,
        "company": company,
        "duration": duration,
        "years": _years_from_duration(duration),
        "responsibilities": responsibilities,
    }


def _split_title_company(line: str) -> tuple[str | None, str | None]:
    for separator in (" at ", " @ ", " | ", " - "):
        if separator in line:
            left, right = [part.strip() for part in line.split(separator, 1)]
            if _looks_like_title(left):
                return left[:90], right[:90]
            if _looks_like_title(right):
                return right[:90], left[:90]
    return line[:90], None


def _looks_like_title(text: str) -> bool:
    return bool(re.search(r"\b(engineer|developer|analyst|manager|officer|consultant|intern|researcher|specialist|lead)\b", text, re.I))


def _years_from_duration(duration: str | None) -> int:
    if not duration:
        return 0
    match = re.search(r"\b(19\d{2}|20\d{2})\b.*?\b(19\d{2}|20\d{2}|present|current|now|contd)\b", duration, re.I)
    if not match:
        return 0
    start = int(match.group(1))
    end_value = match.group(2).lower()
    end = 2026 if end_value in {"present", "current", "now", "contd"} else int(end_value)
    return max(0, min(end, 2026) - start)


def _extract_projects(section: str, all_lines: list[str]) -> list[dict]:
    lines = _clean_lines(section)
    if not lines:
        return []

    projects = []
    current = []
    for line in lines:
        starts_new = current and len(line) <= 70 and not line.startswith(("-", "*"))
        if starts_new:
            projects.append(_parse_project_block(current))
            current = []
        current.append(line)
    if current:
        projects.append(_parse_project_block(current))
    return [project for project in projects if project][:8]


def _parse_project_block(lines: list[str]) -> dict:
    text = " ".join(lines)
    project_skills = _extract_skills("", text)
    return {
        "name": lines[0][:80],
        "description": " ".join(lines[1:])[:350] if len(lines) > 1 else text[:350],
        "tech": [skill["name"] for skill in project_skills[:10]],
        "impact": _extract_impact(text),
    }


def _extract_impact(text: str) -> str | None:
    patterns = (
        r"\b\d+%\s+[a-zA-Z]+",
        r"\b(?:reduced|improved|increased|decreased|saved|generated)\b.{0,60}?\b\d+%?",
        r"\b\d+[kmb]?\+?\s+(?:users|customers|requests|transactions|records|students)\b",
    )
    for pattern in patterns:
        match = re.search(pattern, text, re.I)
        if match:
            return match.group(0)[:120]
    return None


def _extract_certifications(section: str, full_text: str) -> list[str]:
    text = f"{section}\n{full_text}"
    found = set()
    for pattern in CERTIFICATION_PATTERNS:
        for match in re.finditer(pattern, text, re.I):
            found.add(_title_certification(match.group(0)))
    return sorted(found)[:12]


def _title_certification(value: str) -> str:
    upper = value.upper().strip()
    known = {"CEH", "OSCP", "CISSP", "CISA", "CISM", "PMP", "CPA"}
    if upper in known:
        return upper
    if "SECURITY" in upper:
        return "CompTIA Security+"
    return value.strip().title()


def _extract_summary(sections: dict[str, str], lines: list[str]) -> str:
    summary = sections.get("summary", "")
    if summary:
        return " ".join(summary.split())[:350]
    preamble = sections.get("preamble", "")
    if preamble:
        return " ".join(preamble.split())[:350]
    return " ".join(lines[:5])[:350]


def _words(text: str) -> list[str]:
    return re.findall(r"[A-Za-z][A-Za-z+#/.-]*", text)


def _empty_profile(*, warnings: list[str] | None = None, raw_text_length: int = 0) -> dict:
    return {
        "field": "General",
        "seniority": "Beginner",
        "years_of_experience": 0,
        "skills": [],
        "education": [],
        "experience": [],
        "projects": [],
        "certifications": [],
        "summary": "",
        "warnings": warnings or [],
        "raw_text_length": raw_text_length,
    }
