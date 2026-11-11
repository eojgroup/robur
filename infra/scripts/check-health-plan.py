#!/usr/bin/env python3
"""Check a private Terraform plan without printing credentials or payloads."""
import json
import sys

PROJECT = "robur-505508"
NUMBER = "112122569407"
ALLOWED = {
    "google_project_service", "google_sql_database_instance", "google_sql_database", "google_sql_user",
    "random_password", "google_secret_manager_secret", "google_secret_manager_secret_version",
    "google_service_account", "google_project_iam_member", "google_storage_bucket",
    "google_storage_bucket_iam_member", "google_artifact_registry_repository_iam_member",
    "google_secret_manager_secret_iam_member", "google_cloud_run_v2_service",
    "google_cloud_run_v2_service_iam_member", "google_cloud_run_v2_job", "google_billing_budget",
    "google_monitoring_alert_policy", "google_project_iam_custom_role",
}

def check(plan):
    errors = []
    for resource in plan.get("resource_changes", []):
        if resource.get("mode") == "data":
            continue
        kind, address = resource["type"], resource["address"]
        change = resource["change"]
        after = change.get("after") or {}
        if kind not in ALLOWED:
            errors.append(f"{address}: resource type outside the Cloud Run beta")
        if "delete" in change["actions"]:
            errors.append(f"{address}: deletion/replacement requires separate review")
        if after.get("project") is not None and str(after["project"]) not in {PROJECT, NUMBER}:
            errors.append(f"{address}: project must be {PROJECT}")
        if kind == "google_secret_manager_secret_version" and not any(
                str(after.get("secret", "")).startswith(f"projects/{project}/secrets/robur-health-") for project in [PROJECT, NUMBER]):
            errors.append(f"{address}: secret must belong to Robur")
        if kind == "google_sql_database_instance":
            settings = after.get("settings", [{}])[0]
            if (after.get("region") != "europe-west2" or settings.get("tier") != "db-f1-micro"
                    or settings.get("disk_size") != 10 or settings.get("disk_autoresize") is not False
                    or settings.get("availability_type") != "ZONAL"):
                errors.append(f"{address}: database exceeds the approved beta envelope")
        if kind == "google_cloud_run_v2_service":
            template = after.get("template", [{}])[0]
            scaling = template.get("scaling", [{}])[0]
            limits = template.get("containers", [{}])[0].get("resources", [{}])[0].get("limits", {})
            if (scaling.get("min_instance_count", 0) != 0 or scaling.get("max_instance_count") != 1
                    or limits.get("cpu") != "1" or limits.get("memory") != "512Mi"):
                errors.append(f"{address}: service exceeds the approved beta envelope")
        if kind == "google_billing_budget":
            filters = after.get("budget_filter", [{}])[0]
            amount = after.get("amount", [{}])[0].get("specified_amount", [{}])[0]
            cap = {"USD": 25, "SEK": 200}.get(amount.get("currency_code"), 0)
            if filters.get("projects") != [f"projects/{NUMBER}"] or not 0 < int(amount.get("units", 0)) <= cap:
                errors.append(f"{address}: budget scope or alert amount changed")
    return errors

if __name__ == "__main__":
    with open(sys.argv[1]) as source:
        errors = check(json.load(source))
    if errors:
        raise SystemExit("\n".join(errors))
    print("Plan verified: Robur only, no deletions, approved Cloud Run/PostgreSQL capacity.")
