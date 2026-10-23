"""
Check Claude (Anthropic) quota and capacity on Microsoft Foundry.

Uses the same Azure Resource Manager APIs documented for Azure OpenAI quota:
    https://learn.microsoft.com/azure/foundry/openai/how-to/quota#programmatically-check-quota-and-capacity

Two endpoints are queried:

1.  Usages API
    GET .../locations/{location}/usages?api-version=2024-10-01
    -> per-region ledger of "limit" vs "currentValue" for each quota line.

2.  Model Capacities API
    GET .../modelCapacities?api-version=2024-10-01
        &modelFormat=Anthropic&modelName={name}&modelVersion={version}
    -> deployable capacity per location + SKU (GlobalStandard) for a model.

Prereqs
-------
*   Azure CLI logged in (`az login --tenant <tenant>`; `az account set -s <sub>`),
    or any other DefaultAzureCredential source.
*   Caller has at least `Cognitive Services Usages Reader` at subscription scope
    (or Reader). Without it the calls return 403.
*   The subscription must be Enterprise or MCA-E for Claude to actually appear
    (per the Foundry docs); on other subscription types the quota lines may be
    absent rather than zero.

Usage
-----
    python src/check_claude_quota.py                       # current `az` sub, default regions
    python src/check_claude_quota.py --subscription <id>
    python src/check_claude_quota.py --regions eastus2 swedencentral
    python src/check_claude_quota.py --json                # raw JSON instead of tables
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, asdict
from typing import Any

import requests
from azure.identity import (
    AzureCliCredential,
    AzureDeveloperCliCredential,
    ChainedTokenCredential,
    DefaultAzureCredential,
)

ARM = "https://management.azure.com"
API_VERSION = "2024-10-01"

# Regions where Claude in Foundry is offered (per the Foundry Claude doc).
DEFAULT_REGIONS = ["eastus2", "swedencentral"]

# Known Claude model IDs in Foundry. Versions are auto-discovered at runtime
# (the Model Capacities API requires `modelVersion`, and Anthropic versions are
# a mix of `1` and date strings like `20251001`).
CLAUDE_MODELS = [
    "claude-mythos-preview",
    "claude-opus-5-5",
    "claude-opus-5-5-fast",
    "claude-opus-4-8",
    "claude-opus-4-7",
    "claude-opus-4-6",
    "claude-opus-4-5",
    "claude-opus-4-1",
    "claude-sonnet-5-5",
    "claude-sonnet-4-6",
    "claude-sonnet-4-5",
    "claude-haiku-5-5",
    "claude-haiku-4-5",
]

# Regions used for auto-discovery of (model, version) pairs. Claude is currently
# only listed under these locations; discovery in one is sufficient.
DISCOVERY_REGIONS = ["eastus2", "swedencentral"]

MODEL_FORMAT = "Anthropic"

# RPM is NOT a separate quota line for Claude in the Usages API. The Foundry
# Claude docs publish fixed RPM:TPM ratios per model; we derive RPM from the
# TPM limit using these ratios. Source:
#   https://learn.microsoft.com/azure/foundry/foundry-models/concepts/claude-models-quotas-limits
# Format: RPM per 1,000 TPM (i.e. multiply by the "thousands" units the API
# returns to get RPM).
RPM_PER_KTPM: dict[str, float] = {
    "claude-opus-5-5": 1.0,   # 10,000 RPM / 10,000 k-ITPM
    "claude-opus-5-5-fast": 1.0,
    "claude-opus-4-8": 1.0,
    "claude-opus-4-7": 1.0,
    "claude-opus-4-6": 1.0,
    "claude-opus-4-5": 1.0,
    "claude-opus-4-1": 1.0,
    "claude-sonnet-5-5": 1.0,
    "claude-sonnet-4-6": 1.0,
    "claude-sonnet-4-5": 1.0,
    "claude-haiku-5-5": 1.0,
    "claude-haiku-4-5": 1.0,
    "claude-mythos-preview": 1.0,
}


@dataclass
class QuotaLine:
    region: str
    name: str
    localized: str
    current: float
    limit: float
    model: str | None = None  # parsed Claude model id, when identifiable

    @property
    def pct(self) -> float:
        return (self.current / self.limit * 100.0) if self.limit else 0.0

    @property
    def rpm_limit(self) -> float | None:
        """Derived RPM limit from the published RPM:TPM ratio for this model."""
        if not self.model:
            return None
        ratio = RPM_PER_KTPM.get(self.model)
        if ratio is None:
            return None
        return self.limit * ratio  # limit is in thousands-of-TPM

    @property
    def rpm_used(self) -> float | None:
        if not self.model:
            return None
        ratio = RPM_PER_KTPM.get(self.model)
        if ratio is None:
            return None
        return self.current * ratio


@dataclass
class CapacityLine:
    model: str
    region: str
    sku: str
    available: float
    available_finetune: float | None


def _get_current_subscription() -> str:
    """Resolve a subscription id from AZURE_SUBSCRIPTION_ID or `az account show`."""
    env = os.environ.get("AZURE_SUBSCRIPTION_ID")
    if env:
        return env.strip()
    try:
        out = subprocess.check_output(
            ["az", "account", "show", "--query", "id", "-o", "tsv"],
            stderr=subprocess.STDOUT,
            text=True,
        )
        return out.strip()
    except (subprocess.CalledProcessError, FileNotFoundError) as ex:
        raise SystemExit(
            "Could not resolve a subscription id. Either:\n"
            "  * set $env:AZURE_SUBSCRIPTION_ID, or\n"
            "  * pass --subscription <id>, or\n"
            "  * install Azure CLI and run `az login` so `az account show` works.\n"
            f"Underlying error: {ex}"
        )


def _bearer_token(tenant_id: str | None = None) -> str:
    """
    Build a token-getter. When ``tenant_id`` is supplied we try AzureCliCredential
    and AzureDeveloperCliCredential against that tenant explicitly (DefaultAzureCredential
    doesn't accept a flat ``tenant_id`` argument). Otherwise fall back to the full
    DefaultAzureCredential chain.
    """
    if tenant_id:
        cred = ChainedTokenCredential(
            AzureCliCredential(tenant_id=tenant_id),
            AzureDeveloperCliCredential(tenant_id=tenant_id),
        )
    else:
        cred = DefaultAzureCredential(exclude_interactive_browser_credential=False)
    return cred.get_token(f"{ARM}/.default").token


def _is_claude(item: dict[str, Any]) -> bool:
    """
    A usage line is Claude-related if its quota name references Anthropic or a
    known Claude model. The name format is `{Provider}.{DeploymentType}.{Model}`.
    """
    name = (item.get("name", {}) or {}).get("value", "") or ""
    localized = (item.get("name", {}) or {}).get("localizedValue", "") or ""
    haystack = f"{name} {localized}".lower()
    if "anthropic" in haystack or "claude" in haystack:
        return True
    return any(m in haystack for m in CLAUDE_MODELS)


def fetch_usages(subscription_id: str, region: str, token: str) -> list[QuotaLine]:
    url = (
        f"{ARM}/subscriptions/{subscription_id}"
        f"/providers/Microsoft.CognitiveServices/locations/{region}/usages"
        f"?api-version={API_VERSION}"
    )
    r = requests.get(url, headers={"Authorization": f"Bearer {token}"}, timeout=30)
    if r.status_code == 403:
        raise PermissionError(
            f"403 from Usages API in {region}. Grant the caller "
            f"'Cognitive Services Usages Reader' at the subscription scope."
        )
    r.raise_for_status()
    payload = r.json()
    lines: list[QuotaLine] = []
    for item in payload.get("value", []):
        if not _is_claude(item):
            continue
        name = (item.get("name") or {}).get("value", "")
        # Quota name format: AIServices.GlobalStandard.<model-id>
        model_id = name.split(".")[-1] if name else None
        lines.append(
            QuotaLine(
                region=region,
                name=name,
                localized=(item.get("name") or {}).get("localizedValue", ""),
                current=float(item.get("currentValue", 0) or 0),
                limit=float(item.get("limit", 0) or 0),
                model=model_id,
            )
        )
    return lines


def fetch_capacity(
    subscription_id: str, model: str, version: str, token: str
) -> list[CapacityLine]:
    url = (
        f"{ARM}/subscriptions/{subscription_id}"
        f"/providers/Microsoft.CognitiveServices/modelCapacities"
        f"?api-version={API_VERSION}"
        f"&modelFormat={MODEL_FORMAT}"
        f"&modelName={model}"
        f"&modelVersion={version}"
    )
    r = requests.get(url, headers={"Authorization": f"Bearer {token}"}, timeout=30)
    # 404 / empty value means the model isn't surfaced in this subscription
    # (often a subscription-type or onboarding issue for Claude). Treat as empty.
    if r.status_code == 404:
        return []
    if r.status_code == 403:
        raise PermissionError(
            "403 from Model Capacities API. Grant the caller 'Cognitive Services "
            "Usages Reader' (or Reader) at the subscription scope."
        )
    r.raise_for_status()
    payload = r.json()
    out: list[CapacityLine] = []
    for item in payload.get("value", []):
        props = item.get("properties", {}) or {}
        out.append(
            CapacityLine(
                model=f"{model}:{version}",
                region=item.get("location", ""),
                sku=props.get("skuName", ""),
                available=float(props.get("availableCapacity", 0) or 0),
                available_finetune=(
                    float(props["availableFinetuneCapacity"])
                    if props.get("availableFinetuneCapacity") is not None
                    else None
                ),
            )
        )
    return out


def discover_claude_versions(
    subscription_id: str, token: str, regions: list[str] = DISCOVERY_REGIONS
) -> dict[str, set[str]]:
    """Return {model_name -> {versions...}} for every Claude model visible to the sub."""
    found: dict[str, set[str]] = {}
    for region in regions:
        url = (
            f"{ARM}/subscriptions/{subscription_id}"
            f"/providers/Microsoft.CognitiveServices/locations/{region}/models"
            f"?api-version={API_VERSION}"
        )
        r = requests.get(url, headers={"Authorization": f"Bearer {token}"}, timeout=30)
        if r.status_code >= 400:
            continue
        for item in (r.json().get("value") or []):
            m = item.get("model") or {}
            if m.get("format") != MODEL_FORMAT:
                continue
            name = m.get("name")
            version = m.get("version")
            if not name or not version:
                continue
            found.setdefault(name, set()).add(version)
    return found


def _print_merged(usages: list[QuotaLine], capacities: list[CapacityLine]) -> None:
    """Single unified table keyed on (model, region).

    Combines:
      * Usages API   -> TPM used / TPM limit / derived RPM limit
      * Capacity API -> deployable capacity (model:version : available)
      * Doc defaults -> not inferred; vary by subscription type and hosting.

    Outer-join: capacity may exist in regions where no quota has been
    consumed yet, and vice versa.
    """
    # Index by (model, region)
    u_idx: dict[tuple[str, str], QuotaLine] = {
        (u.model, u.region): u for u in usages if u.model
    }
    # Group capacity by (model_base, region) -> list of "version:available"
    c_idx: dict[tuple[str, str], list[CapacityLine]] = {}
    for c in capacities:
        base = c.model.split(":", 1)[0]
        c_idx.setdefault((base, c.region), []).append(c)

    keys = sorted(set(u_idx) | set(c_idx))
    if not keys:
        print("  (no Claude quota or capacity visible)")
        return

    headers = (
        "Model", "Region", "SKU",
        "Def RPM", "Def TPM",
        "TPM Used", "TPM Limit", "TPM %",
        "RPM Limit*", "Capacity", "Version",
    )
    data: list[tuple[str, ...]] = []
    for model, region in keys:
        u = u_idx.get((model, region))
        caps = c_idx.get((model, region), [])
        cap = caps[0] if caps else None
        if u:
            tpm_used = f"{u.current * 1000:,.0f}"
            tpm_lim = f"{u.limit * 1000:,.0f}"
            tpm_pct = f"{u.pct:.1f}%"
            rpm_lim = f"{u.rpm_limit:,.0f}" if u.rpm_limit is not None else "-"
        else:
            tpm_used = tpm_lim = tpm_pct = rpm_lim = "-"
        sku = cap.sku if cap else "GlobalStandard"
        cap_avail = f"{cap.available:,.0f}" if cap else "-"
        version = cap.model.split(":", 1)[1] if cap and ":" in cap.model else "-"
        data.append((
            model, region, sku,
            "-", "-",
            tpm_used, tpm_lim, tpm_pct,
            rpm_lim, cap_avail, version,
        ))

    widths = [max(len(h), max(len(r[i]) for r in data)) for i, h in enumerate(headers)]
    # Right-align numeric columns; left-align identifiers.
    right_align = {3, 4, 5, 6, 7, 8, 9}
    align_specs = [">" if i in right_align else "<" for i in range(len(headers))]
    fmt = "  " + "  ".join(f"{{:{a}{w}}}" for a, w in zip(align_specs, widths))
    print(fmt.format(*headers))
    print("  " + "  ".join("-" * w for w in widths))
    for r in data:
        print(fmt.format(*r))
    print(
        "\n  * RPM Limit is DERIVED from the per-model RPM:TPM ratios published in the\n"
        "    Foundry Claude docs; it is not a separate quota line in the Usages API.\n"
        "  Def RPM/TPM are '-' because defaults depend on subscription type and hosting."
    )


def _print_usages(lines: list[QuotaLine]) -> None:
    if not lines:
        print("  (no Claude/Anthropic quota lines visible in this subscription)")
        return
    width_region = max(len(l.region) for l in lines)
    width_name = max(len(l.localized or l.name) for l in lines)
    print(
        f"  {'REGION'.ljust(width_region)}  "
        f"{'QUOTA'.ljust(width_name)}  "
        f"{'TPM USED':>14}  {'TPM LIMIT':>14}  {'TPM %':>6}  "
        f"{'RPM USED*':>10}  {'RPM LIMIT*':>11}"
    )
    for l in sorted(lines, key=lambda x: (x.region, x.localized or x.name)):
        label = l.localized or l.name
        rpm_u = f"{l.rpm_used:>10,.0f}" if l.rpm_used is not None else "          -"
        rpm_l = f"{l.rpm_limit:>11,.0f}" if l.rpm_limit is not None else "           -"
        print(
            f"  {l.region.ljust(width_region)}  "
            f"{label.ljust(width_name)}  "
            f"{l.current:>14,.0f}  {l.limit:>14,.0f}  {l.pct:>5.1f}%  "
            f"{rpm_u}  {rpm_l}"
        )
    print(
        "  * RPM columns are DERIVED from the documented per-model RPM:TPM ratios\n"
        "    (Foundry Claude docs); they are not separate quota lines in the API."
    )


def _print_doc_style(lines: list[QuotaLine]) -> None:
    """Print one row per (model, region) in the Foundry-doc table format.

    Columns: Model | Region | Deployment type | Default RPM | Default TPM |
             EA/MCA-E RPM | EA/MCA-E TPM

    "Default" is not inferred. Subscription and hosting types have different
    defaults. Other columns show the actual values pulled from this
    subscription's Usages API (TPM) and derived RPM.
    """
    rows = [l for l in lines if l.model]
    if not rows:
        print("  (no Claude quota visible)")
        return
    rows.sort(key=lambda x: (x.model or "", x.region))
    headers = (
        "Model", "Region", "Deployment type",
        "Default RPM", "Default TPM",
        "EA/MCA-E RPM", "EA/MCA-E TPM",
    )
    data = []
    for l in rows:
        tpm_limit = l.limit * 1000  # API reports in thousands
        rpm_limit = l.rpm_limit
        rpm_str = f"{rpm_limit:,.0f}" if rpm_limit is not None else "-"
        data.append((
            l.model or "",
            l.region,
            "Global Standard",
            "-", "-",
            rpm_str,
            f"{tpm_limit:,.0f}",
        ))
    widths = [max(len(h), max(len(r[i]) for r in data)) for i, h in enumerate(headers)]
    fmt = "  " + "  ".join(f"{{:<{w}}}" for w in widths)
    print(fmt.format(*headers))
    print("  " + "  ".join("-" * w for w in widths))
    for r in data:
        print(fmt.format(*r))


def _print_capacities(lines: list[CapacityLine], regions_filter: list[str]) -> None:
    lines = [l for l in lines if not regions_filter or l.region in regions_filter]
    if not lines:
        print("  (no Claude model capacity visible in the requested regions)")
        return
    width_model = max(len(l.model) for l in lines)
    width_region = max(len(l.region) for l in lines)
    width_sku = max(len(l.sku) for l in lines)
    print(
        f"  {'MODEL'.ljust(width_model)}  "
        f"{'REGION'.ljust(width_region)}  "
        f"{'SKU'.ljust(width_sku)}  {'AVAILABLE':>12}"
    )
    for l in sorted(lines, key=lambda x: (x.model, x.region, x.sku)):
        print(
            f"  {l.model.ljust(width_model)}  "
            f"{l.region.ljust(width_region)}  "
            f"{l.sku.ljust(width_sku)}  {l.available:>12,.0f}"
        )


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--subscription", help="Azure subscription id (default: current az subscription)")
    p.add_argument("--tenant", help="Azure tenant id to authenticate against (default: caller's home tenant)")
    p.add_argument(
        "--regions",
        nargs="+",
        default=DEFAULT_REGIONS,
        help=f"Regions to query for usages (default: {' '.join(DEFAULT_REGIONS)})",
    )
    p.add_argument(
        "--models",
        nargs="+",
        default=CLAUDE_MODELS,
        help="Claude model names to query for capacity",
    )
    p.add_argument("--json", action="store_true", help="Emit raw JSON instead of tables")
    args = p.parse_args()

    sub = args.subscription or _get_current_subscription()
    token = _bearer_token(args.tenant)

    # --- 1. Usages (per region) -------------------------------------------------
    usages: list[QuotaLine] = []
    usage_errors: dict[str, str] = {}
    with ThreadPoolExecutor(max_workers=min(8, len(args.regions))) as ex:
        futures = {ex.submit(fetch_usages, sub, r, token): r for r in args.regions}
        for fut in as_completed(futures):
            region = futures[fut]
            try:
                usages.extend(fut.result())
            except Exception as e:  # noqa: BLE001
                usage_errors[region] = str(e)

    # --- 2. Model capacities (per (model, version), all regions) --------------
    # Discover (name, version) pairs from the locations/{region}/models endpoint
    # so we don't have to hard-code Anthropic's versioning scheme.
    discovered = discover_claude_versions(sub, token)
    pairs: list[tuple[str, str]] = sorted(
        ((name, ver) for name, vers in discovered.items() for ver in vers),
        key=lambda x: (x[0], x[1]),
    )
    # Constrain to models the user asked about (if they passed --models).
    if args.models != CLAUDE_MODELS:
        pairs = [(n, v) for (n, v) in pairs if n in args.models]

    capacities: list[CapacityLine] = []
    cap_errors: dict[str, str] = {}
    if pairs:
        with ThreadPoolExecutor(max_workers=min(8, len(pairs))) as ex:
            futures = {ex.submit(fetch_capacity, sub, n, v, token): (n, v) for (n, v) in pairs}
            for fut in as_completed(futures):
                key = futures[fut]
                try:
                    capacities.extend(fut.result())
                except Exception as e:  # noqa: BLE001
                    cap_errors[f"{key[0]}:{key[1]}"] = str(e)

    if args.json:
        print(
            json.dumps(
                {
                    "subscription": sub,
                    "regions": args.regions,
                    "usages": [
                        asdict(u) | {
                            "pct": u.pct,
                            "rpm_used": u.rpm_used,
                            "rpm_limit": u.rpm_limit,
                        }
                        for u in usages
                    ],
                    "usage_errors": usage_errors,
                    "capacities": [asdict(c) for c in capacities],
                    "capacity_errors": cap_errors,
                },
                indent=2,
            )
        )
        return 0

    print(f"Subscription: {sub}")
    print(f"Regions queried: {', '.join(args.regions)}")

    print("\n=== Claude quota + capacity (merged) ===")
    _print_merged(usages, capacities)
    for region, err in usage_errors.items():
        print(f"  ! usages {region}: {err}", file=sys.stderr)
    for model, err in cap_errors.items():
        print(f"  ! capacity {model}: {err}", file=sys.stderr)

    if not usages and not capacities:
        print(
            "\nNothing returned. Common reasons:"
            "\n  * The subscription is not Enterprise / MCA-E (Claude in Foundry is gated)."
            "\n  * The caller lacks 'Cognitive Services Usages Reader' at sub scope."
            "\n  * No Foundry resource has ever been created in the queried regions.",
            file=sys.stderr,
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
