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

/* Entry point — bring this AP from 16-bit real mode to 64-bit long mode */
trampoline_start:
    cli
    cld
    jmp    trampoline16_main
    .align 16

/* ── Real-mode (PM16) GDT ───────────────────────────────────────────────── */
gdt_real:
    .long 0, 0
    .long 0x0000FFFF, 0x00CF9A00    /* flat code */
    .long 0x0000FFFF, 0x008F9200    /* flat data */
    .align 16

gdtr_real:
    .word gdtr_real - gdt_real - 1
gdtr_real_base:
    .long 0                          /* base — patched at runtime */
    .long 0, 0
    .align 16

farjmp_real:
    .long 0                          /* 32-bit offset — patched at runtime */
    .word 0x08                       /* selector — flat PM code */
    .align 16

/* ── 16-bit trampoline code ─────────────────────────────────────────────── */
trampoline16_main:
    movw    %cs, %ax
    movw    %ax, %ds

    /* EDX = CS * 16 = linear base of this trampoline page */
    xorl    %edx, %edx
    movw    %cs, %dx
    shll    $4, %edx

    leal    (gdt_real - trampoline_start)(%edx), %eax
    movl    %eax, (gdtr_real_base - trampoline_start)

    lgdtl   (gdtr_real - trampoline_start)

    movl    %cr0, %eax
    orl     $1, %eax
    movl    %eax, %cr0

    leal    (trampoline32_main - trampoline_start)(%edx), %eax
    movl    %eax, (farjmp_real - trampoline_start)

    ljmpl   *(farjmp_real - trampoline_start)
    .align 16

/* ── Null IDTR ──────────────────────────────────────────────────────────── */
null_idtr:
    .word 0
    .long 0
    .align 4

/* ── Long-mode GDT ──────────────────────────────────────────────────────── */
gdt_long:
    .quad 0x0000000000000000         /* NULL */
    .quad 0x00209A0000000000         /* 64-bit code @ 0x08 */
    .quad 0x0000920000000000         /* data       @ 0x10 */
gdt_long_end:
    .align 4

gdtr_long:
    .word (gdt_long_end - gdt_long - 1)
gdtr_long_base:
    .long 0                          /* base — patched at runtime */
    .align 16

    .code32
/* ── 32-bit far-jump descriptor (protected → long mode) ─────────────────── */
farjmp_long:
    .long 0                          /* 32-bit offset — patched at runtime */
    .word 0x08                       /* selector — 64-bit code */
    .align 16

/* ── 32-bit trampoline code ─────────────────────────────────────────────── */
trampoline32_main:
    movw   $0x10, %ax
    movw   %ax, %ds
    movw   %ax, %es
    movw   %ax, %ss

    movl $1, %eax
    lock xaddl %eax, (trampoline_data_asm_count - trampoline_start)(%edx) 
    movl %eax, %ecx
    shll $12, %eax
    addl $TRAMPOLINE_SCRATCH_MEMORY, %eax
    addl $0x1000, %eax
    movl %eax, %esp

    mov $PML4, %cr3

    mov $7, %eax
    xor %ecx, %ecx
    cpuid
    bt $0, %ebx

    mov $(CR4_PSE | CR4_PAE | CR4_PGE | CR4_OSFXSR | CR4_OSXMMEXCPT | CR4_FSGSBASE), %eax
    jc has_fsgs
    and $(~CR4_FSGSBASE), %eax
has_fsgs:
    mov %eax, %cr4

    mov $(0xC0000080), %ecx
    xor %edx, %edx
    mov $(EFER_SCE | EFER_LME | EFER_NXE), %eax
    wrmsr

    mov $(CR0_PG | CR0_PE | CR0_MP | CR0_WP | CR0_NE), %eax
    mov %eax, %cr0

    /* Patch gdtr_long base with the linear address of gdt_long */
    leal    (gdt_long - trampoline_start)(%edx), %eax
    movl    %eax, (gdtr_long_base - trampoline_start)(%edx)

    lidt    (null_idtr  - trampoline_start)(%edx)
    lgdt    (gdtr_long  - trampoline_start)(%edx)

    /* Patch farjmp_long offset with the address of the 64-bit entry point */
    leal    (trampoline64_start - trampoline_start)(%edx), %eax
    movl    %eax, (farjmp_long - trampoline_start)(%edx)

    ljmp    *(farjmp_long - trampoline_start)(%edx)

    .align 16
    .code64
    .section .startup.text64, "ax"
trampoline64_start:
    hlt




.section .trampoline.data, "aw"

/*
    Stores the closure pointer, the same for all started up APs
 */
.align 8
.globl trampoline_data_asm
.type trampoline_data_asm, %object
trampoline_data_asm_count:
    .long 0
trampoline_data_asm_ptr:
    .quad 0     /* void (*trampoline)()    (offset 0) */
.size trampoline_data_asm,.-trampoline_data_asm
