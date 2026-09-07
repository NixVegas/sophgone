#!/usr/bin/env python3
# Source-of-truth generator for sophgone-map.json (hex-authored so the values are
# auditable; JSON can't hold hex or comments). Addresses come from RE; see
# sophgone-offset-map.md. Run: python3 sophgone-map.gen.py > sophgone-map.json
import json

MAP = {
  # A53 aarch64 (runtime base 0x40000000)
  "a53": {
    "rom_base": 0x40000000,
    "bl2_base": 0x40100000,          # phys 0x0C000000
    "stack_ceiling": 0x4013E540,
    "bl2_total": 0x3E400,
    "spare_window": 0x40130000,      # relocate target (below the ROM globals, above sophg.1 BL2)
    "polyglot_word_off": 0x20,       # 0x1400006F lands here (launch_bl2 br 0x40100020)
    "rv_stub_off": 0x160,            # word `j 320`
    "aa_stub_off": 0x1DC,            # word `b #444`
    "aa_body_off": 0x20000,          # in-place aa body, above any real FSBL (< 128 KB); no self-relocate
    "rv_body_off": 0x28000,          # rv body placement (distinct, also above the FSBL)
    # full read-cluster (v13-proven WIN coverage); the polyglot variant drops 0x3E308 for the C906
    "hijack": [[s, "launch"] for s in (
        0x3E178, 0x3E1B8, 0x3E1C8, 0x3E208, 0x3E258, 0x3E288, 0x3E2A8, 0x3E2B8, 0x3E2C0,
        0x3E2D8, 0x3E2F8, 0x3E308, 0x3E318, 0x3E328, 0x3E338, 0x3E348, 0x3E350, 0x3E368, 0x3E388)],
    "islands": [[0x3C200, 0x04310000]],  # g_sdhci_base value: keep the SDHCI poll alive
                                         # through the DMA (v11 hung without it)
    "fill_value": 0x4013F000,        # writable SRAM (v13-proven); DMA-deref-safe
    "fill_value_alias": 0x0C03F000,  # shared-physical low alias (C906-safe fallback for the unified blob)
    "syms": {
      "f_open": 0x4000EF04,          # x0=FIL* x1=path x2=mode -> w0=FRESULT
      "f_read": 0x4000F33C,          # x0=FIL* x1=buf w2=len x3=&br -> w0=FRESULT
      "f_lseek": 0x4000F52C,         # x0=FIL* x1=offset
      "f_mount": 0x4000EE90,         # x0=FATFS* x1="0:" w2=1
      "load_image": 0x4000197C,      # x0=dst w1=off w2=size w3=media_hi (raw media read; FatFs path preferred)
      "fip_parse": 0x4000DB00,       # header-load: load_image(fip_param,0,size,media) reproduces the parse
      "launch_or_entry": 0x4000E020, # launch_bl2: ic iallu; br 0x40100020  (hijack "launch" value + relaunch)
      "bl2_entry": 0x40100020,       # where launch_bl2 lands (= polyglot word offset)
      "flush_dcache": 0x400107A0,    # dc civac loop + dsb
      "inv_icache": 0x400010A0,      # ic iallu; isb
      "sd_load": 0x40005984,
      "read_wrapper": 0x400058F8,    # f_lseek + f_read helper
      "sd_open_fip": 0x40005864,
      "fip_param": 0x40139000,       # +0xC4 bl2_off, +0xD8 bl2_img_size (survives, below window)
      "sd_ops": 0x4013F058,          # ptr to live SD ops (survives, above window)
      "sd_ctx": 0x4013F054,
      "fatfs_default": 0x4013EBA8,   # mounted volume (survives) -> no re-mount needed
      "fil_default": 0x4013EDF0,   # load_image's SD-FAT arm f_lseek+f_read's this FIL (0x400058F8)
      "uart_base": 0x04140000,
      "printf": 0x400011FC,          # the ROM printf the stubs narrate through
    },
    "abi": {
      "f_open": "x0=FIL* x1=path x2=mode(byte) -> w0=FRESULT (0==FR_OK)",
      "f_read": "x0=FIL* x1=buf w2=len x3=&bytes_read -> w0=FRESULT",
      "f_lseek": "x0=FIL* x1=offset -> w0=FRESULT",
      "load_image": "x0=dst w1=offset w2=size w3=media_hi -> w0=FRESULT; dispatch on media_id @0x4013E580",
    },
  },
  # C906 rv64 (runtime base 0x04418000)
  "c906": {
    "rom_base": 0x04418000,
    "bl2_base": 0x0C000000,
    "stack_ceiling": 0x0C03E540,
    "bl2_total": 0x3E400,
    "spare_window": 0x0C030000,
    "polyglot_word_off": 0x20,
    "rv_stub_off": 0x160,
    "aa_stub_off": 0x1DC,
    "aa_body_off": 0x20000,          # aa body placement (schema symmetry)
    "rv_body_off": 0x28000,          # in-place rv body, above any real FSBL (< 128 KB)
    "hijack": [[0x3E308, "word"]],   # single disk_read saved-ra -> polyglot word (bl2_base+0x20)
    "islands": [[0x3C230, 0x04310000], [0x3C200, 0x04300000]],
    "fill_value": 0x0C000100,        # C906-valid SRAM (romexec-proven) for the C906-solo blob
    "disk_read_ra_off": 0x3E308,
    "island_note": "SD/eMMC driver context base pointers, both smashed by the overflow and both read on the boot path before storage_init (0x0441C1C6) can re-enumerate: [0x3C230, 0x04310000]=SD host base *(0x0C03C230), [0x3C200, 0x04300000]=eMMC host base *(0x0C03C200). ROM never rewrites +0 (static .data), so we must.",
    "launch_convention": "self-modifying-code: dcache_clean(0x04418258) + icache_flush(0x04418240) after any CPU code write (self-relocate, sophg.1 load), then jr; the ROM flushes its own BL2 load but not ours",
    "syms": {
      "f_open": 0x044237AA,          # a0=FIL* a1=path a2=mode -> a0=FRESULT
      "f_read": 0x04423ACA,          # a0=FIL* a1=buf a2=len a3=&br -> a0=FRESULT
      "f_lseek": None,               # not needed; sophgone-rv.S uses sequential reads
      "storage_init": 0x044181C6,
      "storage_drain": 0x044183A6,   # uart TX drain (flush the banner before the jr)
      "load_image": 0x044188C0,      # a0=dst a1=off a2=size a3=dev-index (raw media; FatFs path preferred)
      "fip_parse": 0x04422836,       # fip_load_bl2: DMAs CVBL01 header to 0x0C039000
      "launch_or_entry": 0x0C000020, # jr target (bl2_entry)
      "icache_flush": 0x04418240,    # ROM th.icache.iall + th.sync.i (leaf)
      "dcache_clean": 0x04418258,    # ROM dcache_clean_range(a0=start, a1=size): th.dcache.cva loop + th.sync.s (leaf)
      "fip_param": 0x0C039000,       # survives (below window)
      "sd_ops": 0x0C03F020,          # live SD ops ctx (survives, above stack ceiling)
      "fatfs_default": 0x0C03F3F0,   # mounted volume (survives) -> no re-mount needed
      "read_wrapper": 0x0441BFC8,    # load_image's SD-FAT arm: f_lseek + f_read on fil_default
      "fil_default": 0x0C03EDB0,     # the FIL read_wrapper uses; whatever is f_open'd here is
                                     #   what the launched FSBL's load_image reads (above the
                                     #   0x0C03E540 stack ceiling, so the overflow leaves it intact)
      "uart_base": 0x04140000,
      "printf": 0x0441843C,          # the ROM printf the stubs narrate through
    },
    "abi": {
      "f_open": "a0=FIL* a1=path a2=mode -> a0=FRESULT (0==FR_OK)",
      "f_read": "a0=FIL* a1=buf a2=len a3=&bytes_read -> a0=FRESULT",
      "load_image": "a0=dst a1=offset a2=size a3=dev-index -> a0=FRESULT; media type from global @0x0C03E540",
    },
  },
}

print(json.dumps(MAP, indent=2))
