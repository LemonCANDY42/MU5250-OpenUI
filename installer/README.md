# Legacy installer is disabled

The upstream Tkinter installer and its deployment backend are retained only for
provenance and research. On this V1 branch both entry points exit before
importing deployment code or contacting a device.

They are deliberately not a supported way to unlock, install, update or harden
an HK B04 unit. The historical workflow combined recovery access, arbitrary
deployment, SSH changes, dashboard installation and boot persistence without
the per-operation backup and rollback gates required by this branch.

Use the staged, content-addressed workflow documented in
[`docs/DEPLOYMENT.md`](../docs/DEPLOYMENT.md). Until that document records a
completed real-device gate, keep the agent as a manually started canary and
preserve root ADB.

`scripts/check-device-gates.py` verifies that the installer remains
fail-closed. Re-enabling it would be a new security-sensitive product decision,
not a packaging change.
