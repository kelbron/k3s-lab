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
    SOFT_REQUIREMENTS: ClassVar[list[str]] = ["kubectl", "kustomize", "envsubst", "terraform"]

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
        self.env_file = self.inventory_dir / "test_profile.env"
        self.env_file.write_text("DOMAIN=samjam.dedyn.io\nVIP=192.168.1.53\n", encoding="utf-8")
        self.env_file = self.inventory_dir / "test_profile.tfvars"
        self.env_file.write_text("subscription_id = \"test-id\"\n", encoding="utf-8")

        # Create dummy manifests directory to prevent Kustomize errors
        self.manifest_dir = self.test_dir / "manifests/test/kustomize"
        self.manifest_dir.mkdir(parents=True, exist_ok=True)
        (self.manifest_dir / "kustomization.yaml").write_text("resources:\n  - secret.yaml\n", encoding="utf-8")
        (self.manifest_dir / "secret.yaml").write_text("domain: ${DOMAIN}\n", encoding="utf-8")

        # Copy required base manifests into the temporary test sandbox
        ext_dns_dst = self.test_dir / "manifests/base/external-dns"
        globals_dst = self.test_dir / "manifests/base/globals"

        shutil.copytree(self.repo_root / "manifests/base/external-dns", ext_dns_dst, dirs_exist_ok=True)
        shutil.copytree(self.repo_root / "manifests/base/globals", globals_dst, dirs_exist_ok=True)

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
    def _run_make(self, profile_name: str, target_name: str, dry_run: bool = False, **make_vars):
        """Helper to run the Makefile and the test target file with the specified profile and target"""
        env=os.environ.copy()
        # Ensure subprocess isolates workstation provisioning logic from ambient runner CI flags
        env["CI"] = "false"

        cmd = ["make"]
        if dry_run:
            cmd.append("-n")

        cmd.extend([
            "-f", "Makefile",
            "-f", self.test_targets_mk,
            target_name,
            "USE_PROFILES=true",
            f"PROFILE={profile_name}"
        ])

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

    # =========================================================================
    # 🛡️ TERRAFORM TARGETS & GUARDRAILS TESTS
    # =========================================================================

    def test_guard_tfvars_fails_when_var_file_missing(self):
        """Assert guard-tfvars fails fast with a clear error if the .tfvars file does not exist."""
        result = self._run_make(
            profile_name="test_with_domain",
            target_name="guard-tfvars"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"ERROR: Var file not found at '{self.test_dir}/inventory/test_with_domain.tfvars'", result.stdout)

    def test_guard_tfvars_succeeds_when_var_file_exists(self):
        """Assert guard-tfvars passes when inventory/$(PROFILE).tfvars exists on disk."""
        result = self._run_make(
            profile_name="test_profile",
            target_name="guard-tfvars"
        )
        self.assertEqual(result.returncode, 0, f"guard-tfvars failed: {result.stderr}")

    def test_tf_vars_file_ignores_ambient_environment_overrides(self):
        """Assert TF_VARS_FILE hard-binds to PROFILE and ignores lingering shell environment vars."""
        env = os.environ.copy()
        #  This file exists in the test.dir
        env["TF_VARS_FILE"] = f"{self.test_dir}/inventory/test_profile.tfvars"

        result = self._run_make(
            profile_name="test_with_domain",   # env file exists but tfvars does bot
            target_name="guard-tfvars"
        )

        self.assertNotEqual(result.returncode, 0)
        print(result.stdout)
        # Verify it targeted test_with_domain.tfvars, NOT test_profile.tfvars
        self.assertIn(f"ERROR: Var file not found at '{self.test_dir}/inventory/test_with_domain.tfvars'", result.stdout)

    def test_tf_plan_dry_run_recipe_structure(self):
        """Verify tf-plan dry-run formats terraform plan -out with the secure temp path."""

        (self.test_dir / ".setup_done").touch()   # mock setup done

        result = self._run_make(
            profile_name="test_profile",
            target_name="tf-plan",
            dry_run=True
        )

        print(result.stdout)
        self.assertEqual(result.returncode, 0, f"Dry-run failed: {result.stderr}")
        self.assertIn("terraform -chdir=infrastructure/terraform plan", result.stdout)
        # ensure that -out=tfplan comes after plan allowing for other options
        self.assertRegex(result.stdout, r"(?<=\s)plan\s+.*-out=\S*\/tfplan(?:\s|$)")

    def test_tf_apply_dry_run_recipe_purges_plan_file(self):
        """Verify tf-apply dry-run executes apply on the saved tfplan and cleans it up afterward."""
        (self.test_dir / ".setup_done").touch()   # mock setup done

        result = self._run_make(
            profile_name="test_profile",
            target_name="tf-apply",
            dry_run=True
        )

        self.assertEqual(result.returncode, 0, f"Dry-run failed: {result.stderr}")
        self.assertIn("terraform -chdir=infrastructure/terraform apply", result.stdout)

        # Verifies 'apply' is followed by a plan file ending in '/tfplan', allowing flags in between
        self.assertRegex(result.stdout, r"(?<=\s)apply\s+.*\S*\/tfplan(?:\s|$)")

        # Verifies 'rm -f' explicitly purges the '/tfplan' file path
        self.assertRegex(result.stdout, r"rm\s+-f\s+\S*\/tfplan(?:\s|$)")

    def test_tf_deploy_executes_targets_in_order(self):
        """Verify tf-deploy executes tf-init, tf-plan, and tf-apply in strict sequential order."""
        (self.test_dir / ".setup_done").touch()   # mock setup done

        result = self._run_make(
            profile_name="test_profile",
            target_name="tf-deploy",
            dry_run=True
        )

        self.assertEqual(result.returncode, 0, f"Dry-run failed: {result.stderr}")

        print(result.stdout)
        # Locate the position of each step in the output stream
        init_pos = result.stdout.find("tf-init")
        plan_pos = result.stdout.find("tf-plan")
        apply_pos = result.stdout.find("tf-apply")

        # 1. Assert all targets fired
        self.assertNotEqual(init_pos, -1, "tf-init target was not executed")
        self.assertNotEqual(plan_pos, -1, "tf-plan target was not executed")
        self.assertNotEqual(apply_pos, -1, "tf-apply target was not executed")

        # 2. Assert strict sequential order: init -> plan -> apply
        self.assertTrue(
            init_pos < plan_pos < apply_pos,
            f"Execution order violation! Positions: init={init_pos}, plan={plan_pos}, apply={apply_pos}"
        )

    @require_binaries("kubectl", "envsubst")
    def test_kustomize_external_dns_target(self):
        """Verify 'make kustomize-external-dns' executes the Makefile pipeline cleanly."""
        (self.test_dir / ".setup_done").touch()   # mock setup done

        self.env_file = self.inventory_dir / "test_kustomize_external_dns.env"
        self.env_file.write_text("DOMAIN=samjam.dedyn.io\nVIP=192.168.1.53\nTXT_OWNER_ID=project-id", encoding="utf-8")

        result = self._run_make(
            profile_name="test_kustomize_external_dns",
            target_name="kustomize-external-dns"
        )

        self.assertEqual(result.returncode, 0, f"make kustomize-external-dns failed: {result.stderr}")
        self.assertIn("kind: Deployment", result.stdout)
        self.assertIn("name: external-dns", result.stdout)
        # Verify native Kubelet runtime expansion flags remain untouched
        self.assertIn("--domain-filter=$(DOMAIN)", result.stdout)
        self.assertIn("--txt-owner-id=$(TXT_OWNER_ID)", result.stdout)
        # Verify safe_envsubst properly substituted homelab-globals
        self.assertIn("DOMAIN: samjam.dedyn.io", result.stdout)
        self.assertIn("TXT_OWNER_ID: project-id", result.stdout)

if __name__ == "__main__":
    unittest.main()
