# akai-fs

Source: https://github.com/dialtr/akai-fs
Archived: September 2026 by AkaiS3000Editor project
Author: Tom Dial <thomas.r.dial@gmail.com>
License: GPL-2.0

## About

A FUSE filesystem to allow users to mount disks using proprietary Akai
sampler formats. Builds upon akaiutils by Michael Indlekofer.

akai-fs does not define its own format structures — it wraps the akaiutil
structs. Useful as a reference for how the format is accessed at the OS level.

## What we used from this project

- Confirmation of file type bytes (0xf0=S3000 program, 0xf3=S3000 sample, 0xed=multi)
- FAT structure and volume directory layout
- S3000 vs S1000 format differences
- Starting point for understanding how to navigate the disk image

## Project structure

- archive/         original akaiutil snapshot
- akaifs/          FUSE daemon
- akaiutil/        refactored library
- include/akaiutil header files

## Acknowledgements (from akai-fs README)

Stands on the shoulders of reverse engineering work by Michael Indlekofer,
the author of akaiutils.
