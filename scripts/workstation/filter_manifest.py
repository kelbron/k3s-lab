#!/usr/bin/env python3
"""
Utility script to filter out custom resources from a compiled Kustomize stream.
This facilitates safe multi-phase bootstraps without triggering premature custom API validations.
"""
import os
import sys

import yaml

EXCLUDED_KINDS = {"Application", "AppProject"}


def filter_manifest(input_path: str, output_path: str) -> None:
    if not os.path.isfile(input_path):
        print(f"Error: Input manifest '{input_path}' not found.", file=sys.stderr)
        sys.exit(1)

    with open(input_path, "r", encoding="utf-8") as f:
        documents = list(yaml.safe_load_all(f))

    filtered_docs = [
        doc
        for doc in documents
        if isinstance(doc, dict) and doc.get("kind") not in EXCLUDED_KINDS
    ]

    out_dir = os.path.dirname(output_path)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    with open(output_path, "w", encoding="utf-8") as f:
        yaml.dump_all(
            filtered_docs,
            f,
            default_flow_style=False,
            sort_keys=False,
            explicit_start=True,
        )


if __name__ == "__main__":
    if len(sys.argv) < 3:
        script_name = os.path.basename(sys.argv[0])
        print(f"Usage: {script_name} <input_file> <output_file>", file=sys.stderr)
        sys.exit(1)

    filter_manifest(sys.argv[1], sys.argv[2])

# import sys
# from pathlib import Path


# def filter_manifest(input_path: str, output_path: str) -> None:
#     """
#     Filters out Argo CD Custom Resources (Application, AppProject) from a compiled manifest stream.
#     Strictly parses top-level 'kind:' fields to prevent block scalar and comment collisions.
#     """
#     in_file = Path(input_path)
#     if not in_file.is_file():
#         print(f"Error: Input manifest '{input_path}' not found.", file=sys.stderr)
#         sys.exit(1)

#     documents = in_file.read_text(encoding="utf-8").split("---")

#     filtered_docs = []
#     for doc in documents:
#         doc_strip = doc.strip()
#         if not doc_strip:
#             continue

#         lines = doc_strip.splitlines()
#         is_custom_workload = False

#         for line in lines:
#             line_clean = line.rstrip("\r")

#             # Match top-level keys starting at column 0
#             if line_clean.startswith("kind:"):
#                 parts = line_clean.split(":", 1)
#                 kind_value = parts[1].split("#")[0].strip()

#                 if kind_value in ("Application", "AppProject"):
#                     is_custom_workload = True
#                     break

#         if not is_custom_workload:
#             filtered_docs.append(f"---\n{doc_strip}")

#     out_file = Path(output_path)
#     out_file.parent.mkdir(parents=True, exist_ok=True)
#     out_file.write_text("\n".join(filtered_docs) + "\n", encoding="utf-8")


# if __name__ == "__main__":
#     if len(sys.argv) < 3:
#         script_name = Path(sys.argv[0]).name
#         print(f"Usage: {script_name} <input_file> <output_file>", file=sys.stderr)
#         sys.exit(1)

#     filter_manifest(sys.argv[1], sys.argv[2])
