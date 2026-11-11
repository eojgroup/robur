import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("guard", Path(__file__).with_name("check-health-plan.py"))
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)

def resource(kind, after, actions=None):
    return {"address": kind + ".test", "type": kind, "change": {"actions": actions or ["update"], "after": after}}

class PlanBoundaryTests(unittest.TestCase):
    def test_rejects_deletion_other_projects_and_gke(self):
        for value in [resource("google_sql_database", {"project": "claritas"}),
                      resource("google_sql_user", {}, ["delete", "create"]),
                      resource("google_container_cluster", {"project": guard.PROJECT})]:
            self.assertTrue(guard.check({"resource_changes": [value]}))

    def test_rejects_capacity_growth_and_changed_budget_scope(self):
        for value in [resource("google_sql_database_instance", {"settings": [{"tier": "db-custom-2-4096"}]}),
                      resource("google_cloud_run_v2_service", {"template": [{"scaling": [{"max_instance_count": 2}]}]}),
                      resource("google_billing_budget", {"budget_filter": [{"projects": ["projects/other"]}]})]:
            self.assertTrue(guard.check({"resource_changes": [value]}))

    def test_accepts_project_budget_and_unchanged_runtime_identity(self):
        self.assertEqual(guard.check({"resource_changes": [
            resource("google_service_account", {"project": guard.PROJECT}, ["no-op"]),
            resource("google_secret_manager_secret_version", {"project": None, "secret": "projects/" + guard.NUMBER + "/secrets/robur-health-db-runtime"}, ["no-op"]),
            resource("google_billing_budget", {"budget_filter": [{"projects": ["projects/" + guard.NUMBER]}],
                "amount": [{"specified_amount": [{"currency_code": "SEK", "units": "200"}]}]})]}), [])

if __name__ == "__main__":
    unittest.main()
