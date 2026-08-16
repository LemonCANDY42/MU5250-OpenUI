# Upstream provenance and publication notice

This public fork is an owner-operated integration of two MIT-licensed U60 Pro
projects. It targets one ZTE MU5250 on HK B04 firmware while keeping the API
and recovery boundaries useful to other owners.

## Provenance

- Git history and the current `LICENSE` originate from
  `dklasens/MU5250-OpenUI`. David Klasens added the MIT licence on 2026-08-16.
- Selected iOS presentation code from `jesther-ai/open-u60-pro` retains its MIT
  notice at `clients/ios/LICENSE.open-u60-pro`.
- The current clients use the versioned B04 API and do not merge the two legacy
  device agents or expose either project's generic command surfaces.

Changes may be reused under the retained MIT terms. Imports must retain their
author, licence and source attribution.

## Secret boundary

Repository history must never contain real device identifiers, backup-key
material, passwords, authentication tokens, DNS tokens, private keys, device
backups or exported device configuration. Local deployment and recovery secrets
belong only in approved machine key stores and encrypted backup locations.
