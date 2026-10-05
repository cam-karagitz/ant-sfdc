# Measuring Apex coverage

Salesforce throws stored coverage away whenever a class is saved, so after a day of deploys the
Tooling API's `ApexCodeCoverageAggregate` reads zero for everything. The measure that holds is a
check-only deploy: it changes nothing in the org and its result carries each class's coverage, and
with `RunSpecifiedTests` Salesforce itself fails it when a class in it is under 75 percent.

```bash
# From antsurance/. Build a manifest and a test list, leaving out whatever is modified right now.
python3 -I scripts/apex_coverage/build.py v1 main      # everything but the slow demo-data group
python3 -I scripts/apex_coverage/build.py v2 slow      # AntsuranceDemoData and its neighbors

# Validate (check-only), once, then read the result when it is done.
sf project deploy start --dry-run --manifest scripts/apex_coverage/out/v1.xml --target-org "$SF_TARGET_ORG" \
  --test-level RunSpecifiedTests $(cat scripts/apex_coverage/out/v1.tests) --async --json
sf project deploy report --job-id <id> --target-org "$SF_TARGET_ORG" --json > scripts/apex_coverage/out/v1-report.json
python3 -I scripts/apex_coverage/report.py scripts/apex_coverage/out/v1-report.json
```

`AntsuranceRenewalJob` has a scheduled job and cannot go in a deploy: run its own test class instead.
