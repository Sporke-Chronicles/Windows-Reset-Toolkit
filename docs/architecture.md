# Architecture

## Three workflows, shared principles

The project uses a common set of design principles:

- Reassess real state on every run rather than trusting a prior status flag.
- Stage a known WinRE image before destructive partition work.
- Shrink C: only by the additional capacity currently required.
- Reuse partial previous work where safe.
- Validate active third-party storage-driver coverage inside WinRE.
- Treat BitLocker changes as short-lived, scoped operations.
- Validate the RemoteWipe provider before changing BitLocker for a wipe.
- Fail closed on ambiguous storage states.

## Intune readiness

```mermaid
flowchart TD
    A[Intune Detection as SYSTEM] --> B[Assess ReAgent/Recovery/WIM]
    B --> C[Mount WinRE + DISM CheckHealth]
    C --> D[Compare active storage drivers]
    D --> E[Validate MDM RemoteWipe control surface]
    E --> F{Ready?}
    F -- Yes --> G[Exit 0 / H000]
    F -- No --> H[Exit 1]
    H --> I[Intune Remediation]
    I --> J[Repair registration/partition/drivers/component health]
    J --> K[Final non-wipe validation]
```

## ConfigMgr carve-out

```mermaid
flowchart TD
    A[Resolve safe temporary letter] --> B[Repair/rebuild WinRE]
    B --> C[Validate/inject storage drivers]
    C --> D[RemoteWipe preflight]
    D --> E[BitLocker suspension for wipe]
    E --> F[MDM_RemoteWipe doWipeMethod]
    F --> G[Windows Reset / OOBE]
```

## Intune carve-out reset

The dependent repair and destructive steps remain in one remediation script because independently scheduled Remediations packages do not provide a reliable cross-package execution order.

```mermaid
flowchart TD
    A[Assigned endpoint] --> B{Valid Arm marker?}
    B -- No --> C[Detection exit 0 / do nothing]
    B -- Yes --> D[Detection exit 1]
    D --> E[Remediation as SYSTEM]
    E --> F[Authorization validation]
    F --> G[WinRE repair/readiness]
    G --> H[Storage-driver readiness]
    H --> I[Final RemoteWipe provider preflight]
    I --> J{Authorization still valid?}
    J -- No --> K[Fail closed]
    J -- Yes --> L[BitLocker suspension]
    L --> M[doWipeMethod]
    M --> N[Windows Reset]
```
