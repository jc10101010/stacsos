/* SPDX-License-Identifier: MIT */

/* StACSOS Kernel - Core
 *
 * Copyright (C) University of St Andrews 2024.  All Rights Reserved.
 * Tom Spink <tcs6@st-andrews.ac.uk>
 */

/* AP per-core scratch stacks live immediately after the BSP's scratch region
 * from start32.S (SCRATCH_MEMORY = 0x100000, consuming 5 pages: one boot stack
 * page + PML4 + PDP_LO/MID/HI), which ends at 0x105000.  One 4K page per core. */
#define TRAMPOLINE_SCRATCH_MEMORY  0x105000

.code16
.section .trampoline.text16, "ax"

.align 16

_L0000_trampoline16:
    /*We need to get this fresh core from 16 bit real to 64 bit long*/
    cli # Disable interrupts
    cld # Reset directions of string instructions
    jmp    _L0050_trampoline16
    .align 16
_L0010_GDT_table:
    .long 0, 0
    .long 0x0000FFFF, 0x00CF9A00    # flat code
    .long 0x0000FFFF, 0x008F9200    # flat data
    .align 16
_L0030_GDT_value:
    .word _L0030_GDT_value - _L0010_GDT_table - 1
    .long 0x0000 # This needs to be repaired, should point to the thing below
    .long 0, 0
    .align 16
_L0040_FARJMP:
    .long   0                   # 32-bit offset  — patched at runtime
    .word   0x08                # selector       — flat PM code, fixed
    .align 16
_L0050_trampoline16:
    movw %cs, %ax                # Copy the CS segment over to DS
    movw %ax, %ds

    /* The segment base (CS * 16) is the linear address this trampoline was
       loaded at.  Both the GDTR base and the far-jump offset are linear
       addresses, so compute the base once and keep it in EDX. */
    xorl    %edx, %edx
    movw    %cs, %dx
    shll    $4, %edx           # EDX = CS * 16 = linear base of the trampoline

    /* Patch the GDT descriptor's base field (at offset 0x32, just after the
       2-byte limit) with the linear address of _L0010_GDT_table = base+0x10.
       Must happen BEFORE lgdtl, which reads the descriptor. */
    leal    0x10(%edx), %eax   # base + 0x10 (_L0010_GDT_table)
    movl    %eax, 0x0032       # GDTR base field

    lgdtl   0x0030             # load the GDT (now with a correct linear base)

    movl    %cr0, %eax         # get cr0
    orl     $1, %eax           # set bit 0 (PE)
    movl    %eax, %cr0         # set cr0, protection enabled

    /* Patch the far-jump offset (at 0x40) with the linear address of the
       32-bit entry = base + 0x90 (_L0090_trampoline32). */
    leal    0x90(%edx), %eax   # base + 0x90 (_L0090_trampoline32)
    movl    %eax, 0x0040       # far-jump 32-bit offset field

    ljmpl   *0x0040            # far jump via FARJMP descriptor @ 0x40 (DS-rel)
    .align 16
/* NULL IDT Pointer */
_L0060_NULL_IDTP:
    .word 0
    .long 0
    .align 4
/* Temporary GDT */
_L0070_LONG_GDT_table:
    .quad 0x0000000000000000		// NULL

    // 64-bit Code Segment @ 0x08
    .quad 0x00209A0000000000

    // Data Segment @ 0x10
    .quad 0x0000920000000000
    .align 4
/* Temporary GDT pointer */
_L0080_LONG_GDT_value:
    .word (gdt_end - gdt)
    .long gdt
    .align 16
    .code32
_L0090_FARJMP:
    .long   0                   # 32-bit offset  — patched at runtime
    .word   0x08                # selector       — flat PM code, fixed
    .align 16
_L00A0_trampoline32:
    # Zero out segment selectors
    movw   $0x10, %ax          # flat data selector
    movw   %ax, %ds            # (ds/es/ss still hold stale real-mode values here)
    movw   %ax, %es
    movw   %ax, %ss

    # Get this CPUs scratch stack section
    movl $1, %eax                    # increment amount for the atomic add
    lock xaddl %eax, -----0x90(%edx) # eax = old counter = this core's index; counter++ (TODO patch offset once we know data offset)
    movl %eax, %ecx                  # keep the raw core index in ecx for later use
    shll $12, %eax                   # index * 4096 = this core's page offset
    addl $TRAMPOLINE_SCRATCH_MEMORY, %eax # Determine where the trampolines stack should fit in
    addl $0x1000, %eax                    #  The top of that page is the top of the stack
    movl %eax, %esp                      # Now each core has there own stack

    # Next we need to read from PML4 already setup by the BSP
    mov $PML4, %cr3

    # Check for FSGSBASE
    mov $7, %eax
    xor %ecx, %ecx
    cpuid
    bt $0, %ebx

    mov $(CR4_PSE | CR4_PAE | CR4_PGE | CR4_OSFXSR | CR4_OSXMMEXCPT | CR4_FSGSBASE), %eax
    jc has_fsgs

    and $(~CR4_FSGSBASE), %eax

has_fsgs:

    # Initialise CR4
    mov %eax, %cr4

    # Initialise EFER
    mov $(0xC0000080), %ecx
    xor %edx, %edx
    mov $(EFER_SCE | EFER_LME | EFER_NXE), %eax
    wrmsr

    # Initialise CR0
    mov $(CR0_PG | CR0_PE | CR0_MP | CR0_WP | CR0_NE), %eax
    mov %eax, %cr0

    # Load a null IDT
    lidt 0x60(%edx)

    # Load the temporary GDT
    lgdt 0x70(%edx)

    # PATCH FARJUMP to _L00B0_trampoline64

    ljmp *0x90(%edx) # Got to _L00B0_trampoline64

    .align 16
    .code64
    .section .startup.text64, "ax"
_L00B0_trampoline64:
    hlt



/* TODO: Make independant of page run in ideally*/

.section .trampoline.data, "aw"

/*
    Stores the closure pointer, the same for all started up APs
 */
.align 8
.globl trampoline_data_asm
.type trampoline_data_asm, %object
trampoline_data_asm:
    .long 0
    .quad 0     /* void (*trampoline)()    (offset 0) */
.size trampoline_data_asm,.-trampoline_data_asm
