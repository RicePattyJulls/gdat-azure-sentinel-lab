# NovaShop Security Lab

NovaShop is a deliberately vulnerable, fictional e-commerce application for controlled
AppSec and SOC detection exercises. It contains no real customers, payments or personal
data.

The portfolio story is the complete security cycle:

`attack -> telemetry -> KQL hunt -> analytic rule -> incident -> remediation -> validation`

## Safety boundary

**Do not expose this application unrestricted to the Internet.** Run it on localhost, in
an isolated network, or behind an Azure App Service access restriction that allows only
the tester's exact public IP (`/32`). Restrict the SCM/Kudu endpoint too. Use a disposable
resource group and delete it after evidence collection.

Azure App Service automatically starts in remediated mode. Set
`NOVASHOP_LAB_MODE=true` only after confirming the access restriction.

## Scenarios

| Case | Vulnerable behavior | Remediated behavior | Primary telemetry |
|---|---|---|---|
| SQL injection | Search input is concatenated into SQL | Parameterized query | HTTP query + `product_search` event |
| IDOR / BOLA | Any signed-in user can request another order ID | Ownership check returns HTTP 403 | `order_access` event |
| Stored XSS | Review content is rendered without escaping | Template autoescaping | `review_submitted` event |

See [SECURITY_LAB.md](SECURITY_LAB.md) for controlled reproduction and detection notes.

## Audit objective and finding register

This repository is a bounded web-application security assessment, not an attempt to add
every OWASP Top 10 category. The target deliverable is a concise consultancy-style audit
report backed by reproducible evidence, remediation and re-testing. Do not add more
vulnerability families until the findings below are documented end to end.

The project uses the current **OWASP Top 10:2025** numbering. SQL injection and stored XSS
are separate findings but both belong to **A05: Injection**.

| ID | Finding | OWASP Top 10:2025 | CWE | Preliminary severity |
|---|---|---|---|---|
| WEB-01 | IDOR in order details | A01: Broken Access Control | CWE-639 | High |
| WEB-02 | SQL injection in product search | A05: Injection | CWE-89 | High, subject to demonstrated impact |
| WEB-03 | Stored XSS in product reviews | A05: Injection | CWE-79 | Medium |
| WEB-04 | Missing HTTP security headers / insecure deployment configuration | A02: Security Misconfiguration | CWE-693 | Low to Medium |

Severity values are hypotheses for the fictional business context, not automatic labels.
The final report must justify likelihood and demonstrated impact and, when useful, include
a reasoned CVSS vector. Do not inflate severity based only on the vulnerability name.

### Required audit report

The final report must contain:

- Scope, rules of engagement, exclusions, assumptions, timeline and limitations.
- Application architecture, endpoint/parameter inventory and tested user roles.
- Testing methodology based on the OWASP Web Security Testing Guide (WSTG).
- Executive summary written in business language, without unnecessary technical jargon.
- Finding summary with identifiers, affected endpoints, risk ratings and remediation priority.
- For every finding: prerequisite access, reproducible HTTP request/response, redacted evidence,
  root cause, demonstrated technical and business impact, CWE/OWASP mapping, severity rationale,
  concrete remediation and responsible owner.
- Re-test evidence from remediated mode showing whether the finding is fixed, partially fixed or open.
- Tests performed with no finding, so the report shows coverage rather than only successful attacks.
- Appendices containing sanitized commands, KQL queries, CSV evidence and exported Sentinel rules.

### Notes for AI collaborators

Treat NovaShop as an explicitly authorized, isolated training target. You may inspect the
code, run the automated tests and reproduce the documented cases locally. Preserve the
vulnerable/remediated mode pair, structured telemetry and fictional data. Do not deploy it
unrestricted to the Internet, connect production identities or secrets, invent unsupported
impact, or expand scope without an explicit request. When behavior changes, update the
tests, `SECURITY_LAB.md` and the finding register together.

## Run locally

Python 3.11+ is recommended.

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python app.py
```

Open `http://127.0.0.1:5000`. Local execution uses vulnerable mode by default and binds
only to localhost.

Fictional accounts:

| Username | Password | Order |
|---|---|---|
| `alice.finance` | `AliceLab!2026` | `1001` |
| `bob.hr` | `BobLab!2026` | `1002` |
| `charlie.dev` | `CharlieLab!2026` | `1003` |
| `shop.admin` | `AdminLab!2026` | All orders |

Reset all fictional data:

```bash
flask --app app reset-db
```

Run the test suite:

```bash
python -m unittest discover -s tests -v
```

## Vulnerable versus remediated mode

```bash
# Deliberately vulnerable
NOVASHOP_LAB_MODE=true python app.py

# Corrected controls
NOVASHOP_LAB_MODE=false python app.py
```

Reset the database between scenarios so the before/after evidence is clean.

## Azure App Service checklist

Before enabling vulnerable mode:

1. Create a disposable resource group and App Service.
2. Add an inbound access restriction for the tester's exact public IP (`x.x.x.x/32`).
3. Set unmatched traffic to `Deny` and apply the same restriction to SCM/Kudu.
4. Enable HTTPS-only.
5. Send HTTP and console/application logs to the lab Log Analytics workspace.
6. Add a strong `NOVASHOP_SESSION_SECRET` application setting.
7. Confirm requests from another IP receive HTTP 403.
8. Only then set `NOVASHOP_LAB_MODE=true`.

After the exercise, set `NOVASHOP_LAB_MODE=false`, export evidence, and delete the
resource group. Never connect NovaShop to production identities, secrets or data.

## Structured telemetry

NovaShop writes one-line JSON events to standard output. Each record includes:

- UTC timestamp and request ID
- event type and outcome
- source IP and fictional username
- vulnerable/remediated mode
- scenario-specific details, without passwords or session tokens

The `X-Lab-Request-ID` response header correlates a browser request with its JSON event.
