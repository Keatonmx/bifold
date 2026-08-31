#!/usr/bin/env python3
"""Generates Tests/bifold-test.nds — a tiny homebrew DS ROM for CI smoke tests.

    python Scripts/gen_test_rom.py

The ARM9 program puts engine A into VRAM-display mode and refills the
framebuffer forever with a colour gradient that shifts every pass, so the
top screen animates (two screenshots taken seconds apart must differ).
Engine B shows a teal backdrop on the touch screen. The ARM7 just parks.

melonDS treats a cart as homebrew when the game code is "####"; direct boot
copies the ARM9/ARM7 binaries to their RAM addresses and jumps to the entry
points with both display engines already powered (POWCNT 0x820F).

Hand-assembled ARMv5 via the mini encoder below — no toolchain needed.
"""
import os
import struct

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'Tests', 'bifold-test.nds')

# ---------------------------------------------------------------- assembler

COND_AL = 0xE0000000


def imm_operand(value):
    """ARM data-processing immediate: 8 bits rotated right by an even amount."""
    for rot in range(0, 32, 2):
        imm8 = ((value << rot) | (value >> (32 - rot))) & 0xFFFFFFFF
        if imm8 < 256:
            return (rot // 2) << 8 | imm8
    raise ValueError(f'immediate 0x{value:X} is not encodable')


def mov(rd, value):
    return COND_AL | 0x03A00000 | (rd << 12) | imm_operand(value)


def mov_reg(rd, rm):
    return COND_AL | 0x01A00000 | (rd << 12) | rm


def add(rd, rn, value):
    return COND_AL | 0x02800000 | (rn << 16) | (rd << 12) | imm_operand(value)


def subs(rd, rn, value):
    return COND_AL | 0x02500000 | (rn << 16) | (rd << 12) | imm_operand(value)


def str_word(rd, rn, offset=0, post_increment=None):
    if post_increment is not None:
        # STR Rd, [Rn], #inc  (post-indexed, writeback implied)
        return COND_AL | 0x04800000 | (rn << 16) | (rd << 12) | post_increment
    return COND_AL | 0x05800000 | (rn << 16) | (rd << 12) | offset


def strb(rd, rn, offset=0):
    return COND_AL | 0x05C00000 | (rn << 16) | (rd << 12) | offset


def strh(rd, rn, offset=0):
    hi, lo = (offset >> 4) & 0xF, offset & 0xF
    return COND_AL | 0x01C000B0 | (rn << 16) | (rd << 12) | (hi << 8) | lo


def branch(target_index, current_index, link=False, cond=0xE):
    """Branch between instruction indices within the same block."""
    offset = (target_index - current_index - 2) & 0xFFFFFF
    return (cond << 28) | (0x0B000000 if link else 0x0A000000) | offset


# ---------------------------------------------------------------- ARM9

arm9 = []


def emit(word):
    arm9.append(word)
    return len(arm9) - 1


emit(mov(0, 0x04000000))            # r0 = IO base
emit(mov(1, 0x00020000))
emit(str_word(1, 0, 0x000))         # DISPCNT A = display VRAM block A
emit(mov(1, 0x80))
emit(strb(1, 0, 0x240))             # VRAMCNT_A = enabled, LCDC
emit(mov(1, 0x00010000))
emit(add(6, 0, 0x1000))
emit(str_word(1, 6, 0))             # DISPCNT B = graphics mode, no layers → backdrop
emit(mov(2, 0x05000000))
emit(add(2, 2, 0x400))
emit(mov(1, 0x3300))
emit(strh(1, 2, 0))                 # engine B backdrop = teal (BGR555)
emit(mov(7, 0))                     # r7 = frame base colour

frame = len(arm9)
emit(mov(3, 0x06800000))            # r3 = VRAM A (framebuffer)
emit(mov(4, 0x6000))                # r4 = 24576 words (256×192×2 bytes)
emit(mov_reg(5, 7))
pixloop = len(arm9)
emit(str_word(5, 3, post_increment=4))
emit(add(5, 5, 0x00010000))
emit(add(5, 5, 0x00000001))         # both packed pixels drift through the palette
here = emit(subs(4, 4, 1))
emit(branch(pixloop, here + 1, cond=0x1))       # bne pixloop
emit(add(7, 7, 0x00040000))
here = emit(add(7, 7, 0x00000004))  # shift the whole gradient next pass
emit(branch(frame, here + 1))                    # b frame

arm9_bin = b''.join(struct.pack('<I', w) for w in arm9)

# ---------------------------------------------------------------- ARM7

arm7 = [branch(0, 0)]               # b . (park forever)
arm7_bin = b''.join(struct.pack('<I', w) for w in arm7)

# ---------------------------------------------------------------- header

ARM9_ROM_OFFSET = 0x200
ARM9_RAM = 0x02000000
arm7_rom_offset = ARM9_ROM_OFFSET + ((len(arm9_bin) + 3) & ~3)
ARM7_RAM = 0x02380000

header = bytearray(0x200)
header[0x00:0x0C] = b'BIFOLD TEST\x00'
header[0x0C:0x10] = b'####'          # homebrew marker for melonDS
header[0x10:0x12] = b'01'
struct.pack_into('<I', header, 0x20, ARM9_ROM_OFFSET)
struct.pack_into('<I', header, 0x24, ARM9_RAM)   # entry == load address
struct.pack_into('<I', header, 0x28, ARM9_RAM)
struct.pack_into('<I', header, 0x2C, len(arm9_bin))
struct.pack_into('<I', header, 0x30, arm7_rom_offset)
struct.pack_into('<I', header, 0x34, ARM7_RAM)
struct.pack_into('<I', header, 0x38, ARM7_RAM)
struct.pack_into('<I', header, 0x3C, len(arm7_bin))
struct.pack_into('<I', header, 0x68, 0)          # no banner
rom_end = arm7_rom_offset + len(arm7_bin)
struct.pack_into('<I', header, 0x80, rom_end)    # ROM size
struct.pack_into('<I', header, 0x84, 0x200)      # header size

rom = bytearray(rom_end)
rom[0:0x200] = header
rom[ARM9_ROM_OFFSET:ARM9_ROM_OFFSET + len(arm9_bin)] = arm9_bin
rom[arm7_rom_offset:arm7_rom_offset + len(arm7_bin)] = arm7_bin

os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(OUT, 'wb') as f:
    f.write(rom)
print(f'Wrote {OUT} ({len(rom)} bytes, ARM9 {len(arm9_bin)} bytes)')
