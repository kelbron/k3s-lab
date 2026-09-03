import os
import tempfile
import unittest

from scripts.workstation.filter_manifest import filter_manifest


class TestFilterManifest(unittest.TestCase):
    def setUp(self):
        # We explicitly use noqa: SIM115 here to disable Ruff's check for naked NamedTemporaryFiles.
        # We handle the full cleanup lifecycle (closing and unlinking) safely in tearDown().
        self.input_temp = tempfile.NamedTemporaryFile(mode="w+", delete=False, suffix=".yaml")  # noqa: SIM115
        self.output_temp = tempfile.NamedTemporaryFile(mode="w+", delete=False, suffix=".yaml")  # noqa: SIM115

        self.input_temp.close()
        self.output_temp.close()

        self.input_path = self.input_temp.name
        self.output_path = self.output_temp.name

    def tearDown(self):
        if os.path.exists(self.input_path):
            os.unlink(self.input_path)
        if os.path.exists(self.output_path):
            os.unlink(self.output_path)

    def test_happy_path_standard_filtering(self):
        """Asserts that base resources are kept while custom workloads are cleanly stripped."""
        mock_yaml_stream = """---
apiVersion: v1
kind: Namespace
metadata:
  name: argocd
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-application
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argocd-server
"""
        with open(self.input_path, 'w') as f:
            f.write(mock_yaml_stream)

        filter_manifest(self.input_path, self.output_path)

        with open(self.output_path, 'r') as f:
            rendered = f.read()

        self.assertTrue("kind: Namespace" in rendered)
        self.assertTrue("kind: ServiceAccount" in rendered)
        self.assertFalse("kind: Application" in rendered)

    def test_edge_case_nested_block_scalars(self):
        """Asserts that a nested 'kind: Application' inside a ConfigMap string does NOT cause deletion."""
        mock_yaml_stream = """---
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-templates
data:
  nested-app.yaml: |
    apiVersion: argoproj.io/v1alpha1
    kind: Application
    metadata:
      name: nested-app-workload
"""
        with open(self.input_path, 'w') as f:
            f.write(mock_yaml_stream)

        filter_manifest(self.input_path, self.output_path)

        with open(self.output_path, 'r') as f:
            rendered = f.read()

        # The ConfigMap MUST survive because the Application kind was nested and indented
        self.assertTrue("kind: ConfigMap" in rendered)
        self.assertTrue("kind: Application" in rendered)

    def test_edge_case_inline_comments(self):
        """Asserts that inline comments containing targeted keywords do not trigger false-positive deletion."""
        mock_yaml_stream = """---
apiVersion: apps/v1
kind: Deployment # Deploying our core worker Application
metadata:
  name: argocd-repo-server
"""
        with open(self.input_path, 'w') as f:
            f.write(mock_yaml_stream)

        filter_manifest(self.input_path, self.output_path)

        with open(self.output_path, 'r') as f:
            rendered = f.read()

        # The Deployment must survive even though the word 'Application' was in its inline comment
        self.assertTrue("kind: Deployment" in rendered)

    def test_edge_case_exact_matching_suffix_collision(self):
        """Asserts that 'ApplicationSet' is not stripped because exact matching is enforced."""
        mock_yaml_stream = """---
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: dynamic-applications
"""
        with open(self.input_path, 'w') as f:
            f.write(mock_yaml_stream)

        filter_manifest(self.input_path, self.output_path)

        with open(self.output_path, 'r') as f:
            rendered = f.read()

        # ApplicationSet must survive because it's not strictly 'Application' or 'AppProject'
        self.assertTrue("kind: ApplicationSet" in rendered)

if __name__ == '__main__':
    unittest.main()
