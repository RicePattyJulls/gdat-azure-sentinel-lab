# Controlled security scenarios

Use only against your own isolated NovaShop instance. Record the UTC start/end time for
each exercise and reset the database before moving to the next case.

## Evidence package for every case

1. Controlled action from the tester side, with UTC time visible.
2. Raw HTTP and application event in Log Analytics.
3. KQL hunting query and result.
4. Sentinel analytic rule with MITRE and entity mapping.
5. Incident, entities and investigation timeline.
6. Remediation action.
7. Re-test in remediated mode.
8. CSV result, `.kql` query and exported analytic-rule JSON.

Do not publish passwords, access tokens, cookies, client secrets or unredacted tenant
identifiers in screenshots.

## Case WEB-01 — SQL injection in product search

Business risk: an attacker can change the meaning of the product query and retrieve data
that should not match the search term.

Controlled marker:

```text
' OR 1=1 -- 
```

Expected vulnerable result: the search returns the full catalog and the application emits
`product_search` with outcome `candidate_injection_executed`.

Remediation: set `NOVASHOP_LAB_MODE=false`. The same input is passed as a query parameter
instead of being concatenated, so it returns no products.

## Case WEB-02 — IDOR / broken object-level authorization

1. Sign in as `alice.finance` and open order `1001`.
2. Change only the numeric identifier to `1002`, which belongs to `bob.hr`.

Expected vulnerable result: Bob's fictional order is returned and the application emits
`order_access` with outcome `allowed_without_ownership_check`.

Remediation: set `NOVASHOP_LAB_MODE=false`. Repeating the request returns HTTP 403 and
emits `blocked_by_authorization`.

## Case WEB-03 — stored XSS in product reviews

Sign in with a fictional account and publish a harmless, visible proof-of-execution:

```html
<script>document.documentElement.dataset.labXss='executed';alert('NovaShop controlled XSS')</script>
```

Expected vulnerable result: the marker executes when the product page is loaded and the
application emits `review_submitted` with outcome
`candidate_stored_xss_rendered_unsafe`.

Remediation: set `NOVASHOP_LAB_MODE=false`. Jinja autoescaping renders the marker as text
instead of executable markup.

## KQL starting points

The exact App Service table can vary with the diagnostic configuration. For Linux App
Service console logs, begin with:

```kusto
AppServiceConsoleLogs
| where TimeGenerated > ago(1h)
| where ResultDescription has '"kind": "novashop_security"'
| extend Event = parse_json(ResultDescription)
| project TimeGenerated,
          EventType=tostring(Event.event_type),
          Outcome=tostring(Event.outcome),
          ClientIP=tostring(Event.client_ip),
          User=tostring(Event.user),
          RequestId=tostring(Event.request_id),
          RawEvent=Event
| order by TimeGenerated desc
```

HTTP evidence:

```kusto
AppServiceHTTPLogs
| where TimeGenerated > ago(1h)
| project TimeGenerated, CIp, CsMethod, CsUriStem, CsUriQuery, ScStatus, UserAgent
| order by TimeGenerated desc
```

Inspect the real schema in your workspace before turning either query into an analytic
rule. Map the source address to the IP entity and the fictional username to the Account
entity where the resulting columns are available.
