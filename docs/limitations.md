# Limitations

- The project cannot guarantee that a future Intune command will be delivered. Network, enrollment, service health, and endpoint availability remain external dependencies.
- Automated destructive Recovery-partition repair is intentionally conservative and primarily targets GPT/UEFI Windows client layouts.
- Windows Server is not a supported target.
- The reference Hyper-V/Intune validation proves the inbox-storage path; it does **not** prove positive third-party Intel RST/VMD, AMD RAID, or vendor storage-driver injection on physical hardware.
- Storage-driver matching intentionally prefers exact active package coverage. A different compatible driver might work technically but is not treated as equivalent by the conservative readiness model.
- The 2536 MB Recovery target is an operational default, not a universal Microsoft requirement. Existing smaller partitions can still be healthy when configured thresholds and free-space reserve are satisfied.
- `Ready=True` is a point-in-time local readiness result, not a guarantee that hardware or configuration will remain unchanged.
- Protected wipe is not a general migration default and requires separate risk acceptance/testing.
- Unusual multi-disk, OEM, dynamic-disk, MBR, or manually customized Recovery layouts may require manual engineering review.
- Windows 11 and representative OEM device families were not part of the v1.0.0 reference VM validation; pilot them before broad deployment.
- A successful RemoteWipe can transition into Windows Reset before final local remediation log lines are retrievable. Reset progression/completion is the authoritative destructive-path outcome.
