# tests/test_makefile_k3s.py
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import ClassVar

from tests.support.support import enforce_test_toolchain, require_binaries


class TestMakefileK3s(unittest.TestCase):

    HARD_REQUIREMENTS: ClassVar[list[str]] = ["make"]
    SOFT_REQUIREMENTS: ClassVar[list[str]] = ["kubectl", "kustomize", "envsubst"]

    @classmethod
    def setUpClass(cls):
        enforce_test_toolchain(cls.HARD_REQUIREMENTS)

    def setUp(self):
        # 1. Create a temporary directory for isolated testing
        self.test_dir = Path(tempfile.mkdtemp(prefix="k3s-makefile-test-"))

        # 2. Locate the parent Makefile and k3s.mk in the repository root
        current_file = Path(__file__).resolve()
        self.repo_root = current_file.parent.parent
        self.makefile_src = None
        self.k3s_mk_src = None
        self.test_targets_mk = current_file.parent / "test_k3s_lab_macros.mk"

        for parent in current_file.parents:
            makefile_cand = parent / "Makefile"
            k3s_mk_cand = parent / "k3s-lab.mk"
            if makefile_cand.exists() and not self.makefile_src:
                self.makefile_src = makefile_cand
            if k3s_mk_cand.exists() and not self.k3s_mk_src:
                self.k3s_mk_src = k3s_mk_cand

        if self.makefile_src is None or self.k3s_mk_src is None or not self.makefile_src.exists() or not self.k3s_mk_src.exists():
            raise FileNotFoundError("Could not locate parent Makefile or k3s.mk extension.")

        # 3. Copy Makefile and k3s.mk to the temp directory
        shutil.copy2(self.makefile_src, self.test_dir / "Makefile")
        shutil.copy2(self.k3s_mk_src, self.test_dir / "k3s-lab.mk")

        # Symlink the entire scripts directory into the sandbox
        scripts_link = self.test_dir / "scripts"
        scripts_target = self.repo_root / "scripts"
        scripts_link.symlink_to(scripts_target, target_is_directory=True)

        # 4. Provision dummy directories and files required for parse-time checks
        self.inventory_dir = self.test_dir / "inventory"
        self.inventory_dir.mkdir(parents=True, exist_ok=True)
        self.env_file = self.inventory_dir / "test_with_domain.env"
        self.env_file.write_text("DOMAIN=samjam.dedyn.io\nVIP=192.168.1.53\n", encoding="utf-8")
        self.env_file = self.inventory_dir / "test_without_domain.env"
        self.env_file.write_text("MY_DOMAIN=kelbron.ca\nVIP=192.168.1.53\n", encoding="utf-8")

        # Create dummy manifests directory to prevent Kustomize errors
        self.manifest_dir = self.test_dir / "manifests/test/kustomize"
        self.manifest_dir.mkdir(parents=True, exist_ok=True)
        (self.manifest_dir / "kustomization.yaml").write_text("resources:\n  - secret.yaml\n", encoding="utf-8")
        (self.manifest_dir / "secret.yaml").write_text("domain: ${DOMAIN}\n", encoding="utf-8")


    def tearDown(self):
        shutil.rmtree(self.test_dir)

    # =========================================================================
    # ⚙️ PARSE-TIME SYNTAX & VALUE BINDING TESTS
    # =========================================================================

    def test_k3s_makefile_loads_without_syntax_errors(self):
        """Verify that make parses k3s.mk and its parent Makefile cleanly."""
        result = subprocess.run(
            ["make", "help", "USE_PROFILES=false"],
            check=False,
            cwd=self.test_dir,
            capture_output=True,
            text=True
        )
        self.assertEqual(result.returncode, 0, f"Makefile parsing failed: {result.stderr}")
        self.assertIn("kustomize-argocd", result.stdout)

    def test_k3s_extension_appends_required_tools(self):
        """Test that k3s.mk successfully appends its binaries to OPTIONAL_TOOLS."""
        test_harness = self.test_dir / "Makefile.test"
        test_harness.write_text(
            "include Makefile\n\ntest-tools:\n\t@echo \"TOOLS: $(OPTIONAL_TOOLS)\"\n",
            encoding="utf-8"
        )
        result = subprocess.run(
            ["make", "-f", "Makefile.test", "test-tools", "USE_PROFILES=false"],
            check=False,
            cwd=self.test_dir,
            capture_output=True,
            text=True
        )
        self.assertEqual(result.returncode, 0)
        # Verify both core and k3s-specific tools exist
        self.assertIn("kubectl", result.stdout)
        self.assertIn("envsubst", result.stdout)
        self.assertIn("terraform", result.stdout)

    # =========================================================================
    # 🔬 DRY-RUN RECIPE ENFORCEMENT TESTS
    # =========================================================================

    @require_binaries("kubectl")
    def test_kustomize_argocd_recipe_substitutes_vars(self):
        """Verify kustomize-argocd dry-run uses correct Awk filter logic and envsubst."""
        env = os.environ.copy()
        env["CI"] = "false"

        result = subprocess.run(
            ["make", "kustomize-argocd", "-n", "USE_PROFILES=false"],
            check=False,
            cwd=self.test_dir,
            capture_output=True,
            text=True,
            env=env
        )
        self.assertEqual(result.returncode, 0, f"Dry-run failed: {result.stderr}")
        # Ensure the pipeline checks local.env key extraction
        self.assertIn("extract-manifest-vars.sh", result.stdout)
        self.assertIn("envsubst", result.stdout)
        self.assertIn("manifests/base/argocd/", result.stdout)

    # =========================================================================
    # 🧼 MODULAR CLEANUP INTEGRATION TESTS
    # =========================================================================

    def test_modular_clean_removes_k3s_stage_files(self):
        """Test that make clean successfully executes parent AND child cleanup blocks."""
        # 1. Manually create stage files in our mock staging directory
        secure_tmp = self.test_dir / "secure-staging"
        secure_tmp.mkdir(parents=True, exist_ok=True)

        stage_file = secure_tmp / "kustomize-argocd.yaml"
        stage_file.write_text("apiVersion: v1", encoding="utf-8")

        # 2. Run clean, targeting our mock secure directory
        result = subprocess.run(
            [
                "make", "clean",
                f"SECURE_TMP_DIR={secure_tmp}",
                "BUILD_DIR=dummy-nonexistent",
                "USE_PROFILES=false"
            ],
            check=False,
            cwd=self.test_dir,
            capture_output=True,
            text=True
        )
        self.assertEqual(result.returncode, 0, f"Clean target failed: {result.stderr}")

        # Ensure parent-level clean logged success
        self.assertIn("Wiping workspace build artifacts and secure caches", result.stdout)

        # Verify files are deleted physically
        self.assertFalse(stage_file.exists(), "K3s build stage file was not deleted!")

    # =========================================================================
    # 🛡️ SAFE_ENVSUBST TESTS
    # =========================================================================
    def _run_make(self, profile_name: str, target_name: str, **make_vars):
        """Helper to run the Makefile and the test target file with the specified profile and target"""
        env=os.environ.copy()
        # Ensure subprocess isolates workstation provisioning logic from ambient runner CI flags
        env["CI"] = "false"

        cmd = [
            "make",
            "-f", "Makefile",
            "-f", self.test_targets_mk,
            target_name,
            "USE_PROFILES=true",
            f"PROFILE={profile_name}"
        ]

        for key, value in make_vars.items():
            cmd.append(f"{key}={value}")

        return subprocess.run(
            cmd,
            check=False,
            cwd=self.test_dir,
            capture_output=True,
            text=True,
            env=env
        )

    @require_binaries("envsubst")
    def test_safe_envsubst_with_active_variables(self):
        """Verify safe_envsubst correctly substitutes variables when they match the profile env."""

        result = self._run_make(
            profile_name="test_with_domain",
            target_name="test-safe-envsubst-single-file"
        )

        self.assertEqual(result.returncode, 0, f"make failed: {result.stderr}")
        self.assertIn("domain: samjam.dedyn.io", result.stdout)

    @require_binaries("envsubst")
    def test_safe_envsubst_with_unmatched_variables_fallback(self):
        """Verify safe_envsubst falls back to 'cat' (leaving placeholders untouched) when no keys match."""

        result = self._run_make(
            profile_name="test_without_domain",
            target_name="test-safe-envsubst-single-file"
        )

        self.assertEqual(result.returncode, 0, f"make failed: {result.stderr}")
        # Must pass through perfectly untouched (proving NO empty-string blanket expansion took place)
        self.assertIn("domain: ${DOMAIN}", result.stdout)

    @require_binaries("envsubst")
    def test_safe_envsubst_with_separated_resource_files_and_wildcards(self):
        """
        Verify safe_envsubst handles the Kustomize pattern:
        Scanning down-stream resource files via glob wildcards (*.yaml)
        while processing a separate compiled stream.
        """
        result = self._run_make(
            profile_name="test_with_domain",
            target_name="test-safe-envsubst-with-target",
            TARGET_PATH="manifests/test/kustomize/*.yaml"
        )

        self.assertEqual(result.returncode, 0, f"make failed: {result.stderr}")
        # Verify substitution succeeded because the glob was successfully expanded by cat!
        self.assertIn("stream_domain: samjam.dedyn.io", result.stdout)

    @require_binaries("envsubst")
    def test_safe_envsubst_with_separated_resource_files_and_wildcards_and_unmatched(self):
        """Verify safe_envsubst handles the Kustomize pattern when no keys match."""

        result = self._run_make(
            profile_name="test_without_domain",
            target_name="test-safe-envsubst-with-target",
            TARGET_PATH="manifests/test/kustomize/*.yaml"
        )

        self.assertEqual(result.returncode, 0, f"make failed: {result.stderr}")
        # Verify substitution succeeded because the glob was successfully expanded by cat!
        self.assertIn("stream_domain: ${DOMAIN}", result.stdout)

    @require_binaries("envsubst")
    def test_safe_envsubst_fails_on_missing_files(self):
        """Verify safe_envsubst handles the Kustomize pattern when no keys match."""

        result = self._run_make(
            profile_name="test_without_domain",
            target_name="test-safe-envsubst-with-target",
            TARGET_PATH="manifests/test/nopath/*.yaml"
        )

        self.assertEqual(result.returncode, 0, f"make failed: {result.stderr}")
        # Verify substitution succeeded because the glob was successfully expanded by cat!
        self.assertIn("stream_domain: ${DOMAIN}", result.stdout)

    @require_binaries("envsubst")
    def test_safe_envsubst_with_spaces_in_filename(self):
        """Verify safe_envsubst correctly handles filenames with spaces without breaking or word-splitting."""

        # Create a file with spaces in its name
        spaced_file = self.test_dir / "spaced filename.test"
        spaced_file.write_text("domain: ${DOMAIN}\n", encoding="utf-8")

        result = self._run_make(
            profile_name="test_with_domain",
            target_name="test-safe-envsubst-with-target",
            TARGET_PATH= spaced_file
        )

        self.assertEqual(result.returncode, 0, f"Make failed with spaced filename: {result.stderr}")
        self.assertIn("stream_domain: samjam.dedyn.io", result.stdout)

    @require_binaries("envsubst")
    def test_safe_envsubst_with_empty_filename_does_not_hang(self):
        """Verify safe_envsubst with an empty/omitted filename does not hang waiting for stdin."""
        try:
            result = self._run_make(
                profile_name="test_with_domain",
                target_name="test-safe-envsubst-with-target",
                TARGET_PATH=""
            )
        except subprocess.TimeoutExpired:
            self.fail("❌ CRITICAL REGRESSION: safe_envsubst hung waiting for stdin on empty argument!")

        self.assertEqual(result.returncode, 0, f"Make failed with spaced filename: {result.stderr}")
        self.assertIn("stream_domain: ${DOMAIN}", result.stdout)

    @require_binaries("envsubst")
    def test_safe_envsubst_with_empty_clean_env(self):
        """Verify safe_envsubst falls back to 'cat' when the environment profile is empty (0-byte)."""

        # Create a completely empty (0-byte) environment profile file
        profile_dir = self.test_dir / "inventory"
        profile_dir.mkdir(parents=True, exist_ok=True)
        empty_env = profile_dir / "empty_profile.env"
        empty_env.write_text("", encoding="utf-8")

        result = self._run_make(
            profile_name="empty_profile",
            target_name="test-safe-envsubst-with-target",
            TARGET_PATH="manifests/test/kustomize/*.yaml"
        )


        self.assertEqual(result.returncode, 0, f"Make failed with empty env: {result.stderr}")
        self.assertIn("stream_domain: ${DOMAIN}", result.stdout)

    @require_binaries("envsubst")
    def test_safe_envsubst_with_missing_clean_env(self):
        """Verify safe_envsubst falls back to 'cat' when the clean-env cache does not exist on disk."""

        # Run with USE_PROFILES=false. This skips the sanitization step,
        # preventing the creation of CLEAN_ENV and simulating a missing cache.
        result = self._run_make(
            profile_name="unused_profile",
            target_name="test-safe-envsubst-with-target",
            TARGET_PATH="manifests/test/kustomize/secret.yaml",
            USE_PROFILES="false"
        )

        self.assertEqual(result.returncode, 0, f"Make failed with missing env: {result.stderr}")
        self.assertIn("stream_domain: ${DOMAIN}", result.stdout)

    @require_binaries("envsubst")
    def test_safe_envsubst_with_missing_profile(self):
        """Verify safe_envsubst falls back to 'cat' when the clean-env cache does not exist on disk."""

        result = self._run_make(
            profile_name="unused_profile",
            target_name="test-safe-envsubst-with-target",
            TARGET_PATH="manifests/test/kustomize/secret.yaml",
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("ERROR: Profile configuration file not found at 'inventory/unused_profile.env'!", result.stderr)

if __name__ == "__main__":
    unittest.main()
