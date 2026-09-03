# AArch64 runtime convergence

## Goal

The AArch64 distribution should use the official Omarchy source without maintaining a separate desktop product. `omarchy-pkgs-aarch64` remains responsible for native package construction and signed channel repositories, while `omarchy-aarch64-image` remains responsible for the virtual-machine image, boot stack, and first-boot integration.

The source fork is temporary. It must not carry AArch64-specific menu content, shell layout, appearance, or keybindings.

## Current ownership

| Concern | Long-term owner | Current state |
| --- | --- | --- |
| Native AArch64 PKGBUILDs and payload audits | Package repository | Implemented independently of the source fork. |
| Signed stable, RC, and edge repositories | Package repository | Implemented as isolated GitHub Releases. |
| VM kernel, UKI/Limine, guest services, disk layout, and first boot | Image repository | Implemented by the `aarch64-virt` image profile. |
| Packages deliberately omitted or renamed by the image | Image and package-policy manifests | The image writes the installed-machine manifests; `omarchy-aarch64-config` updates the reinstall exclusion and replacement lists. |
| Menu, shell layout, and Hyprland keybindings | Official Omarchy | No downstream override is shipped. Unsupported actions remain visible or hide through upstream's own runtime guards. |
| Package-channel selection and source checkout | Official Omarchy with a generic external-channel interface | Still carried by the temporary source compatibility fork. |

`omarchy-aarch64-config` is intentionally narrow. It distributes package-selection policy only and must not install a menu overlay, alter `shell.json`, or inject Hyprland configuration.

The maintained VM policy currently excludes only `gpu-screen-recorder`, `obs-studio`, and `qemu-user-static-binfmt`. Other previously omitted upstream defaults have native AArch64 packages and are no longer excluded merely to reduce image size.

## Remaining source compatibility

The remaining source changes fall into three groups.

### Suitable for small upstream changes

- Select the bundled Node archive from the machine architecture instead of assuming `linux-x64` during offline setup.
- Let an externally supplied, root-owned channel definition select repository URLs and the development source checkout while preserving the existing stable/RC/edge/dev user interface.
- Let externally supplied package manifests exclude unavailable defaults and map requested package names to architecture-appropriate providers during reinstall.
- Treat optional services and commands as optional when the selected installation profile does not install them.

These capabilities are architecture-neutral. They are useful to official installation profiles and downstream images without embedding this fork's repository URL or package names upstream.

### Image-owned after the upstream interface exists

- Arch Linux ARM pacman templates and keyring initialization.
- The signed AArch64 repository URL map and refresh hook.
- Generic-VM hardware selection and guest-agent enablement.
- The packages omitted for image size, unavailable hardware, or unvalidated vendor binaries.
- AArch64 kernel, initramfs, UKI/Limine, disk, and firmware setup.

### Transitional only

- Migrations from the legacy `releases/latest/download` endpoint and the old `aarch64-quattro` branch name.
- Pins from `omarchy`, `omarchy-settings`, `omarchy-dev`, and `omarchy-settings-dev` to the compatibility source.
- The compatibility branches and `-aarch64.N` source tags.

Transitional code must remain until a published update has migrated existing installations. Removing it from a new image alone is insufficient.

## Channel contract

The four user choices keep the upstream meaning:

- `stable` installs the stable runtime packages from the AArch64 stable repository.
- `rc` installs the stable runtime package names from the AArch64 RC repository.
- `edge` installs `omarchy-dev` and `omarchy-settings-dev` from the AArch64 edge repository.
- `dev` uses the same edge packages and links a writable source checkout.

There are three binary repositories, not four. Eliminating the source fork requires the official development branch to work on AArch64 because `dev` executes the checked-out source directly.

## Migration sequence

1. Keep the current fork packages available while the generic upstream changes are reviewed.
2. Package a reviewed official stable commit and official development branch in a non-stable AArch64 repository.
3. Run the source tests and package adapter tests locally, then build and recursively audit the affected packages on native AArch64 Docker without QEMU or binfmt emulation.
4. Exercise stable, RC, edge, and dev transitions in a disposable AArch64 image, including returning from dev to every packaged channel.
5. Publish a migration release that changes the development source URL only after the official branch passes those tests. Preserve administrator-defined source URLs and branches.
6. Advance the same verified package state through RC to stable. Do not point stable users at a moving source branch.
7. Keep the compatibility repository read-only for at least one migration cycle, then archive it after supported installations no longer reference it.

## Exit criteria

The source fork can be archived only when all of the following are true:

- The package recipes for both stable and development variants consume official Omarchy commits or branches.
- `omarchy refresh pacman` preserves Arch Linux ARM repositories and selects the requested signed AArch64 channel without fork-specific source code.
- `omarchy channel set` completes stable, RC, edge, and dev transitions, and dev clones official source.
- `omarchy reinstall pkgs` does not request packages excluded or owned by the image.
- Offline first-boot provisioning selects an ARM64 Node archive.
- A fresh image and an upgraded existing installation both pass the same checks.
- No released configuration or migration still references `riverscn/omarchy-aarch64` or `aarch64-quattro`.

Until every condition is met, the source fork should be described as a compatibility layer rather than removed or allowed to accumulate product differences.
