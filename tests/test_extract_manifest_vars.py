import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


class TestExtractManifestVars(unittest.TestCase):
    def setUp(self):
        # 1. Create a secure temporary directory for isolated file testing
        self.test_dir = Path(tempfile.mkdtemp(prefix="extract-vars-test-"))

        # 2. Locate the extract-manifest-vars.sh script
        current_file = Path(__file__).resolve()
        self.script_src = None

        # Search parent directories for scripts/workstation/extract-manifest-vars.sh
        for parent in current_file.parents:
            candidate = parent / "scripts" / "workstation" / "extract-manifest-vars.sh"
            if candidate.exists():
                self.script_src = candidate
                break

        if not self.script_src:
            raise FileNotFoundError("Could not locate the 'extract-manifest-vars.sh' script to test.")

        # Copy the script to our temp directory to ensure isolation
        self.script_path = self.test_dir / "extract-manifest-vars.sh"
        shutil.copy2(self.script_src, self.script_path)
        # Ensure it's executable
        self.script_path.chmod(0o755)

    def tearDown(self):
        shutil.rmtree(self.test_dir)

    def run_script(self, env_content: str, manifest_content: str) -> str:
        """Helper to write env and manifest files and execute the stream processor."""
        env_file = self.test_dir / "test.env"
        env_file.write_text(env_content, encoding="utf-8")

        # Run the script, piping manifest_content to stdin
        result = subprocess.run(
            [str(self.script_path), str(env_file)],
            input=manifest_content,
            capture_output=True,
            text=True,
            check=True
        )
        return result.stdout.strip()

    def test_standard_variables_extracted(self):
        """Verify that standard KEY=VALUE variables are correctly parsed and matched."""
        env_content = "DOMAIN=samjam.dedyn.io\nVIP=192.168.1.53\n"
        manifest_content = "apiVersion: v1\nmetadata:\n  domain: ${DOMAIN}\n  ip: $VIP\n"

        output = self.run_script(env_content, manifest_content)

        # Verify both variables are in the output list (order doesn't matter, split by whitespace)
        extracted_vars = set(output.split())
        self.assertEqual(extracted_vars, {"$DOMAIN", "$VIP"})

    def test_unreferenced_variables_ignored(self):
        """Verify that variables in the .env file that are NOT in the manifest are omitted."""
        env_content = "DOMAIN=samjam.dedyn.io\nUNUSED_KEY=ignoreme\n"
        manifest_content = "apiVersion: v1\nmetadata:\n  domain: ${DOMAIN}\n"

        output = self.run_script(env_content, manifest_content)

        extracted_vars = set(output.split())
        self.assertEqual(extracted_vars, {"$DOMAIN"})
        self.assertNotIn("$UNUSED_KEY", extracted_vars)

    def test_export_keywords_handled_correctly(self):
        """
        FAIL-FAST TDD TARGET: Verify that 'export KEY=VALUE' syntax does not record
        'export' as the key name and successfully extracts the actual key name.
        """
        env_content = "export DOMAIN=samjam.dedyn.io\nexport INGRESS_IP=192.168.1.51\n"
        manifest_content = "apiVersion: v1\nmetadata:\n  domain: ${DOMAIN}\n  ip: ${INGRESS_IP}\n  bad: ${export}\n"

        output = self.run_script(env_content, manifest_content)
        extracted_vars = set(output.split())

        # ❌ If the bug is present:
        # - '$DOMAIN' will be missing because it was never recorded
        # - '$export' will be present because 'export' was recorded as the variable name
        # 🟢 If the bug is fixed:
        # - '$DOMAIN' and '$INGRESS_IP' will be correctly extracted
        # - '$export' will NOT be present

        self.assertNotIn("$export", extracted_vars, "❌ BUG DETECTED: The keyword 'export' was incorrectly captured as a variable name!")
        self.assertIn("$DOMAIN", extracted_vars, "❌ BUG DETECTED: The variable 'DOMAIN' was missed due to the leading export statement!")
        self.assertIn("$INGRESS_IP", extracted_vars, "❌ BUG DETECTED: The variable 'INGRESS_IP' was missed due to the leading export statement!")
        self.assertEqual(extracted_vars, {"$DOMAIN", "$INGRESS_IP"})

    def test_empty_env_file_does_not_corrupt_manifest_processing(self):
        """
        Verify that an empty (0-byte) .env file does not cause the first line of the
        manifest stream to be treated as an environment variable and skipped.
        """
        env_content = "" # 0-byte file
        manifest_content = "domain: ${DOMAIN}\n"

        output = self.run_script(env_content, manifest_content)

        # Output must be empty since the env file is empty
        self.assertEqual(output, "")

    def test_indented_export_and_variables(self):
        """
        Verify that variables with leading spaces or tabs (indented variables
        and indented export keywords) are correctly stripped and parsed.
        """
        env_content = (
            "  export DOMAIN=samjam.dedyn.io\n"
            "\texport VIP=192.168.1.53\n"
            "   GATEWAY=192.168.1.1\n"
            "K3S_TOKEN=secret\n"
        )
        manifest_content = (
            "domain: ${DOMAIN}\n"
            "vip: $VIP\n"
            "gateway: ${GATEWAY}\n"
            "token: $K3S_TOKEN\n"
        )

        output = self.run_script(env_content, manifest_content)
        extracted_vars = set(output.split())

        self.assertEqual(extracted_vars, {"$DOMAIN", "$VIP", "$GATEWAY", "$K3S_TOKEN"})

    def test_invalid_and_commented_lines_ignored(self):
        """
        Verify that commented lines, blank lines, whitespace-only lines, and lines
        without assignments are safely ignored by the environment parser.
        """
        env_content = (
            "# IGNORED_VAR=1\n"
            "  # INDENTED_IGNORED=2\n"
            "\n"
            "   \n"
            "export\n"
            "MALFORMED_LINE_NO_EQUALS\n"
            "VALID_VAR=3\n"
        )
        manifest_content = (
            "ignored: ${IGNORED_VAR}\n"
            "indented: $INDENTED_IGNORED\n"
            "exp: $export\n"
            "malformed: $MALFORMED_LINE_NO_EQUALS\n"
            "valid: $VALID_VAR\n"
        )

        output = self.run_script(env_content, manifest_content)
        extracted_vars = set(output.split())

        self.assertNotIn("$export", extracted_vars)
        self.assertNotIn("$IGNORED_VAR", extracted_vars)
        self.assertNotIn("$INDENTED_IGNORED", extracted_vars)
        self.assertNotIn("$MALFORMED_LINE_NO_EQUALS", extracted_vars)
        self.assertEqual(extracted_vars, {"$VALID_VAR"})
        
if __name__ == "__main__":
    unittest.main()
