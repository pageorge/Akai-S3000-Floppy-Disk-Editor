#ifndef __AKAIUTIL_H
#define __AKAIUTIL_H
/*
* Copyright (C) 2008,2010,2012,2018,2019 Klaus Michael Indlekofer. All rights reserved.
*
* m.indlekofer@gmx.de
*
* This program is free software; you can redistribute it and/or
* modify it under the terms of the GNU General Public License
* as published by the Free Software Foundation; either version 2
* of the License, or (at your option) any later version.
*
* This program is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
* GNU General Public License for more details.
*
* You should have received a copy of the GNU General Public License
* along with this program; if not, write to the Free Software
* Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
*/
/* Source: https://github.com/Midi-In/akaiutil/blob/master/akaiutil.h */



#include "akaiutil_io.h"



/* AKAI S900/S1000/S3000 filesystems */

/* Note: all data types are little endian */



/* floppy */

#define AKAI_FL_BLOCKSIZE	0x0400 /* 1KB */

#define AKAI_FLL_SIZE		0x0320 /* low-density floppy size in floppy blocks (800KB) */
#define AKAI_FLH_SIZE		0x0640 /* high-density floppy size in floppy blocks (1.6MB) */



/* harddisk */

#define AKAI_HD_BLOCKSIZE	0x2000 /* 8KB */

/* S900 harddisk */
#define AKAI_HD9_MAXSIZE	0x1fff /* max. harddisk size in harddisk blocks (approx. 64MB) */
#define AKAI_HD9_DEFSIZE	0x09c4 /* default harddisk size in harddisk blocks (approx. 19.5MB) */

/* S1000/S3000 harddisk */
#define AKAI_HD_MAXSIZE		0xffff /* max. harddisk size in harddisk blocks (approx. 512MB, Note: for 16bit block numbers) */

/* S1000/S3000 harddisk sampler partition */
#define AKAI_PART_MAXSIZE	0x1e00 /* max. partition size in harddisk blocks (60MB) */
#define AKAI_PART_NUM		18 /* max. number of sampler partitions per harddisk */

/* S1100/S3000 harddisk DD partition */
#define AKAI_DDPART_CBLKS	0x20 /* number of blocks per DD partition cluster */
#define AKAI_DDPART_NUM		18 /* max. number of DD partitions per harddisk */



/* names */

#define AKAI_NAME_LEN_S900	10 /* for S900 */
#define AKAI_NAME_LEN		12 /* for S1000/S3000 */



/* FAT (for floppies and harddisk sampler partitions) */

#define AKAI_FAT_CODE_FREE			0x0000 /* free block */
#define AKAI_FAT_CODE_SYS900FL		0x0000 /* block reserved for system (S900 floppy), warning: same as for free block!!! */
#define AKAI_FAT_CODE_SYS900HD		0xffff /* block reserved for system (S900 harddisk) */
#define AKAI_FAT_CODE_SYS			0x4000 /* block reserved for system (S1000/S3000) */
#define AKAI_FAT_CODE_DIREND900HD	0x8000 /* end of chain for volume directory (S900 harddisk) */
#define AKAI_FAT_CODE_DIREND1000HD	0x4000 /* end of chain for volume directory (S1000 harddisk), warning: same as for system block!!! */
#define AKAI_FAT_CODE_DIREND3000	0x8000 /* end of chain for volume directory (S3000) */
#define AKAI_FAT_CODE_FILEEND900	0x8000 /* end of chain for file (S900) */
#define AKAI_FAT_CODE_FILEEND		0xc000 /* end of chain for file (S1000/S3000) */



/* DD FAT (for S1100/S3000 harddisk DD partition) */

#define AKAI_DDFAT_CODE_FREE		0x0000 /* free cluster */
#define AKAI_DDFAT_CODE_SYS			0x8000 /* cluster reserved for system (header cluster) */
#define AKAI_DDFAT_CODE_END			0xffff /* end of chain */



/* OS versions for volumes and files */

#define AKAI_OSVER_S900VOL		0x0000 /* OS version of S900/S950 volume (zero) */
#define AKAI_OSVER_S1000MAX		0x0428 /* max. OS version of S1000 ("4.40") */
#define AKAI_OSVER_S1100MAX		0x091e /* max. OS version of S1100 ("9.30") */
#define AKAI_OSVER_S3000MAX		0x1100 /* max. OS version of S3000 ("17.00") */



