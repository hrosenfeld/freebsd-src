bhyve VGA BIOS support
----------------------

This is based on the work that was originally done by Henryk Gulbrandsen (https://www.gulbra.net/freebsd-bhyve).

I have adapted this to work on top of two other changes that are currently under review, which will allow VGA passthru with Intel and AMD hardware:

* https://reviews.freebsd.org/D26209
* https://reviews.freebsd.org/D27456

I've had to make some improvements to the VGA BIOS itself, as it had a tendency to show me a BSOD instead of failing gracefully if a call was made it didn't support. Even GRUB vbetest seems to work now.

A few more changes were necessary to bhyve itself and the UEFI-CSM firmware. Early during initialization the firmware tries to enumerate all PCI options ROMs to copy them into RAM, and this failed due to the way the firmware guesses the base and size of the PCI memory window. It actually ends up mapping the ROM at the same address as the framebuffer, which fails in interesting ways.

Things that still need improvement:
* bhyve should provide the base and size of the PCI memory window in the physical address space. Some hardware provides a MSR for this, perhaps bhyve should emulate that? And of course, the UEFI-CSM firmware needs to use that.
* UEFI-CSM should be smarter about mapping the BIOS and the framebuffer at the same time, but not at the same addresses
* the VGA BIOS should never BSOD but always handle requests gracefully, indicating that features are unsupported when necessary

This work is spread across three repositories:
* FreeBSD / bhyve: https://github.com/hrosenfeld/freebsd-src/
* UEFI-CSM: https://github.com/hrosenfeld/uefi-edk2/
* FreeBSD ports: https://github.com/hrosenfeld/freebsd-ports

FreeBSD Source:
---------------
This is the top level of the FreeBSD source directory.

FreeBSD is an operating system used to power modern servers, desktops, and embedded platforms.
A large community has continually developed it for more than thirty years.
Its advanced networking, security, and storage features have made FreeBSD the platform of choice for many of the busiest web sites and most pervasive embedded networking and storage devices.

For copyright information, please see [the file COPYRIGHT](COPYRIGHT) in this directory.
Additional copyright information also exists for some sources in this tree - please see the specific source directories for more information.

The Makefile in this directory supports a number of targets for building components (or all) of the FreeBSD source tree.
See build(7), config(8), [FreeBSD handbook on building userland](https://docs.freebsd.org/en/books/handbook/cutting-edge/#makeworld), and [Handbook for kernels](https://docs.freebsd.org/en/books/handbook/kernelconfig/) for more information, including setting make(1) variables.

Source Roadmap:
---------------
| Directory | Description |
| --------- | ----------- |
| bin | System/user commands. |
| cddl | Various commands and libraries under the Common Development and Distribution License. |
| contrib | Packages contributed by 3rd parties. |
| crypto | Cryptography stuff (see [crypto/README](crypto/README)). |
| etc | Template files for /etc. |
| gnu | Various commands and libraries under the GNU Public License. Please see [gnu/COPYING](gnu/COPYING) and [gnu/COPYING.LIB](gnu/COPYING.LIB) for more information. |
| include | System include files. |
| kerberos5 | Kerberos5 (Heimdal) package. |
| lib | System libraries. |
| libexec | System daemons. |
| release | Release building Makefile & associated tools. |
| rescue | Build system for statically linked /rescue utilities. |
| sbin | System commands. |
| secure | Cryptographic libraries and commands. |
| share | Shared resources. |
| stand | Boot loader sources. |
| sys | Kernel sources. |
| sys/`arch`/conf | Kernel configuration files. GENERIC is the configuration used in release builds. NOTES contains documentation of all possible entries. |
| tests | Regression tests which can be run by Kyua.  See [tests/README](tests/README) for additional information. |
| tools | Utilities for regression testing and miscellaneous tasks. |
| usr.bin | User commands. |
| usr.sbin | System administration commands. |

For information on synchronizing your source tree with one or more of the FreeBSD Project's development branches, please see [FreeBSD Handbook](https://docs.freebsd.org/en/books/handbook/cutting-edge/#current-stable).
