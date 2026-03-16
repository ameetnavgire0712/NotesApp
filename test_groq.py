"""Test Groq speed for HTML cleaning"""
import time
from app.services.html_cleaner import get_html_cleaner

# Simulate larger HTML content (similar to resume)
html_content = '''
<table border="1">
<tr><th>Contact</th><th>Details</th></tr>
<tr><td>Email</td><td>ameet.navgire@gmail.com</td></tr>
<tr><td>Phone</td><td>+91 - 9890000732</td></tr>
<tr><td>Location</td><td>Pune, Maharashtra, India</td></tr>
<tr><td>LinkedIn</td><td>https://www.linkedin.com/in/amit-navgire/</td></tr>
</table>

<table border="1">
<tr><th>Skills Category</th><th>Skills</th></tr>
<tr><td>Technical</td><td>DW Architecture, Cloud Migration, Python, SQL Server, SSIS, SSRS, Power BI, SSAS, Azure Data Factory, Azure SQL DW, Azure Data Lake</td></tr>
<tr><td>Non-Technical</td><td>Project Management, Agile, Client Engagement</td></tr>
<tr><td>Domain</td><td>Banking, Healthcare, Insurance, Education</td></tr>
</table>

<p><b>AMIT NAVGIRE</b></p>
<p>Data Architect & AI COE lead (Dual Role)</p>
<p>Data & AI Engineering Leader with 17+ years of experience building and scaling enterprise-grade data, analytics.</p>

<table border="1">
<tr><th>Company</th><th>Role</th><th>Period</th></tr>
<tr><td>Centric Consulting India</td><td>Technical Architect / Data Architect</td><td>Aug 2022 – present</td></tr>
<tr><td>MSC Software</td><td>Architect</td><td>Jul 2019 – Aug 2022</td></tr>
<tr><td>CloudMoyo Technologies</td><td>Associate Architect</td><td>Oct 2016 – Apr 2019</td></tr>
<tr><td>Nitor Infotech</td><td>Lead Analyst – BI</td><td>Jun 2015 – Sep 2016</td></tr>
<tr><td>Bitwise Solutions</td><td>System Analyst</td><td>Feb 2008 – Apr 2014</td></tr>
</table>
''' * 3  # Multiply to simulate larger content

cleaner = get_html_cleaner()
print(f"Provider: {cleaner.provider}")
print(f"Model: {cleaner.model}")
print(f"Content length: {len(html_content)} chars")
print(f"Has HTML: {cleaner.has_html_content(html_content)}")

print("\nStarting conversion...")
start = time.time()
result = cleaner.clean_content(html_content)
elapsed = time.time() - start

print(f"\n⏱️ Conversion time: {elapsed:.2f}s")
print(f"Output length: {len(result)} chars")
print(f"\n--- Result Preview (first 500 chars) ---\n{result[:500]}")
