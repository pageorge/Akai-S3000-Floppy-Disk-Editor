/*
 * akaiutil_file.h - AKAI S900/S1000/S3000 file format structures
 * Copyright (C) 2010,2012,2018,2019 Klaus Michael Indlekofer. All rights reserved.
 *
 * Source: https://github.com/Midi-In/akaiutil/blob/master/akaiutil_file.h
 * Archived: September 2026 by AkaiS3000Editor project
 * GPL-2.0 License
 */

/* AKAI file type identifiers */
#define AKAI_SAMPLE3000_FTYPE  ('s'+0x80)  /* 0xf3 */
#define AKAI_PROGRAM3000_FTYPE ('p'+0x80)  /* 0xf0 */
#define AKAI_MULTI3000_FTYPE   ('m'+0x80)  /* 0xed */
#define AKAI_DRUMFILE_FTYPE    'd'          /* drum inputs */
#define AKAI_FXFILE_FTYPE      'x'          /* effects */
#define AKAI_TLFILE_FTYPE      't'          /* take-list/song */

/* AKAI S1000 sample loop parameters */
struct akai_sample1000loop_s {
    u_char at[4];    /* loop at marker */
    u_char flen[2];  /* loop fine length in 1/65536 sample */
    u_char len[4];   /* loop length in samples */
#define SAMPLE1000LOOP_TIME_NOLOOP 0
#define SAMPLE1000LOOP_TIME_HOLD   9999
    u_char time[2];  /* loop time in msec */
};

/* AKAI S1000/S3000 sample header */
struct akai_sample1000_s {
#define SAMPLE1000_BLOCKID 0x03
    u_char blockid;
#define SAMPLE1000_BANDW_10KHZ 0x00
#define SAMPLE1000_BANDW_20KHZ 0x01
    u_char bandw;    /* bandwidth */
    u_char rkey;     /* MIDI root key */
    u_char name[AKAI_NAME_LEN];
    u_char dummy1;   /* 0x80 */
    u_char lnum;     /* number of loops */
    u_char lfirst;   /* first active loop-1 */
    u_char dummy2;
#define SAMPLE1000_PMODE_LOOP       0x00
#define SAMPLE1000_PMODE_LOOPNOTREL 0x01
#define SAMPLE1000_PMODE_NOLOOP     0x02
#define SAMPLE1000_PMODE_TOEND      0x03
    u_char pmode;
    u_char ctune;    /* cents tune (signed) */
    u_char stune;    /* semitone tune (signed) */
    u_char locat[4]; /* absolute address (sampler-managed) */
    u_char slen[4];  /* number of samples */
    u_char start[4]; /* start marker */
    u_char end[4];   /* end marker */
#define AKAI_SAMPLE1000_LOOPNUM 8
    struct akai_sample1000loop_s loop[AKAI_SAMPLE1000_LOOPNUM];
    u_char dummy3[2];
#define AKAI_SAMPLE1000_STPAIRA_NONE 0xffff
    u_char stpaira[2]; /* stereo partner address (sampler-managed) */
    u_char srate[2];   /* sample rate in Hz */
    u_char hltoff;     /* HOLD loop tune offset */
    u_char dummy4[9];
}; /* 0x0096 bytes */

/* S3000 adds 42 padding bytes = 0x00c0 total */
struct akai_sample3000_s {
    struct akai_sample1000_s s1000;
    u_char dummy1[42];
}; /* 0x00c0 bytes */

/* AKAI S1000 program header */
struct akai_program1000_s {
#define PROGRAM1000_BLOCKID 0x01
    u_char blockid;
    u_char kg1a[2];  /* 1st keygroup address (sampler-managed) */
    u_char name[AKAI_NAME_LEN];
    u_char dummy1;
#define PROGRAM1000_MIDICH1_OMNI 0xff
    u_char midich1;  /* MIDI channel */
    u_char dummy2[2];
    u_char keylo;    /* low MIDI key */
    u_char keyhi;    /* high MIDI key */
    u_char oct;      /* octave offset (signed) */
#define PROGRAM1000_AUXCH1_OFF 0xff
    u_char auxch1;
    u_char dummy3[18];
    u_char kgxf;     /* keygroup crossfade enable */
    u_char kgnum;    /* number of keygroups */
    u_char dummy4[107];
}; /* 0x0096 bytes */

/* S3000 adds 42 padding bytes = 0x00c0 total */
struct akai_program3000_s {
    struct akai_program1000_s s1000;
    u_char dummy1[42];
}; /* 0x00c0 bytes */

/* AKAI S1000 velocity zone (0x18 bytes) */
struct akai_program1000kgvelzone_s {
    u_char sname[AKAI_NAME_LEN]; /* sample name */
    u_char vello;    /* low MIDI velocity */
    u_char velhi;    /* high MIDI velocity */
    u_char ctune;    /* cents tune (signed) */
    u_char stune;    /* semitone tune (signed) */
    u_char loud;     /* loudness offset (signed) */
    u_char filter;   /* filter offset (signed) */
    u_char pan;      /* pan offset (signed) */
#define PROGRAM1000_PMODE_SAMPLE    0x00
#define PROGRAM1000_PMODE_LOOP      0x01
#define PROGRAM1000_PMODE_LOOPNOTREL 0x02
#define PROGRAM1000_PMODE_NOLOOP    0x03
#define PROGRAM1000_PMODE_TOEND     0x04
    u_char pmode;
    u_char dummy1[2];
#define PROGRAM1000KG_SHDRA_NONE 0xffff
    u_char shdra[2]; /* sample header address (sampler-managed) */
}; /* 0x0018 bytes */

/* AKAI S1000 keygroup */
struct akai_program1000kg_s {
#define PROGRAM1000KG_BLOCKID 0x02
    u_char blockid;
    u_char kgnexta[2]; /* next keygroup address (sampler-managed) */
    u_char keylo;      /* low MIDI key */
    u_char keyhi;      /* high MIDI key */
    u_char ctune;      /* cents tune (signed) */
    u_char stune;      /* semitone tune (signed) */
    u_char filter;
    u_char dummy1[22];
    u_char velxf;      /* velocity crossfade enable */
    u_char dummy2[3];
#define PROGRAM1000KG_VELZONENUM 4
    struct akai_program1000kgvelzone_s velzone[PROGRAM1000KG_VELZONENUM];
    u_char dummy3[2];
    u_char pconst[PROGRAM1000KG_VELZONENUM];   /* constant pitch per zone */
    u_char auxchoff[PROGRAM1000KG_VELZONENUM]; /* aux output channel offsets */
    u_char dummy4[10];
}; /* 0x0096 bytes */

/* S3000 keygroup adds 42 padding bytes = 0x00c0 total */
struct akai_program3000kg_s {
    struct akai_program1000kg_s s1000;
    u_char dummy1[42];
}; /* 0x00c0 bytes */