/* file */

#define AKAI_FILE_SIZEMAX	0xffffff /* max. file size in bytes (approx. 16MB, Note: for 24bit size in volume directory entry for file) */

/* entry in volume directory for file */
struct akai_voldir_entry_s{
	/* Note: S900 uses first AKAI_NAME_LEN900 chars in name, rest is zero */
	u_char name[AKAI_NAME_LEN]; /* file name */
#define AKAI_FILE_TAGNUM	0x04 /* number of tags in volume directory entry for file */
#define AKAI_FILE_TAGFREE	0x00 /* invalid tag number, means: free tag entry for S3000 */
#define AKAI_FILE_TAGS1000	0x20 /* invalid tag number, default for S1000 */
	/* Note: valid tag numbers are 1, ..., AKAI_PARTHEAD_TAGNUM */
	/* Note: S900 has no tags, all zero */
	u_char tag[AKAI_FILE_TAGNUM]; /* tags */
#define AKAI_FTYPE_FREE		0x00 /* invalid file type, means: free entry in volume directory */
	u_char type; /* file type */
	u_char size[3]; /* file size in bytes (Note: 24bit) */
	u_char start[2]; /* start block within partition */
	u_char osver[2]; /* if S1000/S3000: OS version */
				 /* if S900 compressed file: number of un-compressed floppy blocks */
				 /* else: zero */
}; /* Note: should be 0x0018 Bytes */



/* volume parameters */
/* Note: S900 has no volume parameters */
struct akai_volparam_s{
	u_char dummy1[0x0030]; /* XXX */
}; /* Note: should be 0x0030 Bytes */



/* harddisk volumes */

/* harddisk volume directory of files */
#define AKAI_VOLDIR_ENTRIES_S900HD		128 /* total number of volume directory entries for S900 */
#define AKAI_VOLDIR_ENTRIES_S1000HD		126 /* total number of volume directory entries for S1000 */
#define AKAI_VOLDIR_ENTRIES_S3000HD		510 /* total number of volume directory entries for S3000 */
#define AKAI_VOLDIR_ENTRIES_1BLKHD		341 /* max. number of volume directory entries in 1 harddisk block */

/* floppy volume directory of files */
#define AKAI_VOLDIR_ENTRIES_S1000FL		64  /* number of volume directory entries total for S900 and S1000 floppy */
#define AKAI_VOLDIR_ENTRIES_S3000FL		510 /* number of volume directory entries total for S3000 floppy */

/* floppy volume label */
/* Note: S900 has no floppy volume label, all zero */
struct akai_flvol_label_s{
	u_char name[AKAI_NAME_LEN]; /* volume name */
	u_char dummy1[2]; /* XXX */
	u_char osver[2]; /* OS version */
	struct akai_volparam_s param; /* volume parameters */
}; /* Note: should be 0x0040 Bytes */

/* high-density floppy header */
struct akai_flhhead_s{
	struct akai_voldir_entry_s file[AKAI_VOLDIR_ENTRIES_S1000FL]; /* volume directory entries for files */
#define AKAI_FAT_ENTRIES_FLH	AKAI_FLH_SIZE /* number of FAT entries */
	u_char fatblk[AKAI_FAT_ENTRIES_FLH][2]; /* FAT entries for floppy blocks: next block or special code */
	struct akai_flvol_label_s label; /* label */
	u_char dummy1[0x0140]; /* XXX */
}; /* Note: should be 5 floppy blocks */
#define AKAI_FLHHEAD_BLKS	5

/* S3000 floppy volume directory (behind header) */
struct akai_voldir3000fl_s{
	struct akai_voldir_entry_s file[AKAI_VOLDIR_ENTRIES_S3000FL]; /* volume directory entries for files */
	u_char dummy1[0x0030]; /* Note: volume parameters are in floppy header */
}; /* Note: should be 12 floppy blocks */
#define AKAI_VOLDIR3000FL_BLKS		12
#define AKAI_VOLDIR3000FLL_BSTART	4 /* start block for low-density */
#define AKAI_VOLDIR3000FLH_BSTART	5 /* start block for high-density */
/* flag for S3000 floppy: invalid type of first file in floppy header */
#define AKAI_VOLDIR3000FL_FTYPE		0xff /* invalid file type, used as flag for S3000 floppy volume */



#endif /* !__AKAIUTIL_H */
