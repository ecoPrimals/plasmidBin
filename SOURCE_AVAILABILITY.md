<!--
SPDX-License-Identifier: AGPL-3.0-or-later
Documentation: CC-BY-SA-4.0
-->

# Source Availability Notice

All primal binaries distributed through this repository are licensed under
**AGPL-3.0-or-later**.

## Your rights under AGPL

The GNU Affero General Public License requires that the **corresponding
source code** be made available when binaries are distributed. You have the
right to receive the complete source code for any binary published here.

## How to obtain source

1. **Check `metadata.toml`**: each primal directory contains a
   `metadata.toml` with a `[provenance] built_from` field indicating which
   source tree produced the binary.

2. **Published repositories**: primal source repositories are being
   published progressively. When a primal's source repository is public,
   the `built_from` field links directly to it.

3. **Request source**: if a primal's source repository is not yet public,
   you may request the corresponding source by opening an issue on this
   repository or contacting the maintainers. Source will be provided within
   a reasonable timeframe as required by the AGPL.

## Provenance

Each `metadata.toml` records:

- **`built_from`**: the source tree that produced this binary
- **`built_at`**: when the binary was built
- **`checksum_sha256`**: integrity verification hash
- **`version`**: the primal's semantic version

These fields constitute a provenance chain from binary back to source,
consistent with the ecoPrimals ecosystem's provenance trio architecture
(rhizoCrypt, loamSpine, sweetGrass).

## License text

The full AGPL-3.0-or-later license text is available at:
https://www.gnu.org/licenses/agpl-3.0.html

Individual primal binaries may carry additional license metadata (e.g.
CC-BY-SA-4.0 for documentation, ORC for creative content) as noted in
their respective `metadata.toml` files.
