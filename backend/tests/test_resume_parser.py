import re
import unittest

from app.services.resume_parser import SKILL_RULES, parse_resume


def skill_names(profile):
    return {item["name"] for item in profile.get("skills", [])}


class ResumeParserSkillTests(unittest.TestCase):
    def test_does_not_invent_short_alias_programming_languages(self):
        profile = parse_resume(
            """
            Azam Rafique
            Electronic Engineer
            EDUCATION
            Ph.D Control Science and Engineering
            EXPERIENCE
            Research work in control systems, signal processing, sensors,
            industrial automation, Matlab simulations, and laboratory testing.
            """
        )

        names = skill_names(profile)

        self.assertIn("MATLAB", names)
        self.assertNotIn("Ruby", names)
        self.assertNotIn("Rust", names)
        self.assertNotIn("Go", names)
        self.assertNotIn("R", names)
        self.assertNotIn("Swift", names)
        self.assertNotIn("Scala", names)

    def test_extracts_cybersecurity_resume_terms(self):
        profile = parse_resume(
            """
            Muhammad Shahzaib Farooq
            Cybersecurity Analyst
            TECHNICAL SKILLS
            Penetration Testing, Vulnerability Assessment, Network Security,
            Linux, Wireshark, Nmap, Burp Suite, SIEM, Splunk, Firewall,
            Incident Response, Python
            CERTIFICATIONS
            CEH, CompTIA Security+
            """
        )

        names = skill_names(profile)

        self.assertEqual("Cybersecurity", profile["field"])
        self.assertIn("Penetration Testing", names)
        self.assertIn("Vulnerability Assessment", names)
        self.assertIn("Network Security", names)
        self.assertIn("Wireshark", names)
        self.assertIn("Nmap", names)
        self.assertIn("Burp Suite", names)
        self.assertIn("SIEM", names)
        self.assertIn("Splunk", names)
        self.assertIn("Linux", names)
        self.assertIn("Python", names)
        self.assertNotIn("Auditing", names)
        self.assertNotIn("Ruby", names)
        self.assertNotIn("Rust", names)

    def test_security_auditing_is_not_mislabeled_as_finance_auditing(self):
        profile = parse_resume(
            """
            Cybersecurity Analyst
            TECHNICAL SKILLS
            Kali Linux, SUID auditing, user management, cron, Firewall
            PROJECTS
            Performed security audit checks on Linux privilege escalation labs.
            """
        )

        names = skill_names(profile)

        self.assertIn("Security Auditing", names)
        self.assertNotIn("Auditing", names)

    def test_empty_or_scanned_text_returns_warning_without_fake_skills(self):
        profile = parse_resume("")

        self.assertEqual([], profile["skills"])
        self.assertEqual("No readable text extracted", profile["warnings"][0])

    def test_extracts_skills_from_projects_and_experience_without_skills_section(self):
        profile = parse_resume(
            """
            Network Security Intern
            EXPERIENCE
            Investigated suspicious traffic using Wireshark and Nmap.
            Hardened Linux hosts and documented incident response steps.
            PROJECTS
            Built a Python log analyzer for firewall events and Splunk alerts.
            """
        )

        names = skill_names(profile)

        self.assertIn("Wireshark", names)
        self.assertIn("Nmap", names)
        self.assertIn("Linux", names)
        self.assertIn("Incident Response", names)
        self.assertIn("Python", names)
        self.assertIn("Firewall", names)
        self.assertIn("Splunk", names)

    def test_domain_word_in_project_title_is_not_extracted_as_practitioner_skill(self):
        profile = parse_resume(
            """
            Electronic Engineer
            PROJECTS
            S-VIT: Stereo Visual-Inertial Tracking of Lower Limb for
            Physiotherapy Rehabilitation in Context of SLAM Systems.
            Built MATLAB simulations for signal processing and control systems.
            """
        )

        names = skill_names(profile)

        self.assertIn("MATLAB", names)
        self.assertIn("Signal Processing", names)
        self.assertIn("Control Systems", names)
        self.assertNotIn("Physiotherapy", names)

    def test_domain_word_in_experience_title_is_not_extracted_as_practitioner_skill(self):
        profile = parse_resume(
            """
            Electronic Engineer
            EXPERIENCE
            Published S-VIT: Stereo Visual-Inertial Tracking of Lower Limb for
            Physiotherapy Rehabilitation in Context of SLAM Systems.
            Built MATLAB simulations for signal processing and control systems.
            """
        )

        names = skill_names(profile)

        self.assertIn("MATLAB", names)
        self.assertIn("Signal Processing", names)
        self.assertNotIn("Physiotherapy", names)

    def test_shahzaib_style_cybersecurity_profile_stays_realistic(self):
        profile = parse_resume(
            """
            Muhammad Shahzaib Farooq
            PROFILE
            Computer Science student with hands-on offensive security, network
            engineering, and Linux administration work on Kali Linux and EVE-NG.
            CERTIFICATION
            Certified Ethical Hacker (CEH)
            TECHNICAL SKILLS
            Offensive Tools Kali Linux, nmap, Metasploit, Burp Suite, sqlmap,
            Hydra, Hashcat, John the Ripper, hping3, Wireshark, tcpdump,
            netcat, macof, arpspoof, Ettercap
            Reconnaissance theHarvester, Maltego, amass, subfinder, dnsx,
            whatweb, nikto, httpx, crt.sh, GHDB, Shodan
            Wireless airmon-ng, airodump-ng, aireplay-ng, aircrack-ng,
            hcxdumptool, hcxpcapngtool, crunch, macchanger
            Networking TCP/IP, OSI Model, VLANs, Trunking, Inter-VLAN Routing,
            Subnetting, OSPF, EIGRP, RIPv2, Route Redistribution, STP,
            BPDU Guard, NAT/PAT, DHCP, Extended ACLs, Switch Security
            Firewall FortiGate, iptables, ufw, IPSec site-to-site VPN
            Linux Administration Apache, MySQL, vsftpd, Samba, BIND, SSH,
            SELinux, user management, cron, SUID auditing
            Platforms Ubuntu, Windows, EVE-NG, VirtualBox
            Programming Python, C++, Java, Flutter / Dart, HTML, CSS
            """
        )

        names = skill_names(profile)
        expected = {
            "Reconnaissance", "Network Engineering",
            "Linux Administration", "Nmap", "Metasploit", "Burp Suite",
            "Wireshark", "Firewall", "Python",
        }
        overclaimed_tools = {
            "theHarvester", "airmon-ng", "airodump-ng", "aircrack-ng",
            "sqlmap", "Hydra", "Hashcat", "tcpdump", "netcat",
        }

        missing = expected - names
        self.assertEqual(set(), missing)
        self.assertEqual("Beginner", profile["seniority"])
        self.assertLessEqual(len(names), 14)
        self.assertTrue(overclaimed_tools.isdisjoint(names))
        self.assertNotIn("Java", names)

    def test_node_red_and_electronics_express_do_not_create_node_or_express_skills(self):
        profile = parse_resume(
            """
            Nouman Ali
            Electrical Engineer
            EXPERIENCE
            Research Officer at National Institute of Electronics.
            PUBLICATIONS
            Published in IEICE Electronics Express.
            PROJECTS
            IoT Based Smart Energy Meter, smart socket based on ESP8266,
            RFID and Wi-Fi Door Lock based on ESP8266.
            DESIGN PLATFORMS
            Node Red, Android Studio, PlatformIO, MATLAB, Arduino IDE,
            Raspberry Pi, Python, C/C++.
            """
        )

        names = skill_names(profile)

        self.assertEqual("Engineering", profile["field"])
        self.assertIn("IoT", names)
        self.assertIn("Embedded Systems", names)
        self.assertIn("Raspberry Pi", names)
        self.assertNotIn("Node.js", names)
        self.assertNotIn("Express.js", names)

    def test_instrumentation_engineer_with_ten_plus_years_is_senior_engineering(self):
        profile = parse_resume(
            """
            Azam Rafique
            Instrumentation Engineer
            EXPERIENCE: 10+ YEARS
            INSTRUMENTATION ENGINEER working as an Instrumentation Engineer
            since March 20, 2020.
            Worked as an Instrumentation Engineer from 2015 to 2020.
            PhD Research Topic: Deep Learning Based Loop Closure Detection.
            TECHNICAL SKILLS
            Embedded System Design, Raspberry Pi, Arduino, MATLAB, Python,
            Machine Learning, Deep Learning, TensorFlow, PyTorch,
            Computer Vision, Signal Processing, MySQL, Android, Flutter,
            JavaScript, CSS.
            """
        )

        names = skill_names(profile)

        self.assertEqual("Engineering", profile["field"])
        self.assertEqual("Senior", profile["seniority"])
        self.assertEqual(10, profile["years_of_experience"])
        self.assertIn("Embedded Systems", names)
        self.assertIn("Signal Processing", names)
        self.assertIn("MATLAB", names)
        self.assertNotIn("CSS", names)
        self.assertNotIn("JavaScript", names)

    def test_research_officer_electronics_cv_extracts_small_engineering_research_profile(self):
        profile = parse_resume(
            """
            Rizwan Chughtai
            BSc Electrical Engineering (Electronics)
            MSc Electrical Engineering (Communication System)
            PhD Electrical Engineering
            Research Contribution Title: An Efficient Scheme for Automatic
            Pill Recognition Using Neural Networks.
            EXPERIENCE
            Research Officer at NIE (National Institute of Electronics)
            from 21-12-2017 till present.
            R&D in the field of Electronics.
            """
        )

        names = skill_names(profile)

        self.assertEqual("Engineering", profile["field"])
        self.assertEqual("Senior", profile["seniority"])
        self.assertGreaterEqual(profile["years_of_experience"], 6)
        self.assertLessEqual(profile["years_of_experience"], 10)
        self.assertIn("Neural Networks", names)
        self.assertIn("Machine Learning", names)


def _make_skill_rule_test(rule):
    def test(self):
        alias = rule.aliases[0]
        profile = parse_resume(
            f"""
            Candidate Name
            PROFILE
            Resume parser taxonomy smoke test for one supported skill rule.
            EXPERIENCE
            Used the listed capability in a professional or academic project.
            TECHNICAL SKILLS
            {alias}
            """
        )
        self.assertIn(rule.name, skill_names(profile))
    test.__name__ = f"test_skill_rule_extracts_{re.sub(r'[^a-z0-9]+', '_', rule.name.lower()).strip('_')}"
    return test


for index, skill_rule in enumerate(SKILL_RULES):
    test_name = f"test_supported_skill_rule_{index:03d}_{re.sub(r'[^a-z0-9]+', '_', skill_rule.name.lower()).strip('_')}"
    setattr(ResumeParserSkillTests, test_name, _make_skill_rule_test(skill_rule))


if __name__ == "__main__":
    unittest.main()
